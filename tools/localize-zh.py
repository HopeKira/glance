#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 glance 源码中的界面英文替换为简体中文（只替换字符串字面量）。

用途：上游发版后重新套用汉化。用法：
    cd glance && python3 tools/localize-zh.py && git diff --stat

注意：
- 只替换来源文件里出现的字面量，已翻译过的文件再跑一遍不会重复替换（键已不存在）。
- 多词整串替换是全局的；单词只在 LookUI 命中行（Text(/Button(/title:/return " 等）替换，
  避免误伤资源名（MenuBarIcon）与逻辑键（onWake/onActivity 这类 rawValue）。
- 校验：跑完用 xcodebuild 编译，编译器会抓出替换造成的语法错误。
"""

import os, re, io

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "glance"))

MULTI = {
"A device-shaped rectangle overlaps the face — a phone or tablet held up.": "面部出现设备大小的矩形——像是举着手机或平板。",
"A device-shaped rectangle was detected around the face — this looks like a photo or screen.": "面部周围检测到设备大小的矩形——这看起来像照片或屏幕。",
"Abstaining — not enough head rotation to tell a plane from a still 3D face.": "暂不判定——头部转动不足，无法区分平面与静态 3D 人脸。",
"Accessibility not granted — open System Settings and enable glance.": "未获得“辅助功能”权限——请打开“系统设置”并启用 Glance。",
"Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable glance.": "需要“辅助功能”权限。请打开“系统设置”→“隐私与安全性”→“辅助功能”，并启用 Glance。",
"Add Identity": "添加身份",
"Aligned face": "对齐后的人脸",
"Aligned input": "对齐输入",
"All directions": "全部方向",
"Allow Glance to recognize your face": "允许 Glance 识别你的面容",
"Allow Glance to unlock your Mac": "允许 Glance 解锁你的 Mac",
"Also requires proof of a real face.": "同时要求证明是真人。",
"Any one firing passes liveness. None firing is not a failure — the scan just keeps looking.": "任一条触发即通过活体检测；都没触发也不算失败——扫描会继续寻找。",
"Authenticate to enroll another face": "验证身份以录入另一张面容",
"Authenticate to re-enroll this face": "验证身份以重新录入这张面容",
"Authenticate to re-enroll your face": "验证身份以重新录入你的面容",
"Authenticate to set up or use glance": "验证身份以设置或使用 Glance",
"Authenticate to use Face Lab": "验证身份以使用面容实验室",
"Authenticate to view your enrolled face": "验证身份以查看已录入的面容",
"Authenticating…": "正在验证…",
"Authentication was cancelled or failed.": "验证被取消或失败。",
"Auto lock session": "自动锁定会话",
"Auto retry once after failure": "失败后自动重试一次",
"Automatically check for updates": "自动检查更新",
"Bottom left": "左下",
"Bottom right": "右下",
"Bring your face closer": "脸再靠近一点",
"Built-in display": "内置显示器",
"Camera Preview": "摄像头预览",
"Camera started.": "摄像头已启动。",
"Camera stopped.": "摄像头已停止。",
"Capture Sample": "采集样本",
"Capture quality • not recorded": "采集质量 • 未记录",
"Capture quality: —": "采集质量：—",
"Captured with a different recognition model — recapture before this face can unlock your Mac.": "该面容由其他识别模型采集——需重新采集后此面容才能解锁你的 Mac。",
"Change password": "更改密码",
"Check for Updates": "检查更新",
"Checks that you're a live person, not a photo. May increase unlock time.": "校验你是真人而非照片。可能会延长解锁时间。",
"Confirm — evidence of a real face": "确认——真人迹象",
"Could not align the detected face.": "无法对齐检测到的人脸。",
"Couldn't confirm a live face — hover the notch to try again.": "无法确认是真人——悬停刘海可再试一次。",
"Couldn't confirm a live face.": "无法确认是真人。",
"Couldn't create CGEvent for keystroke.": "无法为按键创建 CGEvent。",
"Couldn't prepare the aligned face image for Core ML.": "无法准备用于 Core ML 的对齐人脸图像。",
"Cue firing latches for the whole scan — reset to re-test.": "线索一旦触发会锁定至本次扫描结束——重置后可重新测试。",
"Decryption failed. The stored credential may be corrupted.": "解密失败。已保存的凭据可能已损坏。",
"Delete this enrolled face?": "删除这张已录入的面容？",
"Deny — evidence of a spoof": "否决——伪造迹象",
"Detection distance": "检测距离",
"Device detected": "检测到设备",
"Display on": "显示在",
"Distributions overlap — no single cutoff perfectly separates these samples yet.": "两个分布有重叠——目前还没有哪个阈值能完美区分这些样本。",
"Either one firing fails face unlock outright, and overrides any confirmation.": "任一条触发都会直接判定失败，并覆盖任何确认结果。",
"Enable Face Unlock": "启用面容解锁",
"Enable it in System Settings > Privacy & Security > Camera. If glance isn't listed there, quit the app, run `tccutil reset Camera com.jonathan.glance` in Terminal, then relaunch so macOS asks again.": "请在“系统设置”>“隐私与安全性”>“摄像头”中开启。如果列表里没有 Glance，请退出应用，在“终端”中执行 `tccutil reset Camera com.jonathan.glance`，然后重新打开应用，让 macOS 再次询问。",
"Encryption failed.": "加密失败。",
"Enroll another face": "录入另一张面容",
"Enroll separate identities to use Glance with multiple people, accessories (ex. glasses), facial expressions, or new lighting environments. This improves recognition quality.": "可录入多个身份，以便多人共用 Glance，或应对眼镜等配饰、不同表情与光照环境。这能提升识别质量。",
"Enrolled faces couldn't be read": "无法读取已录入的面容",
"Enter a name before capturing a sample.": "请先输入名称再采集样本。",
"Enter a name.": "请输入名称。",
"Enter a name...": "输入名称…",
"Enter a password first.": "请先输入密码。",
"Enter a password.": "请输入密码。",
"Enter password...": "输入密码…",
"Enter your password": "输入你的密码",
"External display": "外接显示器",
"Eye aspect ratio dipped and recovered — a photo cannot blink.": "眼睛宽高比下降后恢复——照片无法眨眼。",
"Face Lab — On-Device Face Recognition (Debug)": "面容实验室——端侧面容识别（调试）",
"Face Lab": "面容实验室",
"Face Unlock for Mac": "Mac 面容解锁",
"Face captured": "已采集面容",
"Face detection duration": "面容检测时长",
"Face encrypted": "面容已加密",
"Face enrollment": "面容录入",
"Face not recognized — hover the notch to try again.": "面容未识别——悬停刘海可再试一次。",
"Face not recognized.": "面容未识别。",
"Face unlock is on, but no password is stored yet.": "面容解锁已开启，但还没有保存密码。",
"Face unlock is on, but the session is locked — authenticate once from Password settings first.": "面容解锁已开启，但会话处于锁定状态——请先在“密码”设置中验证一次身份。",
"Feature print used an unexpected element type.": "特征打印返回了意外的元素类型。",
"Flat vs 3D diagnostics": "平面 / 立体诊断",
"Flat vs 3D": "平面 / 立体",
"Follow the directions\\nshown on the screen": "按屏幕提示\\n跟着做",
"Glance Settings": "Glance 设置",
"Glance is not as secure as Apple's FaceID or TouchID.": "Glance 的安全性不如 Apple 的 Face ID 或 Touch ID。",
"Haptic feedback": "触感反馈",
"Heavy: a deny cue fails the scan; at least one confirm cue must fire before it can pass.": "严格：任一“否决”线索触发即判定失败；至少要有一条“确认”线索触发才可能通过。",
"Held-out nose points miss the plane fit — the face has real depth.": "留出的鼻部点与拟合平面不符——这张脸有真实深度。",
"I understand": "我已了解",
"Injecting…": "正在输入…",
"It uses your Mac's standard webcam and is designed for convenience, not high-security authentication.": "它使用 Mac 自带的摄像头，为便利而设计，不用于高安全级别的身份验证。",
"Keychain item had an unexpected format.": "钥匙串项目格式异常。",
"Keychain item not found.": "未找到钥匙串项目。",
"Large flat specular highlight — glass/screen glare rather than skin's small scattered shine.": "大面积平坦高光——更像玻璃或屏幕反光，而不是皮肤的小范围散射高光。",
"Launch at login": "登录时启动",
"Less strict": "较宽松",
"Light includes basic protection. Heavy requires you to blink or slightly move your head.": "轻度包含基础防护；严格模式要求你眨眼或轻微转头。",
"Light: only the deny cues run. Anything not actively rejected is treated as live.": "轻度：只运行“否决”线索，未被主动否决的都视为真人。",
"Live — auto-confirmed (Light mode)": "真人——已自动确认（轻度模式）",
"Liveness check failed.": "活体检测未通过。",
"Liveness cues reset.": "活体线索已重置。",
"Liveness detection": "活体检测",
"Loading Face Lab…": "正在加载面容实验室…",
"Look straight at the camera": "正对摄像头",
"Looking for your face…": "正在寻找你的面容…",
"Main display": "主显示器",
"Mark Genuine (this is me)": "标记为本人（这是我）",
"Mark Impostor (not me)": "标记为他人（不是我）",
"Match confidence": "匹配置信度",
"More information": "更多信息",
"More strict": "更严格",
"NO MATCH": "不匹配",
"Name this face": "为此面容命名",
"No camera device found.": "未找到摄像头设备。",
"No enrolled identities yet — capture a sample first.": "还没有已录入的身份——请先采集样本。",
"No face detected in frame.": "画面中未检测到人脸。",
"No face detected — hover the notch to try again.": "未检测到人脸——悬停刘海可再试一次。",
"No face detected — can't capture a sample.": "未检测到人脸——无法采集样本。",
"No face detected — can't recognize.": "未检测到人脸——无法识别。",
"No face detected.": "未检测到人脸。",
"No face": "无面部",
"No identities are enabled — face unlock won't recognize anyone until you switch one back on.": "没有启用任何身份——在重新开启至少一个身份之前，面容解锁不会识别任何人。",
"No identities enrolled yet — run the guided nine-pose capture with Add Identity.": "还没有已录入的身份——使用“添加身份”进行九姿势引导采集。",
"No identities enrolled yet.": "还没有已录入的身份。",
"No liveness frame yet.": "尚无活体帧。",
"No samples captured": "未采集到样本",
"No thanks": "不用了",
"Nose offset tracks head yaw — the nose sits off the eye plane, so this isn't flat.": "鼻部偏移随头部偏转变化——鼻子不在眼睛平面上，因此这不是平面。",
"Notch — closed": "刘海——收起",
"Nothing has been deleted, and Glance will not overwrite it — enrolling is blocked until this resolves. Quit and reopen Glance to retry. If it keeps failing, the session key no longer matches this data: remove the stored password on the Password tab to clear both, then set up again.": "没有删除任何内容，Glance 也不会覆盖它——在问题解决前无法进行录入。请退出并重新打开 Glance 重试。如果一直失败，说明会话密钥已与这份数据不匹配：在“密码”标签页删除已保存的密码即可同时清除两者，然后重新设置。",
"Nothing to record — run Identify first.": "没有可记录的内容——请先运行“识别”。",
"On lock": "锁屏时",
"On space": "按空格时",
"On wake": "唤醒时",
"Only rejects obvious spoofs.": "只拒绝明显的伪造。",
"Open Accessibility settings": "打开“辅助功能”设置",
"Password and face enrollment removed.": "密码与面容数据已删除。",
"Password cannot be empty.": "密码不能为空。",
"Password encrypted": "密码已加密",
"Password saved and encrypted.": "密码已保存并加密。",
"Pending — nothing decided yet": "待定——尚未判定",
"Pill — collapsed": "胶囊——收起",
"Pill — expanded": "胶囊——展开",
"Preview ✓": "预览 ✓",
"Preview ✗": "预览 ✗",
"Recognized — unlocking…": "识别成功——正在解锁…",
"Record at least one genuine and one impostor sample to get a suggestion.": "至少记录一个“本人”和一个“他人”样本，才能给出建议。",
"Refresh camera list": "刷新摄像头列表",
"Remove password": "删除密码",
"Reset cues": "重置线索",
"Retry on notch hover": "悬停刘海时重试",
"Run Identify, then tag whether that was really you or someone else — do this across lighting, angle, and expression, and again with a different person, to see where the two score distributions actually fall.": "运行“识别”，然后标记这次是本人还是他人——请在多种光照、角度与表情下重复，并换一个人再试，以看清两组分数分布的真实位置。",
"Saving…": "正在保存…",
"Screen glare detected — this looks like a photo on a display.": "检测到屏幕反光——这看起来像显示设备上的照片。",
"Select camera": "选择摄像头",
"Select multiple": "可多选",
"Selected display (disconnected)": "所选显示器（已断开）",
"Send Feedback": "发送反馈",
"Session Locked": "会话已锁定",
"Session Unlocked": "会话已解锁",
"Session is locked. Authenticate with Touch ID before storing or using the password.": "会话已锁定。请先用触控 ID 验证，再保存或使用密码。",
"Session is locked. Authenticate with Touch ID to access enrolled faces.": "会话已锁定。请用触控 ID 验证以访问已录入的面容。",
"Session locked — authenticate with Touch ID first.": "会话已锁定——请先用触控 ID 验证。",
"Session locked — enrolled faces are encrypted and can't be read or saved yet.": "会话已锁定——已录入的面容处于加密状态，暂时无法读取或保存。",
"Session locked": "会话已锁定",
"Session unlocked.": "会话已解锁。",
"Session unlocked": "会话已解锁",
"Set password": "设置密码",
"Set up Face Unlock": "设置面容解锁",
"Set up Face\\nRecognition": "录入面容\\n解锁",
"Set up Glance": "设置 Glance",
"Set up a password": "设置密码",
"Show animation": "显示动画",
"Show in menu bar": "在菜单栏中显示",
"Show preview": "显示预览",
"Skipped: CGSession reports screen is not actually locked.": "已跳过：CGSession 报告屏幕并未真正锁定。",
"Start Onboarding": "开始引导",
"Starting guided enrollment for a new identity.": "开始为新身份进行引导式录入。",
"Starting the full onboarding flow.": "开始完整引导流程。",
"System default": "系统默认",
"The animation that appears when unlocking your Mac": "解锁 Mac 时播放的动画",
"The session key is missing, but encrypted data still exists that only it could read. Nothing has been deleted. Remove the stored password on the Password tab to clear both and start fresh.": "会话密钥已丢失，但仍有只能由它解密的加密数据。没有删除任何内容。在“密码”标签页删除已保存的密码即可清除两者并重新开始。",
"The stored data couldn't be decrypted with this session key.": "无法用当前会话密钥解密已保存的数据。",
"Threshold Calibration": "阈值校准",
"Too far down": "太靠下",
"Too far left": "太靠左",
"Too far right": "太靠右",
"Too far toward the bottom left": "太靠左下",
"Too far toward the bottom right": "太靠右下",
"Too far toward the top left": "太靠左上",
"Too far toward the top right": "太靠右上",
"Too far up": "太靠上",
"Top left": "左上",
"Top right": "右上",
"Turn your head slightly down": "头稍微向下低",
"Turn your head slightly left": "头稍微向左转",
"Turn your head slightly right": "头稍微向右转",
"Turn your head slightly up": "头稍微向上抬",
"Turn your head to the bottom left": "头向左下方转",
"Turn your head to the bottom right": "头向右下方转",
"Turn your head to the top left": "头向左上方转",
"Turn your head to the top right": "头向右上方转",
"Unlock session": "解锁会话",
"Unlock the session to view enrolled identities.": "解锁会话后才能查看已录入的身份。",
"Use it": "使用",
"Used for Face enrollment and for unlocking your Mac": "用于录入面容和解锁你的 Mac",
"Used to tell enrolled faces apart when more than one person is set up on this Mac.": "当这台 Mac 上有多个用户时，用来区分不同的已录入面容。",
"Vision Feature Print": "Vision 特征打印",
"Vision did not produce a feature print for this image.": "Vision 未能为此图像生成特征打印。",
"You're all set": "设置完成",
"Your enrolled faces couldn't be read, so nothing was saved — writing now would overwrite them.": "无法读取已录入的面容，因此没有保存任何内容——现在写入会覆盖它们。",
"Your password is required to unlock your Mac. It is encrypted and securely stored on your device. Glance works entirely offline, so your password never leaves your Mac.": "解锁 Mac 需要你的登录密码。密码会加密保存在本机。Glance 完全离线运行，密码不会离开你的 Mac。",
"listening for space on the lock screen": "正在监听锁屏界面的空格键",
"liveness clear": "活体通过",
"liveness off": "活体关闭",
"macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time content restrictions or an MDM/profile policy is blocking camera access for this app; toggling it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted.": "macOS 将其报告为*受限*——不是普通的用户拒绝。这通常是“屏幕使用时间”的内容限制或 MDM/描述文件策略在阻止此应用访问摄像头；在限制解除前，去“系统设置”>“隐私与安全性”>“摄像头”里打开也没用。",
"no match": "不匹配",
"padded crop (no alignment)": "填充裁剪（未对齐）",
"Specular: — (no native-resolution crop this frame)": "高光：—（本帧无原生分辨率裁剪）",
"7 days": "7 天",
"14 days": "14 天",
"30 days": "30 天",
"2-point (eyes only)": "2 点（仅眼睛）",
"“On space” reads the keyboard directly to see the space key on the lock screen, which needs Accessibility — the same permission glance uses to type your password. Switch glance on under Privacy & Security → Accessibility, then quit and reopen glance.": "“按空格时”会直接读取键盘，以识别锁屏界面上的空格键，这需要“辅助功能”权限——与 Glance 输入密码所用的权限相同。请在“隐私与安全性”→“辅助功能”中打开 Glance，然后退出并重新打开 Glance。",
}

# 单词：只在明显是 UI 调用的行上替换
SINGLE = {
"Settings": "设置", "Quit": "退出", "About": "关于", "General": "通用",
"Camera": "摄像头", "Recognition": "识别", "Password": "密码", "Face": "面容",
"Identities": "身份", "Cancel": "取消", "Delete": "删除", "Remove": "移除",
"Save": "保存", "Close": "关闭", "Continue": "继续", "Next": "下一步",
"Back": "返回", "Start": "开始", "Stop": "停止", "Grant": "授权",
"Granted": "已授权", "Change": "更改", "Clear": "清除", "Check": "检查",
"Confirm": "确认", "Default": "默认", "Never": "从不", "None": "无",
"Original": "原版", "Minimal": "极简", "Heavy": "严格", "Light": "轻度",
"Enroll": "录入", "Recapture": "重新采集", "Preview": "预览", "Name": "名称",
"Owner": "所有者", "Strength": "强度", "Style": "样式", "Triggers": "触发方式",
"Mode": "模式", "Behaviour": "行为", "Animation": "动画", "Detection": "检测",
"Liveness": "活体", "Permissions": "权限", "Similarity": "相似度", "Unlock": "解锁",
"Recognize": "识别", "Identify": "识别", "Send": "发送", "Running": "运行中",
"Stopped": "已停止", "Idle": "空闲", "Log": "日志", "Genuine": "本人",
"Impostor": "他人", "MATCH": "匹配", "Blink": "眨眼", "Notch": "刘海",
"Up": "上", "Down": "下", "Left": "左", "Right": "右", "Far": "远",
}

UI_LINE = re.compile(r'(Text\(|Button\(|Label\(|GroupBox\(|Picker\(|TextField\(|title:\s*"|text:\s*"|buttonTitle:\s*"|caption:\s*"|NSMenuItem\(title:\s*"|return\s+")')

changed_files = 0
total = 0
for root, _, files in os.walk(ROOT):
    for f in files:
        if not f.endswith(".swift"):
            continue
        p = os.path.join(root, f)
        src = open(p, encoding="utf-8").read()
        orig = src
        # 多词：整串替换
        for en, zh in MULTI.items():
            lit = '"%s"' % en
            if lit in src:
                total += src.count(lit)
                src = src.replace(lit, '"%s"' % zh)
        # 单词：逐行按 UI 上下文替换
        out = []
        for line in src.split("\n"):
            if UI_LINE.search(line):
                for en, zh in SINGLE.items():
                    lit = '"%s"' % en
                    if lit in line:
                        line = line.replace(lit, '"%s"' % zh)
                        total += 1
            out.append(line)
        src = "\n".join(out)
        if src != orig:
            open(p, "w", encoding="utf-8").write(src)
            changed_files += 1

print("修改文件:", changed_files, "替换处数:", total)
