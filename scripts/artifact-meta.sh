#!/usr/bin/env bash
#
# Compute APK artifact metadata and expose it to later steps (blueprint §4.3).
set -euo pipefail

# `-print -quit` returns the first match without a `head` pipe, so `pipefail`
# cannot abort the script on a SIGPIPE'd `find`.
APK_PATH="$(find android-template/app/build/outputs/apk/release -maxdepth 1 -name '*.apk' -print -quit 2>/dev/null || true)"
if [ -z "$APK_PATH" ]; then
  echo "No release APK was produced" >&2
  exit 1
fi

SHA256="$(sha256sum "$APK_PATH" | awk '{print $1}')"
SIZE_BYTES="$(wc -c < "$APK_PATH" | tr -d ' ')"

mkdir -p work
{
  echo "APK_PATH=$APK_PATH"
  echo "SHA256=$SHA256"
  echo "SIZE_BYTES=$SIZE_BYTES"
} > work/meta.env

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "apkPath=$APK_PATH"
    echo "sha256=$SHA256"
    echo "sizeBytes=$SIZE_BYTES"
  } >> "$GITHUB_OUTPUT"
fi

echo "APK $APK_PATH sha256=$SHA256 size=$SIZE_BYTES"
