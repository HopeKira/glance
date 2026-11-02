# Glance 简体中文化构建（zh-Hans）

[Glance](https://www.tryglance.app/) 是 macOS 上的面容解锁工具（用摄像头替代 Touch ID 输入密码）。
上游：[jonnyoo/glance](https://github.com/jonnyoo/glance)（MIT）· 本分支基于 **v1.2**。

上游原版**没有任何本地化**，界面文案全部硬编码英文，也没有语言切换开关。本分支在源码层面做了简体中文化，并编译、签名、安装到本机 `/Applications/Glance.app`。

## 汉化范围

| 部分 | 说明 |
|---|---|
| 界面文案 | 348 处，覆盖引导流程、设置各标签页（通用 / 面容 / 摄像头 / 识别 / 密码 / 关于）、刘海浮层提示、错误提示、Face Lab 调试台 |
| 状态栏菜单 | 会话已锁定 / 设置 / 退出 |
| 系统菜单 | 编辑 / 显示 / 窗口 / 帮助（需 Info.plist 声明 `zh-Hans`，否则仍是英文） |
| 摄像头授权文案 | `NSCameraUsageDescription` 改为中文 |
| 保留英文 | 模型名（ArcFace、Vision 特征打印）、日志、代码注释（部分注释被连带替换） |

> 注意：不是 `Localizable.strings` 方案。Glance 的设置项是把字面量当 `String` 参数传给组件、组件里 `Text(String)` 逐字渲染的，**语言包对这类文案完全无效**，必须直接改源码字面量。

## 与原版的差异（都在工程里，重编必需）

1. `PRODUCT_BUNDLE_IDENTIFIER`：`com.jonathan.glance` → `com.imanity.glance`
   - 原因：本地 Xcode 没有登录上游作者的开发者账号，无法为其 bundle id 生成描述文件
   - 副作用：Sparkle 自动更新失效（好处是不会被英文版更新覆盖）
2. `DEVELOPMENT_TEAM`：改为 `S9A58XG98Z`
3. `glance/Info.plist` 追加：
   - `CFBundleDevelopmentRegion = zh-Hans`
   - `CFBundleLocalizations = [zh-Hans]`（系统菜单跟随变中文的关键）
   - `CFBundleIconFile` / `CFBundleIconName = GlanceIcon`
4. 图标：仓库里的 `glance/glanceicon.icon`（Icon Composer 格式）**不会被 actool 编进产物**，
   导致编译出来的 App 是空白图标。需从官方 dmg 的 App 里取出 `GlanceIcon.icns`，
   构建后复制进 `glance.app/Contents/Resources/`，并配上第 3 条的两个键。

## 构建步骤

前置：macOS 15+、Xcode 26+。

```bash
# 1) 编译（不签名，签名放到手动步骤，避免自动签名要求描述文件）
xcodebuild -project glance.xcodeproj -scheme glance -configuration Release \
  -derivedDataPath ./build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

APP=build/Build/Products/Release/glance.app

# 2) 放入图标（自备 GlanceIcon.icns，或从官方安装包中提取）
cp GlanceIcon.icns "$APP/Contents/Resources/"

# 3) 本地临时签名（钥匙串代码未使用 kSecAttrAccessGroup，无 entitlement 也能用）
codesign --force --deep -s - --timestamp=none "$APP"

# 4) 安装
rm -rf /Applications/Glance.app && ditto "$APP" /Applications/Glance.app
xattr -dr com.apple.quarantine /Applications/Glance.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Glance.app
```

如果 Xcode 已登录开发者账号，也可以直接 `CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates` 走正常签名。

## 安装后需要手动授权

1. **摄像头**：录入时系统会弹窗，选"允许"
2. **辅助功能**：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Glance（用来在锁屏输入密码）
3. **重新录入面容 + 密码**：临时签名与官方签名的钥匙串密钥不通用，
   官方版保存过的面容/密码无法迁移，必须重新设置一次

## 已知问题

- **升级会丢汉化**：任何来自官方渠道的更新都会替换成英文版；本构建无法通过 Sparkle 自动更新
- 用 ad-hoc 签名，`spctl` 判定为 `rejected`（本地已清 quarantine，正常运行无影响）；重编后 cdhash 变化，权限需要重新授予
- Face Lab（隐藏调试台：设置→关于→连点图标 5 次）的部分诊断文案也一并翻了（如"平面 / 立体诊断"）
- 少数由代码拼接的动态文案（例如 `Text(变量)`、状态枚举的字符串）需单独处理，本分支已随源码一并翻译

## 关于签名（本机用的是免费个人团队）

工程里已经写好 `DEVELOPMENT_TEAM = S89Z4QW6TN` 和 `PRODUCT_BUNDLE_IDENTIFIER = com.imanity.glance`，Xcode 登录 Apple ID 后直接：

```bash
xcodebuild -project glance.xcodeproj -scheme glance -configuration Release \
  -derivedDataPath ./build -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic
```

这样签出来的 App 带 `com.apple.application-identifier` 和 `keychain-access-groups`，钥匙串走原设计（会话密钥被 Secure Enclave 的 Touch ID 访问控制门控），源码里不需要任何改动。

**免费个人团队的描述文件只有 7 天**，过期后 App 会直接打不开。`tools/resign.sh` 就是干这个的：重编 + 重签 + 替换 `/Applications/Glance.app` + 重启，增量编译约 30 秒。重签不影响数据——签名身份是「团队号 + bundle id」，钥匙串条目、摄像头/辅助功能授权都不会失效，不用重新录面容。

（如果哪天手上有了付费账号，把 `DEVELOPMENT_TEAM` 换成付费团队即可，描述文件变成 1 年。）

## 上游发版后怎么重做汉化

`tools/localize-zh.py` 是本次汉化用的替换脚本（`MULTI` 多词整串 + `SINGLE` 单词按 UI 上下文），
上游改动不大的话直接重跑即可，再 `git diff` 检查新增英文：

```bash
python3 tools/localize-zh.py
git diff --stat          # 看还有哪些新文案没覆盖
xcodebuild ...           # 编译器会抓出替换引起的语法错误
```

## 许可

上游为 MIT，本分支沿用。原作者不接受 PR，仅供个人使用与参考。
