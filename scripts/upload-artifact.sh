#!/usr/bin/env bash
#
# PUT the finished APK to the presigned artifact upload URL (blueprint §4.3 step 11).
# The URL is single-purpose (PUT, short-lived) and carries no credentials (ADR-07).
set -euo pipefail

UPLOAD_URL="${1:?artifact upload url is required}"
APK_PATH="${2:?apk path is required}"

if [ ! -f "$APK_PATH" ]; then
  echo "APK not found at $APK_PATH" >&2
  exit 1
fi

echo "Uploading $(basename "$APK_PATH") to the presigned storage URL (redacted)..."
curl -fsS --retry 3 --retry-delay 2 \
  -X PUT \
  -H "content-type: application/vnd.android.package-archive" \
  --upload-file "$APK_PATH" \
  -o /dev/null \
  "$UPLOAD_URL"

echo "Artifact upload complete"
