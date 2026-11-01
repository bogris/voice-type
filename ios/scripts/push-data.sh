#!/bin/zsh
# Sends the Mac's word list and corrections to the phone (the repo is public, so they aren't in it).
# With --model it also sends the model files, skipping the 2 GB download on the phone.
#   ios/scripts/push-data.sh [--model]
set -euo pipefail
DEVICE=${DEVICE:-00008130-001939C80483401C}
BUNDLE=com.mikecann.voicetype
MODELS=${MODELS:-$HOME/dev/me/voice-type-benchmark/models/whispercpp}
copy() { xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" --source "$1" --destination "$2" >/dev/null; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
/usr/bin/python3 - "$HOME/Library/Application Support/Voice Type/settings.json" "$tmp/settings.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
json.dump({k: settings[k] for k in ("vocabulary", "corrections") if k in settings}, open(sys.argv[2], "w"), indent=2)
print("words:", len(settings.get("vocabulary") or []))
PY
copy "$tmp/settings.json" Documents/settings.json

if [[ "${1:-}" == --model ]]; then
  # The encoder goes up before the weights: the app counts the model as there once both exist,
  # so an interrupted copy can't look finished for long.
  copy "$MODELS/ggml-large-v3-turbo-encoder.mlmodelc" Documents/models/ggml-large-v3-turbo-encoder.mlmodelc
  copy "$MODELS/ggml-large-v3-turbo-q8_0.bin" Documents/models/ggml-large-v3-turbo-q8_0.bin
fi
echo pushed
