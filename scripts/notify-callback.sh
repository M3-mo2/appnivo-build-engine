#!/usr/bin/env bash
#
# Sign and POST the build callback to AppNivo (blueprint §4.3 step 12, §4.4).
#
# Usage: bash scripts/notify-callback.sh <succeeded|failed>
#
# The payload is exactly the documented contract (blueprint §9.4). The signature
# is HMAC-SHA256 over "{timestamp}.{rawBody}" with a `sha256=` prefix, matching
# the server's verification order. Delivery retries 3x with exponential backoff
# (2s/8s/30s); the endpoint is idempotent (ADR-08/ADR-18).
set -euo pipefail

STATUS="${1:?usage: notify-callback.sh <succeeded|failed>}"
: "${BUILD_WEBHOOK_SECRET:?BUILD_WEBHOOK_SECRET is required}"
: "${BUILD_JOB_ID:?BUILD_JOB_ID is required}"
: "${APP_ID:?APP_ID is required}"
: "${CALLBACK_URL:?CALLBACK_URL is required}"

RUN_ID="${GITHUB_RUN_ID:-unknown}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-org/repo}/actions/runs/${RUN_ID}"
PACKAGE="${PACKAGE_NAME:-com.appnivo.app}"
VERSION_NAME_VALUE="${VERSION_NAME:-1.0.0}"
VERSION_CODE_VALUE="${VERSION_CODE:-1}"

if [ "$STATUS" = "succeeded" ]; then
  EVENT="build.succeeded"
  STATUS_UPPER="SUCCEEDED"
else
  EVENT="build.failed"
  STATUS_UPPER="FAILED"
fi

# `signed` reflects whether a real release keystore was available (blueprint §9.3).
SIGNED=false
if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  SIGNED=true
fi

STARTED_AT="${BUILD_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS="$(date +%s)"
NONCE="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || node -e 'console.log(crypto.randomUUID())')"

# Artifact metadata (written by scripts/artifact-meta.sh) — success only.
ARTIFACT_JSON="null"
if [ "$STATUS" = "succeeded" ]; then
  if [ -f work/meta.env ]; then
    # shellcheck disable=SC1091
    . work/meta.env
  fi
  # The server is authoritative for the storage key; this value is only echoed
  # for audit and is derived from the presigned upload URL when possible.
  STORAGE_KEY="${APK_PATH:+$(basename "$APK_PATH")}"
  STORAGE_KEY="${STORAGE_KEY:-${PACKAGE}-${VERSION_NAME_VALUE}.apk}"
  ARTIFACT_JSON="$(jq -n \
    --arg k "$STORAGE_KEY" \
    --arg sha "${SHA256:-}" \
    --argjson size "${SIZE_BYTES:-0}" \
    --arg vn "$VERSION_NAME_VALUE" \
    --argjson vc "$VERSION_CODE_VALUE" \
    '{storageKey:$k,sha256:$sha,sizeBytes:$size,versionName:$vn,versionCode:$vc}')"
fi

ERROR_JSON="null"
if [ "$STATUS" = "failed" ]; then
  ERROR_JSON="$(jq -n \
    --arg c "${BUILD_ERROR_CODE:-GRADLE_FAILED}" \
    --arg m "${BUILD_ERROR_MESSAGE:-The build job failed. See the workflow run logs.}" \
    '{code:$c,message:$m}')"
fi

BODY="$(jq -n \
  --arg event "$EVENT" \
  --arg buildJobId "$BUILD_JOB_ID" \
  --arg appId "$APP_ID" \
  --arg githubRunId "$RUN_ID" \
  --arg githubRunUrl "$RUN_URL" \
  --arg status "$STATUS_UPPER" \
  --arg startedAt "$STARTED_AT" \
  --arg finishedAt "$FINISHED_AT" \
  --argjson signed "$SIGNED" \
  --argjson artifact "$ARTIFACT_JSON" \
  --argjson error "$ERROR_JSON" \
  --arg logsUrl "$RUN_URL" \
  --argjson timestamp "$TS" \
  --arg nonce "$NONCE" \
  '{event:$event,buildJobId:$buildJobId,appId:$appId,githubRunId:$githubRunId,githubRunUrl:$githubRunUrl,status:$status,startedAt:$startedAt,finishedAt:$finishedAt,signed:$signed,artifact:$artifact,error:$error,logsUrl:$logsUrl,timestamp:$timestamp,nonce:$nonce}')"

SIG="sha256=$(printf '%s.%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$BUILD_WEBHOOK_SECRET" | sed 's/^.*= //')"

echo "Notifying AppNivo: $EVENT (job $BUILD_JOB_ID)"
for delay in 0 2 8 30; do
  if [ "$delay" -gt 0 ]; then sleep "$delay"; fi
  HTTP="$(curl -sS -o /tmp/appnivo-callback-resp -w '%{http_code}' \
    -X POST "$CALLBACK_URL" \
    -H 'Content-Type: application/json' \
    -H "X-AppNivo-Signature: $SIG" \
    -H "X-AppNivo-Timestamp: $TS" \
    --data-raw "$BODY" || true)"
  echo "  attempt (backoff ${delay}s) -> HTTP ${HTTP}: $(cat /tmp/appnivo-callback-resp 2>/dev/null || true)"
  case "$HTTP" in
    2*) exit 0 ;;
    4??)
      # 4xx (except 429) is terminal — e.g. a bad signature or payload will not
      # succeed on retry, so fail fast instead of hammering the server.
      if [ "$HTTP" != "429" ]; then
        echo "AppNivo callback rejected with HTTP ${HTTP}; not retrying." >&2
        break
      fi
      ;;
  esac
done

echo "AppNivo callback failed after retries" >&2
exit 1
