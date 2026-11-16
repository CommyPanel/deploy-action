#!/usr/bin/env bash
# Installs a pinned, checksum-verified commy and runs one deployment. Everything the workflow passes in
# arrives as an environment variable (never spliced into this script), and is checked before it is used.
set -euo pipefail

readonly REPO="CommyPanel/commy-cli"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "::error::$*"
    exit 1
}

# --- checks on what the workflow gave us -------------------------------------------------------------

valid_app()     { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; }
valid_timeout() { [[ "$1" =~ ^[0-9]{1,5}[smh]$ ]]; }
valid_sha256()  { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_url() {
    [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] && return 0
    [[ "$1" =~ ^https://\[[0-9A-Fa-f:]+\](:[0-9]{1,5})?/?$ ]] && return 0

    # For this repository's own tests only: a fake panel on this machine, over plain http.
    [ "${COMMY_ACTION_ALLOW_HTTP_LOCALHOST:-}" = 1 ] && [[ "$1" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?/?$ ]]
}

# --- which binary ------------------------------------------------------------------------------------

# Sets PLATFORM to "<os>_<arch>" for the runner, or fails. (Functions set globals instead of printing, because a
# failure inside $(...) would be swallowed with its message.)
platform() {
    local os arch
    case "${RUNNER_OS:-$(uname -s)}" in
        Linux) os=linux ;;
        macOS|Darwin) os=darwin ;;
        *) fail "This action runs on Linux and macOS runners (not ${RUNNER_OS:-unknown})." ;;
    esac
    case "${RUNNER_ARCH:-$(uname -m)}" in
        X64|x86_64|amd64) arch=amd64 ;;
        ARM64|arm64|aarch64) arch=arm64 ;;
        *) fail "Unsupported processor: ${RUNNER_ARCH:-unknown}." ;;
    esac
    PLATFORM="${os}_${arch}"
}

# Sets EXPECTED to the SHA-256 of a binary: from the checksums kept in THIS repository for versions it knows,
# or the one the workflow gave for any other version. The release's own SHA256SUMS is never trusted for it:
# it lives where the binary lives.
expected_checksum() {
    local version="$1" name="$2" given="${3:-}" file line
    file="$here/checksums/$version.txt"

    if [ -f "$file" ]; then
        line="$(awk -v n="$name" '$2 == n { print $1 }' "$file")"
        [ -n "$line" ] || fail "No checksum for $name in the checksums of commy $version."
        EXPECTED="$line"

        return
    fi

    valid_sha256 "$given" || fail "commy $version is not a version this action knows. Use a known version, or give its SHA-256 as the input 'checksum'."
    EXPECTED="$given"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Downloads commy and checks it; sets BIN to the file.
install_cli() {
    local version="$1" given="$2" name dir actual
    platform
    name="commy_${version}_${PLATFORM}"
    expected_checksum "$version" "$name" "$given"
    dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/commy.XXXXXX")"

    echo "Downloading commy $version for ${PLATFORM/_//}"
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --max-filesize 100000000 -o "$dir/commy" \
        "https://github.com/$REPO/releases/download/v${version}/${name}" || fail "Could not download commy $version."

    actual="$(sha256_of "$dir/commy")"
    [ "$actual" = "$EXPECTED" ] || fail "The checksum of the downloaded commy does not match what is expected for $version. Nothing was run."

    chmod 0755 "$dir/commy"
    BIN="$dir/commy"
}

# --- the deployment ----------------------------------------------------------------------------------

main() {
    local app="${INPUT_APP:-}" url="${INPUT_URL:-}" command="${INPUT_COMMAND:-deploy}" wait="${INPUT_WAIT:-true}"
    local timeout="${INPUT_TIMEOUT:-15m}" version="${INPUT_VERSION:-}" checksum="${INPUT_CHECKSUM:-}"

    [ -n "${COMMY_TOKEN:-}" ] || fail "The input 'token' is empty. Pass a repository secret."
    echo "::add-mask::$COMMY_TOKEN"

    valid_app "$app" || fail "The input 'app' must be an app name: lower case letters, digits and hyphens."
    valid_url "$url" || fail "The input 'url' must be an https address such as https://panel.example.com."
    valid_version "$version" || fail "The input 'version' must look like 1.2.3."
    valid_timeout "$timeout" || fail "The input 'timeout' must look like 15m, 900s or 1h."

    case "$command" in deploy|apply) ;; *) fail "The input 'command' must be deploy or apply." ;; esac
    case "$wait" in true|false) ;; *) fail "The input 'wait' must be true or false." ;; esac

    local out rc stop
    install_cli "$version" "$checksum"
    out="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/commy-result.XXXXXX")"

    local args=("$command" "$app" --json --timeout "$timeout")
    [ "$wait" = false ] && args+=(--no-wait)

    export COMMY_URL="$url"
    unset COMMY_CONFIG || true

    # What the panel says (an error sentence, a commit message) is not ours: it may contain text that looks
    # like a workflow command. Commands are switched off while commy runs, with a one-time word.
    stop="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    echo "::stop-commands::$stop"
    set +e
    "$BIN" "${args[@]}" >"$out"
    rc=$?
    set -e
    echo "::$stop::"

    if [ -n "${GITHUB_OUTPUT:-}" ] && [ -s "$out" ]; then
        local number status
        number="$(sed -n 's/^  "number": \([0-9][0-9]*\).*/\1/p' "$out" | head -n 1)"
        status="$(sed -n 's/^  "status": "\([a-z_]*\)".*/\1/p' "$out" | head -n 1)"
        [ -z "$number" ] || echo "deployment=$number" >>"$GITHUB_OUTPUT"
        [ -z "$status" ] || echo "status=$status" >>"$GITHUB_OUTPUT"
        echo "commy $command of $app: deployment ${number:-?} ${status:-?}"
    fi

    rm -f "$out"
    exit "$rc"
}

if [ "${COMMY_ACTION_SOURCE_ONLY:-}" != 1 ]; then
    main
fi
