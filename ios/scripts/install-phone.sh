#!/bin/zsh
# Build Voice Type and put it on the 15 Pro Max, signing with the App Store Connect API key
# like the other iPhone apps, so no Xcode account is needed.
#   ios/scripts/install-phone.sh
#   BUILD_ONLY=1 ios/scripts/install-phone.sh
# Then ios/scripts/push-data.sh sends the word list, and the model if you'd rather not download it.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-Release}
DEVICE=${DEVICE:-00008130-001939C80483401C}
DD=${DD:-/tmp/voicetype-dd-device}
ASC_KEY_ID=${ASC_KEY_ID:-7SS6J9F98P}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-69a6de6f-a06e-47e3-e053-5b8c7c11a4d1}
ASC_KEY=${ASC_KEY:-$HOME/.config/poddle/AuthKey_$ASC_KEY_ID.p8}
taskpolicy -b xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  build | grep -E "^/.* error:| error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="$DD/Build/Products/$CONFIG-iphoneos/VoiceType.app"
[[ "${BUILD_ONLY:-0}" == 1 ]] && { echo "Built $APP"; exit 0; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
