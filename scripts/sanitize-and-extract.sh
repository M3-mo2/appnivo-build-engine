#!/usr/bin/env bash
#
# Extract the source into a sandbox and re-validate every entry for traversal
# (blueprint §11.2). Never extracts to a path derived from user input; a fresh
# `mktemp -d` is used and only allowlisted, relative entries are copied out.
#
# Before extracting, the declared entry count, uncompressed size and entry types
# (regular files/directories only) are re-checked so a zip-bomb or symlink-laden
# archive is rejected without touching the disk. The defaults mirror the
# server-side upload limits (`UPLOAD_MAX_ENTRIES`, `UPLOAD_MAX_UNCOMPRESSED_MB`).
set -euo pipefail

SOURCE_TYPE="${1:-ZIP}"
MAX_ENTRIES="${MAX_SOURCE_ENTRIES:-5000}"
MAX_UNCOMPRESSED_BYTES="${MAX_SOURCE_UNCOMPRESSED_BYTES:-262144000}"

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

contains_unsafe() {
  # Reject absolute paths, parent traversal, backslashes and very long names.
  # (A NUL arm is deliberately omitted: bash cannot hold NUL in a variable, and
  #  `...|*$'\0'*` collapses to `**`, which matches *every* entry.)
  local entry="$1"
  case "$entry" in
    /*|*..*|*\\*) return 0 ;;
  esac
  if [ "${#entry}" -gt 255 ]; then return 0; fi
  return 1
}

# Reject archives whose declared size/entry/type metadata is out of bounds.
# `unzip -Z -l` / `tar -tvzf` machine-readable lines start with the Unix mode.
guard_limits() {
  local size_column="$1" archive="$2" method="$3"
  if ! "$method" "$archive" | awk \
    -v maxEntries="$MAX_ENTRIES" \
    -v maxBytes="$MAX_UNCOMPRESSED_BYTES" \
    -v sizeColumn="$size_column" '
      /^[-dlcbps]/ {
        n++;
        if (n > maxEntries) { exit 2 }
        t = substr($1, 1, 1);
        if (t != "-" && t != "d") { exit 3 }
        total += $sizeColumn + 0;
        if (total > maxBytes) { exit 4 }
      }
    '; then
    fail SOURCE_INVALID_ZIP "Archive exceeds the entry, size or file-type limits."
  fi
}

unzip_meta() {
  unzip -Z -l "$1"
}

tar_meta() {
  tar -tvzf "$1"
}

SANDBOX="$(mktemp -d)"
STAGE="work/staged"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

if [ "$SOURCE_TYPE" = "ZIP" ]; then
  ARCHIVE="work/source.zip"

  guard_limits 4 "$ARCHIVE" unzip_meta

  while IFS= read -r entry; do
    if contains_unsafe "$entry"; then
      fail PATH_TRAVERSAL_DETECTED "Rejected unsafe ZIP entry: $entry"
    fi
  done < <(unzip -Z1 "$ARCHIVE")

  unzip -q "$ARCHIVE" -d "$SANDBOX"
else
  ARCHIVE="work/source.tar.gz"

  guard_limits 3 "$ARCHIVE" tar_meta

  while IFS= read -r entry; do
    if contains_unsafe "$entry"; then
      fail PATH_TRAVERSAL_DETECTED "Rejected unsafe tarball entry: $entry"
    fi
  done < <(tar -tzf "$ARCHIVE")

  tar -xzf "$ARCHIVE" -C "$SANDBOX"
fi

# Normalize a single wrapper directory (e.g. repo-main/ or mysite/).
ROOT="$SANDBOX"
mapfile -t TOP < <(find "$SANDBOX" -mindepth 1 -maxdepth 1)
if [ "${#TOP[@]}" -eq 1 ] && [ -d "${TOP[0]}" ]; then
  ROOT="${TOP[0]}"
fi

# Require at least one index.html at the normalized root. `-print -quit` avoids a
# `grep -q` pipe whose SIGPIPE would abort the script under `pipefail`.
if [ -z "$(find "$ROOT" -maxdepth 1 -iname 'index.html' -print -quit)" ]; then
  fail SOURCE_MISSING_INDEX "Source has no index.html at its root."
fi

cp -a "$ROOT/." "$STAGE/"

# Defence in depth: the declared sizes can lie, so re-check what actually landed.
STAGED_BYTES="$(du -sb "$STAGE" | awk '{print $1}')"
if [ "$STAGED_BYTES" -gt "$MAX_UNCOMPRESSED_BYTES" ]; then
  fail SOURCE_INVALID_ZIP "Extracted source is ${STAGED_BYTES} bytes, over the limit."
fi

echo "Extracted $(find "$STAGE" -type f | wc -l | tr -d ' ') files into $STAGE"
