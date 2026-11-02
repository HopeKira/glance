#!/bin/bash
# 重新编译 + 重新签名 + 替换 /Applications/Glance.app
# 免费 Apple 个人团队的描述文件只有 7 天，过期后 App 会无法启动；
# 这个脚本用来自动续期（xcodebuild -allowProvisioningUpdates 会拉新描述文件并重签）。
# 签名身份（团队号 + bundle id）不变，所以钥匙串条目、摄像头/辅助功能授权都不受影响。
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP="$SRC/build/Build/Products/Release/glance.app"
LOG="/tmp/glance-resign.log"

cd "$SRC"
echo "[$(date '+%F %T')] 开始编译" >>"$LOG"
if ! xcodebuild -project glance.xcodeproj -scheme glance -configuration Release \
    -derivedDataPath ./build -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic >>"$LOG" 2>&1; then
    echo "[$(date '+%F %T')] 编译失败，放弃安装" >>"$LOG"
    exit 1
fi

codesign --verify --deep --strict "$APP" || { echo "签名校验失败" >>"$LOG"; exit 1; }

osascript -e 'quit app "Glance"' 2>/dev/null || true
sleep 2
rm -rf /Applications/Glance.app
ditto "$APP" /Applications/Glance.app
xattr -dr com.apple.quarantine /Applications/Glance.app 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Glance.app
open -a /Applications/Glance.app

EXPIRES=$(security cms -D -i /Applications/Glance.app/Contents/embedded.provisionprofile 2>/dev/null \
    | plutil -extract ExpirationDate raw - 2>/dev/null || echo "unknown")
echo "[$(date '+%F %T')] 完成，描述文件到期：$EXPIRES" >>"$LOG"
