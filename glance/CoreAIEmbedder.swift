//
//  CoreAIEmbedder.swift
//  glance v2
//
//  EdgeFace-XXS face embedding via Apple's Core AI framework (Neural Engine).
//  Replaces ArcFace/Core ML. Model converted from PyTorch with coreai-torch,
//  compiled with coreai-build --preferred-compute neural-engine.
//

import CoreAI
import CoreGraphics
import Foundation

enum CoreAIEmbedderError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(String)
    case functionMissing
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "EdgeFaceXXS.aimodel 不在 app bundle 中。"
        case .modelLoadFailed(let detail):
            return "Core AI 模型加载失败：\(detail)"
        case .functionMissing:
            return "模型缺少 main 推理函数。"
        case .unexpectedOutput:
            return "模型未返回 512 维 embedding。"
        }
    }
}

/// EdgeFace embedder backed by Core AI / Neural Engine.
/// The model is loaded once (lazily, on first embedding) and reused; AIModel and
/// InferenceFunction are Sendable value types, safe to share across tasks.
nonisolated final class CoreAIEmbedder: FaceEmbedder, @unchecked Sendable {
    nonisolated let name = "EdgeFace-XXS (Core AI / NPU)"
    nonisolated let modelIdentifier = "edgeface-xxs-coreai-v1"
    nonisolated let embeddingDimension = 512
    nonisolated let requiresAlignment = true

    private static let inputSize = 112
    private static let dim = 512

    /// Lazily-loaded shared model+function, created once on first use.
    private static let loader: Task<(AIModel, InferenceFunction), Error> = Task.detached(priority: .userInitiated) {
        guard let url = Bundle.main.url(forResource: "EdgeFaceXXS", withExtension: "aimodel") else {
            throw CoreAIEmbedderError.modelNotFound
        }
        let model: AIModel
        do {
            // 强制 specialization 优先 Neural Engine，避免 Core AI 默认回退到 GPU
            // （GPU 推理持续占用高、发热；ANE 每瓦性能远高，正是端侧识别该用的单元）。
            let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
            model = try await AIModel(contentsOf: url, options: options)
        } catch {
            throw CoreAIEmbedderError.modelLoadFailed(error.localizedDescription)
        }
        guard let fn = try? model.loadFunction(named: "main") else {
            throw CoreAIEmbedderError.functionMissing
        }
        return (model, fn)
    }

    nonisolated func embedding(for face: CGImage) async throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw CoreAIEmbedderError.unexpectedOutput
        }
        guard let pixels = Self.rgbFloats(from: face) else {
            throw CoreAIEmbedderError.unexpectedOutput
        }
        let (_, function) = try await Self.loader.value
        let input = NDArray(scalars: pixels, shape: [1, 3, Self.inputSize, Self.inputSize])
        var outputs = try await function.run(inputs: ["input_image": input])
        guard var emb = outputs.remove("embedding")?.ndArray else {
            throw CoreAIEmbedderError.unexpectedOutput
        }
        let view = emb.view(as: Float.self)
        let vector: [Float] = view.withUnsafePointer { (ptr: UnsafePointer<Float>, _, _) in
            Array(UnsafeBufferPointer(start: ptr, count: Self.dim))
        }
        guard vector.count == Self.dim else {
            throw CoreAIEmbedderError.unexpectedOutput
        }
        return FaceEmbedding.l2Normalized(vector)
    }

    /// Renders the 112x112 CGImage into planar RGB floats normalized to [-1, 1]
    /// (EdgeFace training transform: (x - 0.5) / 0.5).
    nonisolated private static func rgbFloats(from image: CGImage) -> [Float]? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let plane = w * h
        var planar = [Float](repeating: 0, count: 3 * plane)
        for i in 0..<plane {
            let base = i * 4
            planar[i] = (Float(rgba[base]) / 255.0 - 0.5) / 0.5
            planar[plane + i] = (Float(rgba[base + 1]) / 255.0 - 0.5) / 0.5
            planar[2 * plane + i] = (Float(rgba[base + 2]) / 255.0 - 0.5) / 0.5
        }
        return planar
    }
}
