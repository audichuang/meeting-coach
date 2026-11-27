#!/bin/zsh
# Archive and upload to TestFlight. Signing uses the Apple account logged into Xcode
# (an API key failed with "bearer token" on Xcode 27.2 in another app, 2026-11-15).
# App Store Connect app id 6840169416. Build number is required:
#   BUILD_NUMBER=$(tf next-build --app 6840169416) ./scripts/testflight.sh
set -euo pipefail
cd "${0:A:h}/.."
# exportArchive needs the system rsync; Homebrew rsync makes it fail with "Copy failed".
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

: "${BUILD_NUMBER:?set BUILD_NUMBER (use: tf next-build --app 6840169416)}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
OUT="build/testflight-${BUILD_NUMBER}"
mkdir -p "$OUT"

# Without these the build ships with "missing server credentials" and the coach cannot work.
for key in COACH_WORKER_HOST COACH_ACCESS_CLIENT_ID COACH_ACCESS_CLIENT_SECRET; do
  if ! grep -Eq "^${key}[[:space:]]*=[[:space:]]*[^[:space:]]+" Config/Secrets.xcconfig 2>/dev/null; then
    echo "Config/Secrets.xcconfig 缺少 ${key}" >&2; exit 1
  fi
done

if ! xcodebuild -project Kurn.xcodeproj -scheme Kurn -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "${OUT}/Kurn.xcarchive" \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR:-$HOME/Project/meeting-assistant-kurn-wt/SourcePackages-baseline}" \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates archive > "${OUT}/archive.log" 2>&1; then
  { grep -E "error:|BUILD FAILED|ARCHIVE FAILED" "${OUT}/archive.log" || true; } | tail -20
  echo "archive 失敗，完整 log：${OUT}/archive.log"; exit 1
fi

# The coach reads these from Info.plist; check they survived into the archive (lengths only).
plist="${OUT}/Kurn.xcarchive/Products/Applications/Kurn.app/Info.plist"
for key in CoachWorkerHost CoachAccessClientID CoachAccessClientSecret; do
  len=$(/usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null | wc -c | tr -d ' ')
  if [[ "${len:-0}" -le 1 ]]; then echo "archive 的 Info.plist 缺少 ${key}" >&2; exit 1; fi
done

# sherpa-onnx auto-embeds a static onnxruntime.framework that nothing loads; Apple rejects it
# (ITMS-90208). Strip it and resign, as upstream's fastlane beta lane does (see fastlane/Fastfile).
app="${OUT}/Kurn.xcarchive/Products/Applications/Kurn.app"
stripped=0
for name in onnxruntime onnxruntime_extensions; do
  [[ -d "${app}/Frameworks/${name}.framework" ]] && { rm -rf "${app}/Frameworks/${name}.framework"; stripped=1; }
done
if (( stripped )); then
  identity=$(codesign -dvv "$app" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2)
  [[ -n "$identity" ]] || { echo "找不到 archive 的簽章身分，無法重簽" >&2; exit 1; }
  codesign --force --sign "$identity" --preserve-metadata=identifier,entitlements,flags "$app"
  codesign --verify --deep --strict "$app"
fi

if ! xcodebuild -exportArchive -archivePath "${OUT}/Kurn.xcarchive" -exportOptionsPlist ExportOptions.plist \
  -exportPath "${OUT}/export" -allowProvisioningUpdates > "${OUT}/export.log" 2>&1; then
  tail -30 "${OUT}/export.log"; echo "上傳失敗，完整 log：${OUT}/export.log"; exit 1
fi
echo "已上傳 build ${BUILD_NUMBER}（${MARKETING_VERSION}）；App Store Connect 處理約 5～15 分鐘後會出現在 TestFlight。"
