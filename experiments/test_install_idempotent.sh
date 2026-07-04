#!/usr/bin/env bash
# Idempotency test for install.sh.
#
# We can't run real `dnf` here, so we shim `sudo`, `dnf` and `systemctl`
# into a fake bin dir, point HOME at a temp dir, and run install.sh twice.
# The test asserts that both runs succeed and that every dotfile ends up as a
# symlink pointing back into the repo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_BIN" "$FAKE_HOME"

# Shims: no-op, always succeed. `sudo <cmd>` just drops the sudo and does nothing.
for cmd in sudo dnf systemctl usermod; do
    cat >"$FAKE_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$FAKE_BIN/$cmd"
done

run() {
    env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" USER="tester" \
        bash "$REPO_DIR/install.sh" >"$WORK/run.log" 2>&1
}

assert_link() {
    local dest="$FAKE_HOME/$1" want="$REPO_DIR/$2"
    [[ -L "$dest" ]] || { echo "FAIL: $dest is not a symlink"; exit 1; }
    local target
    target="$(readlink "$dest")"
    [[ "$target" == "$want" ]] || { echo "FAIL: $dest -> $target (want $want)"; exit 1; }
}

echo "== First run =="
run || { echo "FAIL: first run exited non-zero"; cat "$WORK/run.log"; exit 1; }

echo "== Second run (idempotency) =="
run || { echo "FAIL: second run exited non-zero"; cat "$WORK/run.log"; exit 1; }

echo "== Verifying symlinks =="
assert_link ".config/sway/config"       "sway/config"
assert_link ".config/foot/foot.ini"     "foot/foot.ini"
assert_link ".config/fuzzel/fuzzel.ini" "fuzzel/fuzzel.ini"
assert_link ".bashrc"                   "bash/.bashrc"
assert_link ".vimrc"                    "vim/.vimrc"
assert_link ".gitconfig"                "git/.gitconfig"

echo "== Verifying swaybar status script =="
[[ -x "$REPO_DIR/bin/status.sh" ]] \
    || { echo "FAIL: bin/status.sh is not executable"; exit 1; }
grep -q 'status_command ~/fedora-asahi/bin/status.sh' "$REPO_DIR/sway/config" \
    || { echo "FAIL: sway/config does not point status_command at bin/status.sh"; exit 1; }

echo "PASS: install.sh is idempotent and all dotfiles are symlinks into the repo"
