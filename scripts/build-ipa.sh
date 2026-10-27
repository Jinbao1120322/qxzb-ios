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
