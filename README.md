# AppNivo Build Engine (template)

This directory is a **template for the external GitHub repository** that AppNivo
dispatches to build Android APKs. AppNivo itself never compiles Android; it signs
short-lived storage URLs, calls `workflow_dispatch` (ADR-07), and waits for an
HMAC-signed callback (ADR-08).

```
AppNivo ──workflow_dispatch(inputs)──► this repo (GitHub Actions)
   ▲                                         │
   │  presigned GET source (2h)              │ fetch → sanitize → inject → gradle
   │  presigned PUT apk    (4h)              │ PUT apk → signed callback
   └──────────── HMAC callback ──────────────┘
```

## 1. Provision the repository

1. Create a **private** repository, e.g. `your-org/appnivo-build-engine`.
2. Copy the contents of this folder (`build-engine/`) to the repo root:
   ```
   .github/workflows/build-apk.yml
   scripts/{fetch-source.sh,sanitize-and-extract.sh,inject-assets.mjs,artifact-meta.sh,upload-artifact.sh,notify-callback.sh}
   android-template/**
   ```
3. Push to the default branch (the workflow input `GITHUB_BUILD_REF`, default
   `main`).
4. Generate an **ephemeral Gradle wrapper** (optional but recommended) so the
   binary `gradle-wrapper.jar` is committed:
   ```
   cd android-template
   gradle wrapper --gradle-version 8.7
   git add gradlew gradlew.bat gradle/wrapper && git commit -m "chore: gradle wrapper"
   ```
   The committed `gradlew` is **self-bootstrapping**: if the wrapper jar is
   absent (as in this template) it falls back to a system `gradle`, then to
   downloading the distribution declared in
   `gradle/wrapper/gradle-wrapper.properties`. The workflow therefore works
   with or without the jar.

## 2. Repository secrets

| Secret | Required | Purpose |
|---|---|---|
| `BUILD_WEBHOOK_SECRET` | **Yes** | HMAC-SHA256 key used to sign the callback. Must equal AppNivo's `BUILD_WEBHOOK_SECRET`. |
| `ANDROID_KEYSTORE_BASE64` | Optional | Release keystore (base64, `base64 -w0 keystore.jks`). |
| `ANDROID_KEYSTORE_PASSWORD` | Optional | Keystore password. |
| `ANDROID_KEY_ALIAS` | Optional | Key alias. |
| `ANDROID_KEY_PASSWORD` | Optional | Key password. |

If the keystore secrets are absent the APK is **debug-signed** and the callback
sends `"signed": false`; the AppNivo UI shows an "unsigned/debug-signed" warning
badge (blueprint §9.3).

## 3. AppNivo-side configuration

Set these in AppNivo's environment (`.env`):

```
GITHUB_BUILD_OWNER=your-org
GITHUB_BUILD_REPO=appnivo-build-engine
GITHUB_BUILD_WORKFLOW_FILE=build-apk.yml
GITHUB_BUILD_REF=main
GITHUB_BUILD_TOKEN=ghp_xxx        # fine-grained PAT with Actions: read/write on the build repo
BUILD_WEBHOOK_SECRET=<same value as the repo secret>
APP_BASE_URL=https://your-appnivo-host   # must be reachable from the runner
```

When these are missing, `triggerBuild` returns `BUILD_ENGINE_NOT_CONFIGURED`
(HTTP 503) and the dashboard renders a setup card instead of crashing.

`APP_BASE_URL` must be a **public** URL: a GitHub-hosted runner resolves
`localhost`/private addresses to itself, so every source GET, APK PUT and
callback would fail. `triggerBuild` refuses to dispatch in that case with
`APP_BASE_URL_NOT_PUBLIC` (HTTP 503). For a self-hosted runner co-located with
AppNivo, set `BUILD_ENGINE_ALLOW_PRIVATE_BASE_URL=true` to allow a loopback URL.

## 4. Workflow inputs (exact contract, blueprint §9.1)

`buildJobId, appId, appName, packageName, versionName, versionCode, sourceUrl,
sourceType, artifactUploadUrl, callbackUrl, minSdk, targetSdk`.

- `sourceUrl` — presigned **GET** of the source artifact, TTL 2h.
- `artifactUploadUrl` — presigned **PUT** for the APK, TTL 4h.
- No raw credentials are ever placed in inputs; URLs are single-purpose and
  short-lived (ADR-07).

Passing an input not declared in `workflow_dispatch` makes the GitHub API reject
the dispatch with `422`, so the input list above is authoritative.

## 5. Callback contract (blueprint §9.4)

`scripts/notify-callback.sh` builds and signs the JSON payload:

