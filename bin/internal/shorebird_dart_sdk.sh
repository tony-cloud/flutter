# Copyright 2026 The Open Shorebird Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Sourced by update_dart_sdk.sh. Resolves where the custom Dart SDK comes from
# and verifies it before anything runs it. Keep this file consistent with
# shorebird_dart_sdk.ps1, and with the precedence table in
# shorebird-workspace docs/HARDENING_CONTRACTS.md section 8.
#
# Trust path: bin/internal/shorebird_dart_sdk.pins is part of this git
# checkout. It pins the engine and Dart SDK revisions, an immutable release
# URL, and the SHA-256 and size of every archive. Only sha256 and curl are
# needed to check an archive, so the SDK is verified before it runs.
#
# Origin modes (SHOREBIRD_ORIGIN_MODE):
#   split (default)  The custom SDK comes from SHOREBIRD_DART_SDK_RELEASE_BASE_URL
#                    (flat layout), else SHOREBIRD_ARTIFACT_BASE_URL (storage
#                    layout under /shorebird), else the lock's base_url. A pinned
#                    digest (lock, or SHOREBIRD_DART_SDK_SHA256) is required.
#                    FLUTTER_STORAGE_BASE_URL is never used: it names an
#                    official-compatible origin, which has no custom SDK.
#   legacy-mirror    An all-in-one artifact proxy in Flutter storage layout.
#                    SHOREBIRD_DOWNLOAD_URL and SHOREBIRD_FLUTTER_STORAGE_BASE_URL
#                    (and FLUTTER_STORAGE_BASE_URL naming the open proxy
#                    http://localhost:8080/download.flutter.io) select it. Uses
#                    the pinned digest when there is one; otherwise installs an
#                    UNVERIFIED SDK with a warning.

SHOREBIRD_OPEN_PROXY_URL='http://localhost:8080/download.flutter.io'
SHOREBIRD_DART_SDK_LOCK="$FLUTTER_ROOT/bin/internal/shorebird_dart_sdk.pins"
SHOREBIRD_DART_SDK_IDENTITY="$FLUTTER_ROOT/bin/cache/engine-dart-sdk.identity"

shorebird::fail() {
  >&2 echo
  >&2 echo "Error: $1"
  shift
  local line
  for line in "$@"; do
    >&2 echo "  $line"
  done
  >&2 echo
  # Exit code 2: a configuration error that retrying cannot fix.
  exit 2
}

shorebird::trim_slash() {
  local value="$1"
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  printf '%s' "$value"
}

