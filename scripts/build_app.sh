#!/bin/bash
# macOS 앱 번들(.app)과 디스크 이미지(.dmg)를 만든다.
#   사용: scripts/build_app.sh [--sign "Developer ID Application: 이름 (TEAMID)"] [--notarize 키체인프로필]
#   결과: dist/라이선스 관리.app, dist/LicenseManager-<버전>.dmg
#
# 서명을 지정하지 않으면 임시(ad-hoc) 서명만 한다. 이 경우 처음 실행할 때 Finder에서
# 앱을 Control-클릭 → '열기'를 고르거나, 시스템 설정 → 개인정보 보호 및 보안 → '그래도 열기'를 누른다.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
BUILD="1"
APP_NAME="라이선스 관리"
BUNDLE_ID="kr.lms.LicenseManager"
SIGN_ID="-"
NOTARY_PROFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sign) SIGN_ID="$2"; shift 2 ;;
    --notarize) NOTARY_PROFILE="$2"; shift 2 ;;
    *) echo "알 수 없는 옵션: $1"; exit 2 ;;
  esac
done

echo "== 빌드(release, arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LicenseManager"

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LicenseManager"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>LicenseManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.business</string>
  <key>NSHumanReadableCopyright</key><string>판매자 전용 라이선스 관리 도구</string>
</dict>
</plist>
PLIST

echo "== 서명($SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --verbose=2 "$APP"

echo "== 디스크 이미지"
DMG="dist/LicenseManager-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "$NOTARY_PROFILE" ]; then
  [ "$SIGN_ID" != "-" ] || { echo "공증하려면 Developer ID 서명이 필요합니다(--sign)."; exit 2; }
  codesign --sign "$SIGN_ID" --timestamp "$DMG"
  echo "== 공증(notarytool, 프로필 $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "완료: $APP"
echo "      $DMG"
