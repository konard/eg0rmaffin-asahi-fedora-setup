#!/usr/bin/env bash
# Behaviour test for the --upgrade flag in install.sh.
#
# We shim `sudo`, `dnf`, `systemctl`, `usermod`, `uname` and `rpm` so no real
# system changes happen. Each shimmed command appends its argv to a log so we
# can assert what install.sh actually invoked. `dnf` can be made to fail a set
# number of times to exercise the retry loop.
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

# `dnf` logs its argv. If FAIL_UPGRADE_TIMES > 0 and this is an `upgrade`, it
# fails and decrements a persistent counter file to simulate flaky mirrors.
cat >"$FAKE_BIN/dnf" <<'EOF'
#!/usr/bin/env bash
echo "dnf $*" >>"$DNF_LOG"
if [[ "${1:-}" == "upgrade" && -f "$FAIL_COUNTER" ]]; then
    remaining="$(cat "$FAIL_COUNTER")"
    if (( remaining > 0 )); then
        echo "$(( remaining - 1 ))" >"$FAIL_COUNTER"
        echo ">>> Interrupted: all mirrors were tried" >&2
        exit 1
    fi
fi
exit 0
EOF

# `uname -r` reports a fixed running kernel; the rpm shim reports a *newer*
# installed kernel so the reboot advice path is exercised.
cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-r" ]] && { echo "6.5.0-1.fc39.aarch64+16k"; exit 0; }
exit 0
EOF

cat >"$FAKE_BIN/rpm" <<'EOF'
#!/usr/bin/env bash
# Emulate the kernel-uname-r provides used to detect the newest kernel.
echo "kernel-uname-r 6.5.0-1.fc39.aarch64+16k"
echo "kernel-uname-r 6.6.0-1.fc39.aarch64+16k"
echo "some-other-provide 1.2.3"
exit 0
EOF

# No-op sleep so the retry loop doesn't actually wait between attempts.
cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

for cmd in systemctl usermod; do
    cat >"$FAKE_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod +x "$FAKE_BIN"/*

DNF_LOG="$WORK/dnf.log"
FAIL_COUNTER="$WORK/fail_counter"

run() {
    : >"$DNF_LOG"
    env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" USER="tester" \
        DNF_LOG="$DNF_LOG" FAIL_COUNTER="$FAIL_COUNTER" \
        bash "$REPO_DIR/install.sh" "$@" >"$WORK/run.log" 2>&1
}

# --- 1. No flag: no upgrade attempted ---------------------------------------
echo "== No flag: upgrade must NOT run =="
rm -f "$FAIL_COUNTER"
run || { echo "FAIL: default run exited non-zero"; cat "$WORK/run.log"; exit 1; }
if grep -q 'dnf upgrade' "$DNF_LOG"; then
    echo "FAIL: default run attempted an upgrade"; cat "$DNF_LOG"; exit 1
fi
echo "PASS: default run performed no upgrade"

# --- 2. --upgrade: hardened upgrade with the required setopts ----------------
echo "== --upgrade: runs hardened upgrade =="
rm -f "$FAIL_COUNTER"
run --upgrade || { echo "FAIL: --upgrade run exited non-zero"; cat "$WORK/run.log"; exit 1; }
grep -q 'dnf clean metadata' "$DNF_LOG" \
    || { echo "FAIL: no 'dnf clean metadata'"; cat "$DNF_LOG"; exit 1; }
grep -q 'dnf upgrade --refresh -y --setopt=max_parallel_downloads=2 --setopt=retries=10 --setopt=timeout=120' "$DNF_LOG" \
    || { echo "FAIL: upgrade missing hardened setopts"; cat "$DNF_LOG"; exit 1; }
grep -q 'dnf check' "$DNF_LOG" \
    || { echo "FAIL: post-upgrade 'dnf check' not run"; cat "$DNF_LOG"; exit 1; }
grep -q 'Reboot recommended' "$WORK/run.log" \
    || { echo "FAIL: no reboot advice despite newer installed kernel"; cat "$WORK/run.log"; exit 1; }
echo "PASS: --upgrade ran the hardened upgrade, dnf check, and reboot advice"

# --- 3. Retry loop: 2 transient failures then success ------------------------
echo "== --upgrade: retries transient failures =="
echo "2" >"$FAIL_COUNTER"
run --upgrade || { echo "FAIL: --upgrade did not recover after retries"; cat "$WORK/run.log"; exit 1; }
upgrade_calls="$(grep -c 'dnf upgrade' "$DNF_LOG")"
[[ "$upgrade_calls" == "3" ]] \
    || { echo "FAIL: expected 3 upgrade attempts, got $upgrade_calls"; cat "$DNF_LOG"; exit 1; }
echo "PASS: recovered on the 3rd attempt after 2 transient failures"

# --- 4. All attempts fail: exit 1 -------------------------------------------
echo "== --upgrade: exits 1 when all attempts fail =="
echo "99" >"$FAIL_COUNTER"
if run --upgrade; then
    echo "FAIL: --upgrade should have exited non-zero when all attempts fail"
    cat "$WORK/run.log"; exit 1
fi
grep -q 'system upgrade failed after 3 attempts' "$WORK/run.log" \
    || { echo "FAIL: missing clear failure message"; cat "$WORK/run.log"; exit 1; }
attempts="$(grep -c 'dnf upgrade' "$DNF_LOG")"
[[ "$attempts" == "3" ]] \
    || { echo "FAIL: expected 3 upgrade attempts before giving up, got $attempts"; exit 1; }
echo "PASS: aborted with exit 1 and a clear message after 3 failed attempts"

echo "ALL PASS: --upgrade behaves per spec"
