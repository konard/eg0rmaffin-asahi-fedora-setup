#!/usr/bin/env bash
# Behaviour test for the Happ install/upgrade logic in install.sh.
#
# Happ is installed from GitHub releases as a native aarch64 rpm, mirroring dnf
# semantics. We shim `sudo`, `dnf`, `rpm`, `curl`, `uname`, `systemctl` and
# `usermod` so nothing touches the real system or network. The shims are driven
# by env vars written per scenario:
#   HAPP_INSTALLED   -> version `rpm -q happ` reports ("" = not installed)
#   HAPP_LATEST      -> tag the fake GitHub API returns ("" = API unreachable)
#   CURL_LOG/DNF_LOG -> record every curl/dnf invocation so we can assert on them
# `uname -m` reports aarch64 so the native-arch guard lets the flow run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_BIN" "$FAKE_HOME"

# `sudo` just drops itself and re-executes the rest through PATH.
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

# `dnf` logs its argv and always succeeds (real installs are out of scope).
cat >"$FAKE_BIN/dnf" <<'EOF'
#!/usr/bin/env bash
echo "dnf $*" >>"$DNF_LOG"
exit 0
EOF

# `rpm -q happ` reports the version from HAPP_INSTALLED (empty => not installed,
# exit 1 like the real rpm). The kernel-provides query used by --upgrade's
# post_upgrade step is emulated so that path stays quiet.
cat >"$FAKE_BIN/rpm" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"PROVIDENAME"* ]]; then
    echo "kernel-uname-r 6.6.0-1.fc39.aarch64+16k"
    exit 0
fi
if [[ "$args" == *happ* ]]; then
    if [[ -n "${HAPP_INSTALLED:-}" ]]; then
        echo "$HAPP_INSTALLED"
        exit 0
    fi
    # Real rpm prints this to STDOUT (not stderr) and exits non-zero. Callers
    # that capture the output and test string-emptiness therefore see a
    # non-empty "version" — this reproduces the bug from issue #17.
    echo "package happ is not installed"
    exit 1
fi
exit 0
EOF

# `curl` stands in for the GitHub API. Logs the call. When HAPP_LATEST is set it
# prints a minimal releases JSON with the aarch64 asset; when empty it fails
# (exit 22) to simulate an unreachable API.
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$CURL_LOG"
if [[ -z "${HAPP_LATEST:-}" ]]; then
    exit 22
fi
url="https://github.com/Happ-proxy/happ-desktop/releases/download/${HAPP_LATEST}/Happ.linux.arm64.rpm"
cat <<JSON
{
  "tag_name": "${HAPP_LATEST}",
  "assets": [
    { "name": "Happ.linux.x64.rpm", "browser_download_url": "https://example/x64.rpm" },
    { "name": "Happ.linux.arm64.rpm", "browser_download_url": "${url}" }
  ]
}
JSON
exit 0
EOF

# `uname -m` => aarch64 (native-arch guard passes); `uname -r` => a kernel string.
cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-m" ]] && { echo "aarch64"; exit 0; }
[[ "${1:-}" == "-r" ]] && { echo "6.6.0-1.fc39.aarch64+16k"; exit 0; }
exit 0
EOF

# `jq` is used by install.sh to parse the API JSON; if the host lacks it,
# install.sh falls back to grep/sed. Only shim a no-jq host when the host has no
# real jq, to exercise the fallback deterministically we DON'T shim it here.

for cmd in systemctl usermod; do
    cat >"$FAKE_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
# No-op sleep so any retry loop in install.sh doesn't wait.
cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN"/*

DNF_LOG="$WORK/dnf.log"
CURL_LOG="$WORK/curl.log"

# run <installed> <latest> [flags...]
run() {
    local installed="$1" latest="$2"; shift 2
    : >"$DNF_LOG"; : >"$CURL_LOG"
    env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" USER="tester" \
        DNF_LOG="$DNF_LOG" CURL_LOG="$CURL_LOG" \
        HAPP_INSTALLED="$installed" HAPP_LATEST="$latest" \
        bash "$REPO_DIR/install.sh" "$@" >"$WORK/run.log" 2>&1
}

happ_dnf_installs() { grep -c 'dnf install -y http' "$DNF_LOG" || true; }

# --- 1. Fresh install: resolves latest and dnf-installs the arm64 rpm --------
echo "== Fresh system: ./install.sh installs happ =="
run "" "2.18.3" || { echo "FAIL: fresh run exited non-zero"; cat "$WORK/run.log"; exit 1; }
grep -q 'api.github.com/repos/Happ-proxy/happ-desktop/releases/latest' "$CURL_LOG" \
    || { echo "FAIL: fresh install did not query the GitHub API"; cat "$CURL_LOG"; exit 1; }
grep -q 'dnf install -y https://github.com/Happ-proxy/happ-desktop/releases/download/2.18.3/Happ.linux.arm64.rpm' "$DNF_LOG" \
    || { echo "FAIL: fresh install did not dnf-install the arm64 rpm"; cat "$DNF_LOG"; exit 1; }
echo "PASS: fresh install resolved latest and installed the native arm64 rpm"

