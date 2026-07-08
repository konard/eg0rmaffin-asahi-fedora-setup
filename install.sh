#!/usr/bin/env bash
#
# Minimal Fedora Asahi Remix setup: Sway + Steam (for Left 4 Dead 2) + dotfiles.
#
# Declarative and fully idempotent: safe to re-run any number of times.
# No system upgrades are performed by default (see README for the manual
# prerequisite). Pass --upgrade to run a hardened full upgrade first.
#
set -euo pipefail

# --- Pretty output -----------------------------------------------------------
CYAN=$'\e[36m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
RED=$'\e[31m'
RESET=$'\e[0m'

step() { printf '%s==>%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()   { printf '%s  ok:%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !!:%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s ERR:%s %s\n' "$RED" "$RESET" "$*" >&2; }

# Absolute path to this repo (where the dotfiles live).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Flags -------------------------------------------------------------------
# Only one flag is supported: --upgrade runs a full system upgrade before the
# rest of the (unchanged) idempotent flow. Absent the flag, behaviour is
# identical to before: no upgrade is ever attempted.
DO_UPGRADE=0
for arg in "$@"; do
    case "$arg" in
        --upgrade) DO_UPGRADE=1 ;;
        *) warn "ignoring unknown argument: $arg" ;;
    esac
done

# --- Optional full system upgrade (--upgrade) --------------------------------
# Newest installed kernel version (uname -r style), detected generically so it
# works for any kernel package name (Asahi ships a 16k-page kernel variant).
# Every installed kernel package provides `kernel-uname-r = <version>`, and that
# version string matches `uname -r` exactly, so we never hardcode a package name.
newest_installed_kernel() {
    rpm -q --qf '[%{PROVIDENAME} %{PROVIDEVERSION}\n]' -a 2>/dev/null \
        | awk '$1 == "kernel-uname-r" { print $2 }' \
        | sort -V | tail -n1
}

# Informational post-upgrade checks. Never fatal.
post_upgrade() {
    # rpmdb consistency check — print its output, but treat problems as
    # informational only (no distro-sync / --allowerasing / rpm --rebuilddb).
    step "Running 'dnf check' (informational only)"
    sudo dnf check || warn "dnf check reported issues (informational, not fatal)"

    # A freshly installed kernel is not active until reboot; recommend one when
    # the newest installed kernel differs from the running kernel. Detection is
    # best-effort: if it fails for any reason, skip the advice rather than abort
    # an otherwise-successful upgrade.
    local newest running
    newest="$(newest_installed_kernel)" || newest=""
    running="$(uname -r)" || running=""
    if [[ -n "$newest" && "$newest" != "$running" ]]; then
        warn "newer kernel installed ($newest) than the running one ($running)."
        warn "Reboot recommended: the new Asahi kernel/mesa are not active yet."
    fi
}

# Full upgrade hardened against flaky mirrors, with a small retry loop.
# dnf downloads every package before touching the rpm transaction, so a
# download-stage failure leaves the system consistent and retries are cheap
# (dnf resumes from its package cache).
run_upgrade() {
    step "Full system upgrade (--upgrade)"
    sudo dnf clean metadata

    local attempt max_attempts=3
    for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
        step "Upgrade attempt $attempt/$max_attempts (dnf upgrade --refresh)"
        if sudo dnf upgrade --refresh -y \
                --setopt=max_parallel_downloads=2 \
                --setopt=retries=10 \
                --setopt=timeout=120; then
            ok "system upgrade complete"
            post_upgrade
            return 0
        fi
        warn "upgrade attempt $attempt failed (likely a transient mirror/download error)"
        if (( attempt < max_attempts )); then
            warn "retrying in 15s..."
            sleep 15
        fi
    done

    err "system upgrade failed after $max_attempts attempts; aborting."
    err "The upgrade did not happen. Nothing was installed; re-run once the mirrors are reachable."
    exit 1
}

if (( DO_UPGRADE )); then
    run_upgrade
fi

# --- 1. Packages -------------------------------------------------------------
step "Installing packages (dnf install -y)"
sudo dnf install -y \
    sway swaybg swaylock swayidle xorg-x11-server-Xwayland \
    foot fuzzel \
    wl-clipboard grim slurp \
    thunar gvfs \
    pavucontrol pamixer \
    brightnessctl \
    google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-emoji-fonts \
    firefox \
    vim git htop unzip wget
ok "packages installed"

# --- 2. Steam ----------------------------------------------------------------
# Comes from the Asahi repos included in the Remix and pulls the whole x86
# emulation stack (FEX + muvm + Vulkan) automatically. No RPM Fusion / COPR / Flatpak.
step "Installing Steam (sudo dnf install -y steam)"
sudo dnf install -y steam
ok "steam installed"

# --- 3. Symlinks -------------------------------------------------------------
# link <source-in-repo> <target-in-home>
link() {
    local src="$REPO_DIR/$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
    ok "linked $dest -> $src"
}

step "Linking config files"
link sway/config       "$HOME/.config/sway/config"
link foot/foot.ini     "$HOME/.config/foot/foot.ini"
link fuzzel/fuzzel.ini "$HOME/.config/fuzzel/fuzzel.ini"
link bash/.bashrc      "$HOME/.bashrc"
link vim/.vimrc        "$HOME/.vimrc"
link git/.gitconfig    "$HOME/.gitconfig"

# swaybar reads its status line from bin/status.sh; re-assert the executable bit
# on everything under bin/ so a stray checkout that dropped it can't leave the
# bar blank.
chmod +x "$REPO_DIR"/bin/*
ok "bin/ scripts are executable"

# Symlink every script under bin/ into ~/.local/bin so configs can reference a
# stable location (~/.local/bin/status.sh) regardless of where the repo is
# cloned. sway/config points at ~/.local/bin/status.sh, not the clone dir.
step "Linking bin/ scripts into ~/.local/bin"
for script in "$REPO_DIR"/bin/*; do
    link "bin/$(basename "$script")" "$HOME/.local/bin/$(basename "$script")"
done

# --- 4. Audio services -------------------------------------------------------
step "Enabling audio services (pipewire / wireplumber)"
systemctl --user enable --now pipewire       || true
systemctl --user enable --now wireplumber    || true
systemctl --user enable --now pipewire-pulse || true
ok "audio services requested"

# --- 5. Groups ---------------------------------------------------------------
# brightnessctl needs the 'video' group to adjust backlight without root.
step "Adding $USER to the 'video' group (for brightnessctl)"
sudo usermod -aG video "$USER"
ok "usermod done (re-login required for group change to take effect)"

# --- 6. Done -----------------------------------------------------------------
step "Setup complete"
printf '%s\n' "Launch the desktop with: ${GREEN}sway${RESET}   (from a tty)"
printf '%s\n' "Remember to create ${YELLOW}~/.gitconfig.local${RESET} with your user.name and user.email:"
printf '%s\n' "    git config --file ~/.gitconfig.local user.name  \"Your Name\""
printf '%s\n' "    git config --file ~/.gitconfig.local user.email \"you@example.com\""