shorebird::reject_mutable() {
  case "$2" in
    */releases/latest|*/releases/latest/*)
      shorebird::fail "$1 names a mutable \"latest\" release: $2" \
        'Name an immutable release tag; the archive digest is pinned in bin/internal/shorebird_dart_sdk.pins.'
      ;;
  esac
}

# Sets SHOREBIRD_MODE (split|legacy-mirror) and, in legacy-mirror mode,
# SHOREBIRD_MIRROR_URL. Exits on conflicting overrides.
shorebird::resolve_origin_mode() {
  local legacy="" legacy_name="" name value
  for name in SHOREBIRD_DOWNLOAD_URL SHOREBIRD_FLUTTER_STORAGE_BASE_URL; do
    value="${!name:-}"
    [[ -z "$value" ]] && continue
    value="$(shorebird::trim_slash "$value")"
    if [[ -n "$legacy" && "$legacy" != "$value" ]]; then
      shorebird::fail "Conflicting artifact mirror overrides: $legacy_name=$legacy but $name=$value." \
        'Both name a legacy all-in-one artifact mirror. Set one of them, or neither.'
    fi
    legacy="$value"
    legacy_name="$name"
  done
  local official
  official="$(shorebird::trim_slash "${FLUTTER_STORAGE_BASE_URL:-}")"
  if [[ -z "$legacy" && "$official" == "$SHOREBIRD_OPEN_PROXY_URL" ]]; then
    legacy="$official"
    legacy_name=FLUTTER_STORAGE_BASE_URL
  fi
  case "${SHOREBIRD_ORIGIN_MODE:-}" in
    '')
      if [[ -n "$legacy" ]]; then SHOREBIRD_MODE=legacy-mirror; else SHOREBIRD_MODE=split; fi
      ;;
    split)
      if [[ -n "$legacy" ]]; then
        shorebird::fail "SHOREBIRD_ORIGIN_MODE=split conflicts with $legacy_name=$legacy, a legacy all-in-one mirror." \
          'Unset the mirror variable, or set SHOREBIRD_ORIGIN_MODE=legacy-mirror.'
      fi
      SHOREBIRD_MODE=split
      ;;
    legacy-mirror)
      SHOREBIRD_MODE=legacy-mirror
      if [[ -z "$legacy" ]]; then legacy="${official:-$SHOREBIRD_OPEN_PROXY_URL}"; fi
      ;;
    *)
      shorebird::fail "Unknown SHOREBIRD_ORIGIN_MODE=${SHOREBIRD_ORIGIN_MODE}." 'Use split (default) or legacy-mirror.'
      ;;
  esac
  if [[ "$SHOREBIRD_MODE" == legacy-mirror && -n "$official" && "$official" != "$legacy" ]]; then
    shorebird::fail "Conflicting artifact origins: FLUTTER_STORAGE_BASE_URL=$official but the legacy all-in-one mirror is $legacy." \
      'In legacy-mirror mode one mirror serves every artifact. Unset FLUTTER_STORAGE_BASE_URL or set it to the mirror.'
  fi
  SHOREBIRD_MIRROR_URL="$legacy"
}

# Reads the lock into LOCK_* variables. LOCK_MATCHES=1 when its identity is
# this checkout's (engine.version and DEPS dart_sdk_revision).
shorebird::read_lock() {
  LOCK_SCHEMA="" LOCK_VERSION="" LOCK_ENGINE="" LOCK_DART="" LOCK_BASE_URL="" LOCK_ASSETS="" LOCK_MATCHES=0
  CHECKOUT_DART="$(sed -n 's/^[[:space:]]*"dart_sdk_revision":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$FLUTTER_ROOT/DEPS" | head -n 1)"
  [[ -f "$SHOREBIRD_DART_SDK_LOCK" ]] || return 0
  local key a b c
  while read -r key a b c; do
    case "$key" in
      schema) LOCK_SCHEMA="$a" ;;
      contract_version) LOCK_VERSION="$a" ;;
      engine_revision) LOCK_ENGINE="$a" ;;
      dart_sdk_revision) LOCK_DART="$a" ;;
      base_url) LOCK_BASE_URL="$(shorebird::trim_slash "$a")" ;;
      asset) LOCK_ASSETS="$LOCK_ASSETS$a $b $c"$'\n' ;;
    esac
  done < <(tr -d '\r' < "$SHOREBIRD_DART_SDK_LOCK")
  if [[ "$LOCK_SCHEMA" != open-shorebird.dart-sdk-lock || "$LOCK_VERSION" != 1 ]]; then
    shorebird::fail "$SHOREBIRD_DART_SDK_LOCK is not an open-shorebird.dart-sdk-lock contract 1 file."
  fi
  if [[ "$LOCK_ENGINE" == "$ENGINE_VERSION" && -n "$CHECKOUT_DART" && "$LOCK_DART" == "$CHECKOUT_DART" ]]; then
    LOCK_MATCHES=1
  fi
}

# Exits on a malformed explicit pin. Call outside command substitution.
shorebird::check_explicit_pin() {
  if [[ -n "${SHOREBIRD_DART_SDK_SHA256:-}" && ! "$SHOREBIRD_DART_SDK_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    shorebird::fail 'SHOREBIRD_DART_SDK_SHA256 must be 64 lowercase hex digits.'
  fi
}

# Prints "<sha256> <size>" pinned for archive $1, or nothing.
shorebird::pinned_digest() {
  if [[ -n "${SHOREBIRD_DART_SDK_SHA256:-}" ]]; then
    printf '%s -\n' "$SHOREBIRD_DART_SDK_SHA256"
    return 0
  fi
  [[ "$LOCK_MATCHES" == 1 ]] || return 0
  local name sha size
  while read -r name sha size; do
    if [[ "$name" == "$1" ]]; then
      printf '%s %s\n' "$sha" "$size"
      return 0
    fi
  done <<< "$LOCK_ASSETS"
}

# Returns 0 when bin/cache/dart-sdk must be (re)installed.
shorebird::dart_sdk_needs_update() {
  [[ -f "$ENGINE_STAMP" && "$ENGINE_VERSION" == "$(< "$ENGINE_STAMP")" ]] || return 0
  # A stamp without an identity is an SDK provisioned outside this script (a
  # local engine build); it is kept, as before.
  [[ -f "$SHOREBIRD_DART_SDK_IDENTITY" ]] || return 1
  local engine dart zip sha pinned
  read -r engine dart zip sha < "$SHOREBIRD_DART_SDK_IDENTITY"
  shorebird::resolve_origin_mode
  shorebird::check_explicit_pin
  shorebird::read_lock
  [[ "$engine" == "$ENGINE_VERSION" ]] || return 0
  [[ -z "$CHECKOUT_DART" || "$dart" == "$CHECKOUT_DART" ]] || return 0
  pinned="$(shorebird::pinned_digest "$zip")"
  # Offline reuse: nothing newer is pinned, so the verified install stands.
  [[ -n "$pinned" ]] || return 1
  [[ "$sha" == "${pinned%% *}" ]] && return 1
  return 0
}

shorebird::sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    shorebird::fail 'Missing "sha256sum" or "shasum"; the Dart SDK cannot be verified before it runs.'
  fi
}

# Checks archive $1 against "<sha256> <size>" in $2. Returns 1 on mismatch.
shorebird::verify_archive() {
  local expected_sha="${2%% *}" expected_size="${2##* }" actual_size actual_sha
  if [[ "$expected_size" != - ]]; then
    actual_size="$(wc -c < "$1" | tr -d '[:space:]')"
    if [[ "$actual_size" != "$expected_size" ]]; then
      >&2 echo "Refusing $1: size $actual_size does not match the pinned $expected_size."
      return 1
    fi
  fi
  actual_sha="$(shorebird::sha256 "$1")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    >&2 echo "Refusing $1: sha256 $actual_sha does not match the pinned $expected_sha."
    return 1
  fi
}

# Sets DART_SDK_URL, DART_SDK_PIN ("<sha256> <size>" or empty) and
# DART_SDK_IDENTITY for archive $1, or exits with the reason none is usable.
shorebird::resolve_dart_sdk() {
  local zip="$1" layout_path="flutter_infra_release/flutter/$ENGINE_VERSION/$1"
  shorebird::resolve_origin_mode
  shorebird::check_explicit_pin
  command -v sha256sum > /dev/null 2>&1 || command -v shasum > /dev/null 2>&1 ||
    shorebird::fail 'Missing "sha256sum" or "shasum"; the Dart SDK cannot be verified before it runs.'
  shorebird::read_lock
  DART_SDK_PIN="$(shorebird::pinned_digest "$zip")"
  if [[ "$SHOREBIRD_MODE" == legacy-mirror ]]; then
    DART_SDK_URL="$SHOREBIRD_MIRROR_URL${ENGINE_REALM:+/$ENGINE_REALM}/$layout_path"
  elif [[ -n "${SHOREBIRD_DART_SDK_RELEASE_BASE_URL:-}" ]]; then
    local base
    base="$(shorebird::trim_slash "$SHOREBIRD_DART_SDK_RELEASE_BASE_URL")"
    shorebird::reject_mutable SHOREBIRD_DART_SDK_RELEASE_BASE_URL "$base"
    DART_SDK_URL="$base/$zip"
  elif [[ -n "${SHOREBIRD_ARTIFACT_BASE_URL:-}" ]]; then
    DART_SDK_URL="$(shorebird::trim_slash "$SHOREBIRD_ARTIFACT_BASE_URL")/shorebird/$layout_path"
  elif [[ "$LOCK_MATCHES" == 1 && -n "$LOCK_BASE_URL" ]]; then
    shorebird::reject_mutable "$SHOREBIRD_DART_SDK_LOCK base_url" "$LOCK_BASE_URL"
    DART_SDK_URL="$LOCK_BASE_URL/$zip"
  else
    DART_SDK_URL=""
  fi
  if [[ "$SHOREBIRD_MODE" == split && ( -z "$DART_SDK_URL" || -z "$DART_SDK_PIN" ) ]]; then
    local why
    if [[ "$LOCK_MATCHES" != 1 ]]; then
      why="bin/internal/shorebird_dart_sdk.pins pins engine ${LOCK_ENGINE:-none} and Dart SDK ${LOCK_DART:-none}, but this checkout pins engine $ENGINE_VERSION and Dart SDK ${CHECKOUT_DART:-unknown}."
    elif [[ -z "$LOCK_BASE_URL" ]]; then
      why="bin/internal/shorebird_dart_sdk.pins is unpublished: no verified archive exists yet for engine $ENGINE_VERSION and Dart SDK $CHECKOUT_DART."
    else
      why="bin/internal/shorebird_dart_sdk.pins publishes no $zip for this host."
    fi
    shorebird::fail "No verified custom Dart SDK ($zip) for this Flutter checkout." "$why" \
      'This SDK is patched; a stock Dart SDK is never substituted. Options:' \
      '- use a Flutter revision whose lock is published;' \
      '- serve the archive from SHOREBIRD_ARTIFACT_BASE_URL and pin it with SHOREBIRD_DART_SDK_SHA256;' \
      '- install a locally built SDK into bin/cache/dart-sdk;' \
      '- or SHOREBIRD_ORIGIN_MODE=legacy-mirror with an artifact proxy (compatibility only).'
  fi
  if [[ -n "$DART_SDK_PIN" ]]; then
    DART_SDK_IDENTITY="$ENGINE_VERSION ${CHECKOUT_DART:--} $zip ${DART_SDK_PIN%% *}"
  else
    >&2 echo
    >&2 echo "WARNING: installing an UNVERIFIED Dart SDK from the legacy all-in-one mirror"
    >&2 echo "  $DART_SDK_URL"
    >&2 echo "  No digest is pinned for engine $ENGINE_VERSION. Publish the lock or set SHOREBIRD_DART_SDK_SHA256."
    >&2 echo
    DART_SDK_IDENTITY="$ENGINE_VERSION ${CHECKOUT_DART:--} $zip unverified"
  fi
}

# Downloads (or reuses) the archive at $1 and verifies it against DART_SDK_PIN.
# A verified archive already at $1 is reused without any network access.
shorebird::fetch_dart_sdk() {
  local archive="$1" partial="$1.partial" verbose_curl=""
  if [[ -n "$DART_SDK_PIN" && -f "$archive" ]]; then
    if shorebird::verify_archive "$archive" "$DART_SDK_PIN"; then
      >&2 echo "Reusing the verified Dart SDK archive $archive."
      return 0
    fi
    rm -f -- "$archive"
  fi
  if [[ -n "$LUCI_CI" ]]; then
    verbose_curl="--verbose"
  fi
  curl ${verbose_curl} --fail --retry 3 --continue-at - --location --output "$partial" "$DART_SDK_URL" 2>&1 || {
    curlExitCode=$?
    # 33: HTTP range error; retry without resuming (see update_dart_sdk.sh).
    if [ "$curlExitCode" -ne 33 ]; then
      rm -f -- "$partial"
      return "$curlExitCode"
    fi
    rm -f -- "$partial"
    curl ${verbose_curl} --fail --retry 3 --location --output "$partial" "$DART_SDK_URL" 2>&1
  } || {
    rm -f -- "$partial"
    return 1
  }
  if [[ -n "$DART_SDK_PIN" ]] && ! shorebird::verify_archive "$partial" "$DART_SDK_PIN"; then
    rm -f -- "$partial"
    shorebird::fail "The Dart SDK archive from $DART_SDK_URL does not match its pinned digest." \
      'It was deleted without being unpacked or run. The mirror or release serves different bytes.'
  fi
  mv -f -- "$partial" "$archive"
}

shorebird::record_dart_sdk_identity() {
  echo "$DART_SDK_IDENTITY" > "$SHOREBIRD_DART_SDK_IDENTITY"
}