```jsonc
{
  "event": "build.succeeded",              // build.started | build.succeeded | build.failed
  "buildJobId": "clx…",
  "appId": "clx…",
  "githubRunId": "1234567890",
  "githubRunUrl": "https://github.com/org/repo/actions/runs/1234567890",
  "status": "SUCCEEDED",                   // SUCCEEDED | FAILED
  "startedAt": "2026-09-29T10:00:00Z",
  "finishedAt": "2026-09-29T10:04:12Z",
  "signed": true,
  "artifact": { "storageKey": "…", "sha256": "…", "sizeBytes": 4831234,
                "versionName": "1.0.0", "versionCode": 1 },   // null on failure
  "error": null,                           // { "code": "GRADLE_FAILED", "message": "…" } on failure
  "logsUrl": "https://github.com/org/repo/actions/runs/1234567890",
  "timestamp": 1790000000,
  "nonce": "b6f1c0e2-…"
}
```

Signature (header `X-AppNivo-Signature: sha256=…`, `X-AppNivo-Timestamp: <epoch seconds>`):

```
HMAC-SHA256(BUILD_WEBHOOK_SECRET, "{timestamp}.{rawBody}")
```

The server recomputes it with `timingSafeEqual` and rejects callbacks older than
300s (replay window). Delivery retries 3× with 2s/8s/30s backoff; the endpoint is
idempotent, so retries are safe.

The server is **authoritative for the APK storage key**: it records the key it
signed at dispatch time and ignores the callback's `storageKey` (which is only a
fallback for synthetic jobs, e.g. the dev simulator).

On failure, `error.code` is derived from the step that actually failed rather
than a hard-coded `GRADLE_FAILED`:

| Failing step | `error.code` |
|---|---|
| fetch source | `SOURCE_FETCH_FAILED` / `SOURCE_TOO_LARGE` |
| sanitize & extract | `SOURCE_INVALID_ZIP`, `SOURCE_MISSING_INDEX`, `PATH_TRAVERSAL_DETECTED` |
| inject assets | `UNKNOWN` |
| gradle build | `GRADLE_FAILED` |
| artifact metadata | `UNKNOWN` |
| upload artifact | `ARTIFACT_UPLOAD_FAILED` |
| anything else | `UNKNOWN` |

The failure callback is only sent when a step other than the success callback
fails, so a failed success-callback delivery never masquerades as a build
failure.

## 6. Pipeline steps

`fetch-source.sh` → `sanitize-and-extract.sh` → `inject-assets.mjs` →
`gradlew assembleRelease` → `artifact-meta.sh` → `upload-artifact.sh` →
`notify-callback.sh`.

- The download is bounded by `MAX_SOURCE_BYTES` (default 50 MiB, mirroring
  `UPLOAD_MAX_SIZE_MB`) and `MAX_FETCH_SECONDS` (default 300).
- Before extraction the declared entry count, uncompressed size and entry types
  are checked (defaults: `MAX_SOURCE_ENTRIES=5000`,
  `MAX_SOURCE_UNCOMPRESSED_BYTES=262144000`); symlinks/hardlinks/devices and
  zip-bombs are rejected. Extraction happens in a fresh `mktemp -d` sandbox;
  every archive entry is re-validated for traversal/absolute/backslash/long
  names, and the extracted size is re-checked afterwards (blueprint §11.2).
- A single wrapper directory is normalized away; an `index.html` at the
  normalized root is required.
- `inject-assets.mjs` rewrites `__PACKAGE_NAME__`, `__APP_NAME__`,
  `__VERSION_NAME__`, `__VERSION_CODE__`, `__MIN_SDK__`, `__TARGET_SDK__` and
  `__CLEARTEXT__` in the Android project, then copies the staged site into
  `app/src/main/assets`. Values are substituted in a single pass and
  XML-escaped for `AndroidManifest.xml`/`strings.xml`, so an app name such as
  `Tom & Jerry` cannot break the build or inject XML.

## 7. Testing without a real Actions run

From the AppNivo repo, against a running dev server and database:

```
pnpm tsx scripts/dev/simulate-build-callback.ts --app <appId> --status succeeded
pnpm tsx scripts/dev/simulate-build-callback.ts --app <appId> --status failed
```

The simulator creates a `QUEUED` `BuildJob` if needed, writes a dummy APK to
local storage, signs a callback and POSTs it to `/api/webhooks/build`, exercising
the full state machine and `App` APK metadata path.

## 8. Troubleshooting

- **`422 Unexpected inputs provided`** — an undeclared input was sent; compare
  with §4 above.
- **Callback `401 INVALID_SIGNATURE`** — `BUILD_WEBHOOK_SECRET` differs between
  AppNivo and the repo, or the runner clock is skewed past the 300s window.
- **Callback never arrives** — `APP_BASE_URL` is not reachable from GitHub
  runners (use a public URL or a tunnel; see blueprint §13.4). Dispatch now
  fails fast with `APP_BASE_URL_NOT_PUBLIC` instead of producing a doomed run.
- **`ARTIFACT_MISSING`** — the success callback arrived before/without the APK
  PUT; ensure the upload step runs before the notify step (it does by default).
- **Gradle cannot find an SDK** — confirm the `Install Android SDK packages` step
  ran (it installs `platforms;android-34` and `build-tools;34.0.0`).
