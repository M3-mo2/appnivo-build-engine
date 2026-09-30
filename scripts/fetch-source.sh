#!/usr/bin/env bash
#
# Download the pre-signed source artifact (blueprint §4.3 step 6).
#
# All secret-bearing material arrives as short-lived, single-purpose presigned
# URLs (ADR-07); no credentials are available to this job.
#
# The download is size- and time-bounded so a hostile or oversized artifact
# cannot exhaust the runner's disk or stall the job. The ceiling mirrors the
# server-side `UPLOAD_MAX_SIZE_MB` (50 MiB) unless `MAX_SOURCE_BYTES` overrides.
set -euo pipefail

SOURCE_URL="${1:?source url is required}"
SOURCE_TYPE="${2:-ZIP}"
MAX_SOURCE_BYTES="${MAX_SOURCE_BYTES:-52428800}"
MAX_FETCH_SECONDS="${MAX_FETCH_SECONDS:-300}"

# Report a typed build-engine error code to the workflow (see §9.4 enum).
fail() {
  local code="$1"
  shift
  echo "Build input rejected [$code]: $*" >&2
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "BUILD_FAILURE_CODE=$code"
      echo "BUILD_FAILURE_MESSAGE=$*"
    } >> "$GITHUB_ENV"
  fi
  exit 1
}

mkdir -p work

case "$SOURCE_TYPE" in
  ZIP)
    OUT="work/source.zip"
    ;;
  GITHUB_TARBALL|*)
    OUT="work/source.tar.gz"
    ;;
esac

echo "Fetching $SOURCE_TYPE source from the presigned URL (redacted)..."
if curl -fsSL --retry 3 --retry-delay 2 \
  --max-time "$MAX_FETCH_SECONDS" \
  --max-filesize "$MAX_SOURCE_BYTES" \
  -o "$OUT" "$SOURCE_URL"; then
  :
else
  curl_rc=$?
  # curl exit 63 == "maximum file size exceeded".
  if [ "$curl_rc" -eq 63 ]; then
    fail SOURCE_TOO_LARGE "Source exceeds the ${MAX_SOURCE_BYTES}-byte limit."
  fi
  fail SOURCE_FETCH_FAILED "Could not download the source artifact from the presigned URL."
fi

BYTES="$(wc -c < "$OUT" | tr -d ' ')"
if [ "$BYTES" -le 0 ]; then
  fail SOURCE_FETCH_FAILED "Downloaded source is empty."
fi
if [ "$BYTES" -gt "$MAX_SOURCE_BYTES" ]; then
  fail SOURCE_TOO_LARGE "Source is ${BYTES} bytes, over the ${MAX_SOURCE_BYTES}-byte limit."
fi

echo "Downloaded $BYTES bytes to $OUT"
