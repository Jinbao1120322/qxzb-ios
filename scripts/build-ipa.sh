#!/usr/bin/env bash
# 本地(Mac)构建未签名 IPA。Windows 上无法运行，请用 GitHub Actions。
# 用法: ./scripts/build-ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1/5] 准备 web/ (若缺失则从 CDN 抓取)"
if [ ! -f web/index.html ]; then
  python3 tools/fetch_h5.py --out web --jobs 24
fi
du -sh web

echo "[2/5] 生成 Xcode 工程"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
# 兼容 Xcode 15：把项目格式强制降到 objectVersion 56
PBX=QXZB.xcodeproj/project.pbxproj
sed -i '' -E 's/objectVersion = [0-9]+;/objectVersion = 56;/' "$PBX"
sed -i '' -E 's/compatibilityVersion = "Xcode [0-9.]+";/compatibilityVersion = "Xcode 14.0";/' "$PBX"
sed -i '' -E '/preferredProjectObjectVersion = [0-9]+;/d' "$PBX"
grep -E 'objectVersion|compatibilityVersion' "$PBX" | head -3

echo "[3/5] 编译 (未签名)"
xcodebuild \
  -project QXZB.xcodeproj \
  -scheme QXZB \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build

echo "[4/5] 打包 IPA"
APP="build/Build/Products/Release-iphoneos/QXZB.app"
rm -rf Payload QXZB-unsigned.ipa
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry QXZB-unsigned.ipa Payload

echo "[5/5] 完成"
ls -lh QXZB-unsigned.ipa