# --- 2. Already installed, normal run: ZERO happ network calls, no change -----
echo "== Re-run with happ present: no network, no install =="
run "2.18.3" "2.18.3" || { echo "FAIL: idempotent run exited non-zero"; cat "$WORK/run.log"; exit 1; }
[[ -s "$CURL_LOG" ]] && { echo "FAIL: happ made a network call on a plain re-run"; cat "$CURL_LOG"; exit 1; }
[[ "$(happ_dnf_installs)" == "0" ]] || { echo "FAIL: happ was (re)installed on a plain re-run"; cat "$DNF_LOG"; exit 1; }
grep -q 'happ already installed (v2.18.3)' "$WORK/run.log" \
    || { echo "FAIL: expected 'happ already installed'"; cat "$WORK/run.log"; exit 1; }
echo "PASS: plain re-run made zero happ network calls and changed nothing"

# --- 3. --upgrade, up to date: prints 'up to date', no download --------------
echo "== --upgrade with happ up to date: no download =="
run "2.18.3" "2.18.3" --upgrade || { echo "FAIL: --upgrade run exited non-zero"; cat "$WORK/run.log"; exit 1; }
grep -q 'happ up to date (v2.18.3)' "$WORK/run.log" \
    || { echo "FAIL: expected 'happ up to date'"; cat "$WORK/run.log"; exit 1; }
[[ "$(happ_dnf_installs)" == "0" ]] || { echo "FAIL: happ downloaded despite being up to date"; cat "$DNF_LOG"; exit 1; }
echo "PASS: --upgrade with up-to-date happ printed 'up to date' and did not download"

# --- 4. --upgrade, older installed: updates and prints old->new --------------
echo "== --upgrade with older happ: updates, prints old->new =="
run "2.18.0" "2.18.3" --upgrade || { echo "FAIL: --upgrade run exited non-zero"; cat "$WORK/run.log"; exit 1; }
grep -q 'Upgrading happ 2.18.0 -> 2.18.3' "$WORK/run.log" \
    || { echo "FAIL: expected 'Upgrading happ 2.18.0 -> 2.18.3'"; cat "$WORK/run.log"; exit 1; }
grep -q 'dnf install -y https://github.com/Happ-proxy/happ-desktop/releases/download/2.18.3/Happ.linux.arm64.rpm' "$DNF_LOG" \
    || { echo "FAIL: upgrade did not dnf-install the newer rpm"; cat "$DNF_LOG"; exit 1; }
echo "PASS: --upgrade updated older happ and printed old->new"

# --- 5. --upgrade, installed newer than release: keep, no download ------------
echo "== --upgrade with installed newer than release: keep =="
run "2.19.0" "2.18.3" --upgrade || { echo "FAIL: --upgrade run exited non-zero"; cat "$WORK/run.log"; exit 1; }
grep -q 'happ v2.19.0 is newer than latest release' "$WORK/run.log" \
    || { echo "FAIL: expected 'newer than latest release'"; cat "$WORK/run.log"; exit 1; }
[[ "$(happ_dnf_installs)" == "0" ]] || { echo "FAIL: happ downgraded/reinstalled"; cat "$DNF_LOG"; exit 1; }
echo "PASS: --upgrade kept the newer installed happ"

# --- 6. --upgrade, API unreachable: warn and continue (non-fatal) ------------
echo "== --upgrade with GitHub API unreachable: warn, continue, exit 0 =="
run "2.18.0" "" --upgrade || { echo "FAIL: unreachable API must not abort"; cat "$WORK/run.log"; exit 1; }
grep -q 'happ: GitHub API unreachable' "$WORK/run.log" \
    || { echo "FAIL: expected an 'API unreachable' warning"; cat "$WORK/run.log"; exit 1; }
[[ "$(happ_dnf_installs)" == "0" ]] || { echo "FAIL: happ installed despite unreachable API"; cat "$DNF_LOG"; exit 1; }
echo "PASS: unreachable API warned and continued without aborting"

# --- 7. Fresh install, API unreachable: warn, continue, exit 0 ---------------
echo "== Fresh install with API unreachable: warn, continue, exit 0 =="
run "" "" || { echo "FAIL: unreachable API on fresh install must not abort"; cat "$WORK/run.log"; exit 1; }
grep -q 'happ: GitHub API unreachable' "$WORK/run.log" \
    || { echo "FAIL: expected an 'API unreachable' warning on fresh install"; cat "$WORK/run.log"; exit 1; }
[[ "$(happ_dnf_installs)" == "0" ]] || { echo "FAIL: happ installed despite unreachable API"; cat "$DNF_LOG"; exit 1; }
echo "PASS: unreachable API on fresh install warned and continued"

# --- 8. Non-aarch64 host: refuse the native asset, skip ----------------------
echo "== Non-aarch64 host: skip happ (native aarch64 only) =="
cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-m" ]] && { echo "x86_64"; exit 0; }
[[ "${1:-}" == "-r" ]] && { echo "6.6.0-1.fc39.x86_64"; exit 0; }
exit 0
EOF
chmod +x "$FAKE_BIN/uname"
run "" "2.18.3" || { echo "FAIL: non-aarch64 run exited non-zero"; cat "$WORK/run.log"; exit 1; }
grep -q 'native aarch64 asset only' "$WORK/run.log" \
    || { echo "FAIL: expected native-aarch64-only skip message"; cat "$WORK/run.log"; exit 1; }
[[ -s "$CURL_LOG" ]] && { echo "FAIL: queried the API on a non-aarch64 host"; cat "$CURL_LOG"; exit 1; }
[[ "$(happ_dnf_installs)" == "0" ]] || { echo "FAIL: installed happ on a non-aarch64 host"; cat "$DNF_LOG"; exit 1; }
echo "PASS: non-aarch64 host skipped happ with no network calls"

echo "ALL PASS: happ install/upgrade behaves per spec"
