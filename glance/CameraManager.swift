//
//  CameraManager.swift
//  glance
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage. Runs entirely on-device.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
struct CameraFrame {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.jonathan.glance.camera.session")
    /// v2 修复：独立的串行队列专管 startRunning/stopRunning。与 sample-buffer 回调队列分离，
    /// 避免启停 block 和帧回调互相排队；start/stop 在此队列上同步执行，返回时状态已落实，
    /// 消除"标志说在跑、实际已停"以及 stop block 晚于 start 执行的竞态（多次唤醒后摄像头不亮）。
    private let lifecycleQueue = DispatchQueue(label: "com.jonathan.glance.camera.lifecycle")

    /// Handed to the delegate outside the actor; only ever touched via `Task { @MainActor ... }`.
    private let framePublisher = FramePublisher()

    /// 待机侦测用低功耗实例：挑最小分辨率、最低帧率，只做人脸检测。
    private let prefersLowPower: Bool

    init(prefersLowPower: Bool = false) {
        self.prefersLowPower = prefersLowPower
        super.init()
        framePublisher.owner = self
    }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
        default:
            permission = .denied
        }

        guard permission == .granted else {
            errorMessage = "Camera access not granted (status: \(describe(status))). " +
                (status == .restricted
                    ? "macOS 将其报告为*受限*——不是普通的用户拒绝。这通常是“屏幕使用时间”的内容限制或 MDM/描述文件策略在阻止此应用访问摄像头；在限制解除前，去“系统设置”>“隐私与安全性”>“摄像头”里打开也没用。"
                    : "请在“系统设置”>“隐私与安全性”>“摄像头”中开启。如果列表里没有 Glance，请退出应用，在“终端”中执行 `tccutil reset Camera com.jonathan.glance`，然后重新打开应用，让 macOS 再次询问。")
            return
        }

        errorMessage = nil
        configureSessionIfNeeded()
        reconcileDeviceIfNeeded()

        // v2: 在 lifecycle 队列上同步启停，返回时状态已确定。startRunning 是同步调用，
        // 且此队列不用于帧回调，不会死锁。逐次 sync 保证 start/stop 严格按调用顺序执行，
        // 不再出现残留 stop block 晚于 start 把刚开的摄像头关掉。
        lifecycleQueue.sync { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
        isRunning = true
    }

    func stop() {
        lifecycleQueue.sync { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
        isRunning = false
        currentFrame = nil
    }

    /// v2: 等待真实出帧。锁屏多次唤醒时，USB 摄像头偶尔被走近侦测的 session 抢占，
    /// startRunning 成功但拿不到设备、帧永远不来（动画在转、灯却不亮）。等一小段时间，
    /// 没帧就 stop + 重启一次 session 自愈——避免整个扫描窗口空转到超时。
    /// 返回是否拿到第一帧。
    func waitForFirstFrame(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while currentFrame == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if currentFrame != nil { return true }

        GlanceLog.write("摄像头首个视频帧超时，重启 session 自愈")
        stop()
        try? await Task.sleep(nanoseconds: 300_000_000) // 给 USB 设备释放时间
        await start()
        let retryDeadline = Date().addingTimeInterval(2.0)
        while currentFrame == nil, Date() < retryDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return currentFrame != nil
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?
    /// 当前生效的相机与分辨率，供诊断日志使用。
    private(set) var activeDeviceDescription: String = "未选择"

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
        // `activeFormat`, so leaving this at `.high` and locking the format separately below is sufficient.
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Called on every `start()` so a camera preference change in Settings takes effect without an app restart.
    private func reconcileDeviceIfNeeded() {
        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "未找到摄像头设备。"
            return
        }
        guard device.uniqueID != currentInput?.device.uniqueID else { return }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            selectPreferredFormat(for: device)
        } else {
            currentInput = nil
            errorMessage = "未找到摄像头设备。"
        }
        session.commitConfiguration()
    }

    /// 选一个「设备真的能跑」的格式：优先长边 ≤1280、且支持 30fps 的最高分辨率。
    /// 原来按最高分辨率挑，容易选到 4K@5fps 这类实际跑不动的格式，导致一帧都收不到；
    /// 而且识别最终只用 448px 的裁剪，4K 纯属浪费带宽和功耗。
    private func selectPreferredFormat(for device: AVCaptureDevice) {
        let all = device.formats
        guard !all.isEmpty else { return }

        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }

        if prefersLowPower {
            // 待机侦测：只要够检测到脸，越小越省电；1/4 帧率上限也压到 5fps。
            let small = all.filter { area($0) >= 320 * 240 && area($0) <= 640 * 480 }
            let pick = small.min { area($0) < area($1) } ?? all.min { area($0) < area($1) }
            guard let pick else { return }
            applyFormat(pick, to: device, targetFPS: 5)
            return
        }

        let capped = all.filter { area($0) > 0 && max(CMVideoFormatDescriptionGetDimensions($0.formatDescription).width,
                                                       CMVideoFormatDescriptionGetDimensions($0.formatDescription).height) <= 1280 }
        let pool = capped.isEmpty ? all : capped
        let best = pool.max { lhs, rhs in
            let l30 = maxFPS(lhs) >= 29, r30 = maxFPS(rhs) >= 29
            if l30 != r30 { return r30 }          // 30fps 可用的优先
            return area(lhs) < area(rhs)
        }
        guard let best else { return }
        applyFormat(best, to: device, targetFPS: 30)
    }

    private func applyFormat(_ best: AVCaptureDevice.Format, to device: AVCaptureDevice, targetFPS: Double) {
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            let ranges = best.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate }) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            // v2: 自动图像控制——扫描前确保对焦/曝光/白平衡都处于连续自动模式，
            // 并把测光/对焦兴趣点放在画面中心（解锁时人脸通常居中）。
            // 全用公开 AVFoundation API，无需逆向厂商私有 UVC 控制，也无需用户手动调。
            if !prefersLowPower {
                configureAutoImageControl(device)
            }
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            activeDeviceDescription = "\(device.localizedName) \(dims.width)x\(dims.height)@\(Int(targetFPS))fps"
        } catch {
            errorMessage = "无法应用摄像头格式：\(error.localizedDescription)"
        }
    }

    /// must be called while `device` is locked for configuration.
    /// 实测（EMEET C60E）：连续自动对焦/曝光支持且生效；白平衡与兴趣点均不支持，故只设前两项。
    private func configureAutoImageControl(_ device: AVCaptureDevice) {
        // 连续自动对焦：扫描时持续合焦，避免"拉风箱"导致抓到糊帧。
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
        // 连续自动曝光：逆光/暗光下让系统自动调节。
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        } else if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        currentFrame = frame
    }

    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for spoof-cue extraction which
    /// needs pixel detail (screen texture, moiré, gloss) the downscaled working frame throws away.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Expand ~1.3x so device edges/bezels are captured for texture/moiré cues.
        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    /// `CIContext` is expensive to create and safe to reuse concurrently. Explicitly `nonisolated` since a `static let`
    /// on this `@MainActor` class would otherwise be main-actor-isolated, which the `nonisolated renderCrop` can't touch.
    private nonisolated static let cropRenderContext = CIContext()

    /// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there, then hops back.
    /// Swift 6: 必须显式 nonisolated —— 它运行在 AVFoundation 的摄像头队列而非 main actor，
    /// 否则外层 @MainActor 会感染此嵌套类，captureOutput 里触发 _checkExpectedExecutor 断言崩溃。
    /// 其可变状态（ciContext/nextFrameID/owner）只在 sessionQueue 上访问，线程安全。
    private nonisolated final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        private let ciContext = CIContext()
        /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
        /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceExtent = sourceImage.extent
            var ciImage = sourceImage
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(
                id: nextFrameID,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size
            )

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
