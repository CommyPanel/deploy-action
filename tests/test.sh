#!/usr/bin/env bash
# Tests for scripts/deploy.sh. Needs bash, curl and python3; the live tests download a real release.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
passes=0

pass() { passes=$((passes + 1)); }
bad()  { failures=$((failures + 1)); echo "FAIL: $*"; }
ok()   { if "$@"; then pass; else bad "expected success: $*"; fi; }
no()   { if "$@"; then bad "expected failure: $*"; else pass; fi; }

# shellcheck disable=SC1091
COMMY_ACTION_SOURCE_ONLY=1 source "$root/scripts/deploy.sh"
set +e +u   # the sourced script turns these on

echo "== input checks"
ok valid_app shop; ok valid_app my-app-2; no valid_app 'Shop'; no valid_app 'shop;id'; no valid_app '$(id)'; no valid_app "shop
x"; no valid_app ''; no valid_app -x
ok valid_version 0.1.0; ok valid_version 1.20.3-rc.1; no valid_version latest; no valid_version '0.1.0;id'; no valid_version '../0.1.0'; no valid_version 0.1
ok valid_timeout 15m; ok valid_timeout 900s; ok valid_timeout 2h; no valid_timeout 15; no valid_timeout 'm'; no valid_timeout '1m; id'; no valid_timeout 123456m
ok valid_sha256 "$(printf 'a%.0s' $(seq 64))"; no valid_sha256 abc; no valid_sha256 "$(printf 'A%.0s' $(seq 64))"
ok valid_url https://panel.example.com; ok valid_url https://panel.example.com:8443/; ok valid_url 'https://[::1]:8443'
no valid_url http://panel.example.com; no valid_url https://panel.example.com/path; no valid_url 'https://user:pw@panel.example.com'; no valid_url 'https://a b'; no valid_url 'https://a.com?x=1'; no valid_url javascript:alert
no valid_url http://127.0.0.1:8000   # plain http is refused unless this repository's own tests ask for it
(COMMY_ACTION_ALLOW_HTTP_LOCALHOST=1; ok valid_url http://127.0.0.1:8000; no valid_url http://evil.example.com)

echo "== platform"
(RUNNER_OS=Linux RUNNER_ARCH=X64; platform; [ "$PLATFORM" = linux_amd64 ]) && pass || bad "linux amd64"
(RUNNER_OS=macOS RUNNER_ARCH=ARM64; platform; [ "$PLATFORM" = darwin_arm64 ]) && pass || bad "mac arm64"
(RUNNER_OS=Windows RUNNER_ARCH=X64; platform) >/dev/null 2>&1 && bad "windows should be refused" || pass

echo "== checksums come from this repository, not from the release"
(here="$root"; expected_checksum 0.1.0 commy_0.1.0_linux_amd64 ""; [ "$EXPECTED" = "$(awk '$2=="commy_0.1.0_linux_amd64"{print $1}' "$root/checksums/0.1.0.txt")" ]) && pass || bad "known version"
(here="$root"; expected_checksum 0.1.0 commy_0.1.0_plan9_amd64 "") >/dev/null 2>&1 && bad "unknown platform should fail" || pass
(here="$root"; expected_checksum 9.9.9 commy_9.9.9_linux_amd64 "") >/dev/null 2>&1 && bad "unknown version without a checksum should fail" || pass
(here="$root"; expected_checksum 9.9.9 commy_9.9.9_linux_amd64 "$(printf 'b%.0s' $(seq 64))"; [ "$EXPECTED" = "$(printf 'b%.0s' $(seq 64))" ]) && pass || bad "unknown version with a checksum"
(here="$root"; expected_checksum 9.9.9 commy_9.9.9_linux_amd64 "not-a-checksum") >/dev/null 2>&1 && bad "a malformed checksum should fail" || pass

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== live: download, verify, and refuse a tampered checksum"
if [ "${SKIP_LIVE:-}" != 1 ]; then
    ( export RUNNER_TEMP="$work"; install_cli 0.1.0 "" >"$work/install.log" 2>&1; "$BIN" version >"$work/version.txt"; grep -q "^commy 0.1.0$" "$work/version.txt" ) && pass || { bad "real install"; cat "$work/install.log"; }

    # A copy of the script with a checksums file that does not match the real binary: nothing may run.
    mkdir -p "$work/tampered/scripts" "$work/tampered/checksums"
    cp "$root/scripts/deploy.sh" "$work/tampered/scripts/"
    sed "s/^[0-9a-f]\{64\}/$(printf '0%.0s' $(seq 64))/" "$root/checksums/0.1.0.txt" >"$work/tampered/checksums/0.1.0.txt"
    out="$(RUNNER_TEMP="$work" bash -c 'COMMY_ACTION_SOURCE_ONLY=1 source "$1"; set +e; install_cli 0.1.0 ""; echo "ran-after-failure"' _ "$work/tampered/scripts/deploy.sh" 2>&1)"
    if grep -q "does not match" <<<"$out" && ! grep -q "ran-after-failure" <<<"$out"; then pass; else bad "a wrong checksum must stop everything: $out"; fi
else
    echo "(skipped)"
fi

echo "== the whole flow against a fake panel on this machine"
if [ "${SKIP_LIVE:-}" != 1 ]; then
    port=$((20000 + RANDOM % 9000))
    export EXPECT_TOKEN="3|cpt_testtokentesttokentesttoken"

    run_flow() {   # $1 = mode; prints the combined output, then "exit=<code>"
        MODE="$1" python3 "$root/tests/fake_panel.py" "$port" &
        local server=$!
        sleep 1
        local out
        out="$( cd "$work" && RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/gh_output" COMMY_ACTION_ALLOW_HTTP_LOCALHOST=1 COMMY_ALLOW_HTTP_LOCALHOST=1 \
            INPUT_APP=shop INPUT_URL="http://127.0.0.1:$port" INPUT_COMMAND=deploy INPUT_WAIT=true INPUT_TIMEOUT=60s INPUT_VERSION=0.1.0 INPUT_CHECKSUM= \
            COMMY_TOKEN="$EXPECT_TOKEN" bash "$root/scripts/deploy.sh" 2>&1; echo "exit=$?" )"
        kill "$server" 2>/dev/null; wait "$server" 2>/dev/null
        echo "$out"
    }

    : >"$work/gh_output"
    out="$(run_flow active)"
    if grep -q "exit=0" <<<"$out" && grep -q "^deployment=5$" "$work/gh_output" && grep -q "^status=active$" "$work/gh_output" && grep -q "::add-mask::" <<<"$out" && ! grep -q "testtokentesttoken" <<<"$(grep -v '::add-mask::' <<<"$out")"; then pass; else bad "a good deploy: $out"; fi
    port=$((port + 1))

    : >"$work/gh_output"
    out="$(run_flow failed)"
    if grep -q "exit=3" <<<"$out" && grep -q "^status=failed$" "$work/gh_output"; then pass; else bad "a failed deploy must exit 3: $out"; fi

    # What the panel says must not be able to issue workflow commands: they are switched off around commy.
    stop_line="$(grep -n '^::stop-commands::' <<<"$out" | head -1 | cut -d: -f1)"
    inj_line="$(grep -n '::error::pwned' <<<"$out" | head -1 | cut -d: -f1)"
    resume_line="$(grep -n -E '^::[0-9a-f]{32}::$' <<<"$out" | head -1 | cut -d: -f1)"
    if [ -n "$stop_line" ] && [ -n "$inj_line" ] && [ -n "$resume_line" ] && [ "$stop_line" -lt "$inj_line" ] && [ "$inj_line" -lt "$resume_line" ]; then pass; else bad "the panel's text is not inside the stop-commands window ($stop_line/$inj_line/$resume_line): $out"; fi
    port=$((port + 1))

    out="$(run_flow conflict)"
    if grep -q "exit=1" <<<"$out" && grep -q "already in progress" <<<"$out"; then pass; else bad "a conflict: $out"; fi
else
    echo "(skipped)"
fi

echo "== bad input stops before anything is downloaded"
for case in "INPUT_APP=shop;id" "INPUT_VERSION=latest" "INPUT_TIMEOUT=forever" "INPUT_URL=http://panel.example.com" "INPUT_COMMAND=destroy" "INPUT_WAIT=maybe"; do
    out="$(env INPUT_APP=shop INPUT_URL=https://panel.example.com INPUT_COMMAND=deploy INPUT_WAIT=true INPUT_TIMEOUT=15m INPUT_VERSION=0.1.0 COMMY_TOKEN=x RUNNER_TEMP="$work" "$case" bash "$root/scripts/deploy.sh" 2>&1)"
    if [ $? -ne 0 ] && grep -q "::error::" <<<"$out" && ! grep -q "Downloading" <<<"$out"; then pass; else bad "$case should be refused before downloading: $out"; fi
done
out="$(env INPUT_APP=shop INPUT_URL=https://panel.example.com COMMY_TOKEN= bash "$root/scripts/deploy.sh" 2>&1)"
if grep -q "token' is empty" <<<"$out"; then pass; else bad "an empty token: $out"; fi

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
