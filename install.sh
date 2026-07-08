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
#
# On total failure we DO NOT abort: the upgrade (flaky mirrors) and the
# idempotent install flow (symlinks/packages/services) are independent concerns.
# We set UPGRADE_FAILED so the caller can continue with the rest of the flow and
# re-surface the warning in the final summary; the function returns non-zero.
UPGRADE_FAILED=0
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

    return 1
}

if (( DO_UPGRADE )); then
    # `set -e` would kill the script on a non-zero return; guard the call so a
    # failed upgrade only sets the flag and lets the install flow continue.
    if ! run_upgrade; then
        UPGRADE_FAILED=1
        err "system upgrade FAILED after 3 attempts — system unchanged, continuing with install flow; retry later with --upgrade"
    fi
fi

# --- 1. RPM Fusion (free) ----------------------------------------------------
# telegram-desktop lives in RPM Fusion (free), so enable that repo first.
# Only the *free* repo — no nonfree, no other third-party packages for now.
#
# CRITICAL: Steam and the whole x86 emulation stack (FEX + muvm + mesa/Vulkan)
# MUST keep coming from the Fedora/Asahi repos, never from RPM Fusion. RPM Fusion
# ships its own steam package; if dnf ever preferred it, a future upgrade could
# swap Steam (and drag in incompatible mesa bits) and break the Asahi emulation
# stack. We therefore pin `excludepkgs=steam*` into every rpmfusion-free* repo
# section so those repos can never provide steam. `dnf info steam` must always
# resolve to the Asahi/Fedora repo.

# Idempotent: only fetches the release RPM if it isn't installed yet.
step "Enabling RPM Fusion (free)"
if rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    ok "rpmfusion-free-release already installed"
else
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    ok "rpmfusion-free-release installed"
fi

# Add `excludepkgs=steam*` to each section of the rpmfusion-free* repo files so
# the guard survives future upgrades. Implemented with awk (no config-manager
# dependency, works on both dnf4 and dnf5) and idempotent: a section that
# already excludes steam is left untouched, so re-runs never duplicate the line.
guard_steam_exclude() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    # Append `excludepkgs=steam*` just before the next section header (or EOF)
    # for any section that doesn't already have an exclude/excludepkgs line.
    awk '
        /^[[:space:]]*\[/ {
            if (in_section && !has_exclude) print "excludepkgs=steam*"
            in_section = 1; has_exclude = 0
        }
        /^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=/ { has_exclude = 1 }
        { print }
        END { if (in_section && !has_exclude) print "excludepkgs=steam*" }
    ' "$file" > "$tmp"
    if ! cmp -s "$file" "$tmp"; then
        sudo cp "$tmp" "$file"
        ok "pinned excludepkgs=steam* in $(basename "$file")"
    else
        ok "$(basename "$file") already excludes steam"
    fi
    rm -f "$tmp"
}

step "Guarding Steam against RPM Fusion (excludepkgs=steam*)"
for repo in /etc/yum.repos.d/rpmfusion-free*.repo; do
    guard_steam_exclude "$repo"
done

# --- 2. Packages -------------------------------------------------------------
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
    telegram-desktop \
    fastfetch \
    widevine-installer \
    vim git htop unzip wget jq
ok "packages installed"

# --- 3. Steam ----------------------------------------------------------------
# Comes from the Asahi repos included in the Remix and pulls the whole x86
# emulation stack (FEX + muvm + Vulkan) automatically — never from RPM Fusion
# (pinned out above via excludepkgs=steam*), no COPR, no Flatpak.
step "Installing Steam (sudo dnf install -y steam)"
sudo dnf install -y steam
ok "steam installed"

# --- 4. Happ (VLESS/Reality proxy client) ------------------------------------
# Happ is not packaged for Fedora — we install it straight from its GitHub
# releases, mirroring dnf semantics:
#   * normal run  : install only if absent; if already installed, do nothing and
#                   make ZERO network calls for happ (a plain `rpm -q` is local).
#   * --upgrade   : resolve the latest release, compare with the installed
#                   version and update only when the release is newer, printing
#                   old->new. If the GitHub API is unreachable, warn and continue
#                   (non-fatal, same spirit as the --upgrade flow above).
#
# CRITICAL: use the native Linux aarch64 asset ONLY. Happ is a VPN client; its
# TUN device must run on the real kernel, so it must NOT be the x86_64 build
# under FEX/muvm (TUN from inside a microVM won't work). The upstream release
# ships a native aarch64 rpm (Happ.linux.arm64.rpm), so we take the rpm route:
# `dnf install` the asset URL and track the version with `rpm -q` (no VERSION
# file needed). The rpm installs to /opt/happ, drops /usr/bin/happ and a
# Happ.desktop entry (so it shows up in fuzzel), and its own %post sets up the
# happd helper used for TUN mode — we add no autostart or systemd unit of ours.
HAPP_REPO="Happ-proxy/happ-desktop"
HAPP_ASSET="Happ.linux.arm64.rpm"
HAPP_API="https://api.github.com/repos/${HAPP_REPO}/releases/latest"

# Installed happ version (empty when absent). Always returns 0 so a "not
# installed" rpm exit can't trip `set -e` in the caller's command substitution.
#
# CRITICAL: gate on rpm's EXIT STATUS, not its stdout. `rpm -q happ` on a missing
# package exits non-zero but still prints `package happ is not installed` to
# stdout (see issue #17). Capturing that output and testing string-emptiness
# would treat the absent package as installed with a bogus "version", so we must
# ask `rpm -q happ` for presence first and only then read the version.
happ_installed_version() {
    rpm -q happ &>/dev/null || return 0
    rpm -q --qf '%{VERSION}\n' happ 2>/dev/null | head -n1 || true
}

# Resolve the latest release from the GitHub API. Prints "<tag>\t<asset-url>" on
# success; returns non-zero on any network/parse failure so callers can decide
# whether that is fatal (fresh install) or just a warning (--upgrade). Prefers
# jq (in the package list) but falls back to grep/sed so it also works before
# the package step has run.
happ_latest_release() {
    local json
    json="$(curl -fsSL --max-time 30 "$HAPP_API")" || return 1
    local tag url
    if command -v jq >/dev/null 2>&1; then
        tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
        url="$(printf '%s' "$json" | jq -r --arg a "$HAPP_ASSET" \
            '.assets[]? | select(.name==$a) | .browser_download_url' | head -n1)"
    else
        tag="$(printf '%s' "$json" \
            | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -n1 \
            | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
        url="$(printf '%s' "$json" \
            | grep -o "\"browser_download_url\":[[:space:]]*\"[^\"]*${HAPP_ASSET}\"" | head -n1 \
            | sed -E 's/.*"(https[^"]*)"[[:space:]]*$/\1/')"
    fi
    [[ -n "$tag" && -n "$url" ]] || return 1
    # Compare cleanly against `rpm -q %{VERSION}` (which carries no "v" prefix);
    # the download URL is taken verbatim from the API, so this only affects the
    # version we display/compare, never what we fetch.
    tag="${tag#v}"
    printf '%s\t%s\n' "$tag" "$url"
}

install_or_upgrade_happ() {
    # Native aarch64 only: refuse to install the x86_64 build under emulation.
    local arch; arch="$(uname -m)"
    if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
        warn "happ: native aarch64 asset only; host arch is $arch — skipping"
        return 0
    fi

    local installed; installed="$(happ_installed_version)"

    # Already installed and not upgrading: nothing to do, no network calls.
    if [[ -n "$installed" && $DO_UPGRADE -eq 0 ]]; then
        ok "happ already installed (v$installed)"
        return 0
    fi

    # The only network call in this section — resolve the latest release.
    local rel tag url
    if ! rel="$(happ_latest_release)"; then
        if [[ -n "$installed" ]]; then
            warn "happ: GitHub API unreachable — keeping installed v$installed"
        else
            warn "happ: GitHub API unreachable — cannot install now; re-run later"
        fi
        return 0
    fi
    tag="${rel%%$'\t'*}"
    url="${rel#*$'\t'}"

    # Fresh install.
    if [[ -z "$installed" ]]; then
        step "Installing happ $tag (native aarch64 rpm)"
        sudo dnf install -y "$url"
        ok "happ $tag installed"
        return 0
    fi

    # Installed + --upgrade: update only when the release is strictly newer.
    if [[ "$installed" == "$tag" ]]; then
        ok "happ up to date (v$installed)"
        return 0
    fi
    local newest
    newest="$(printf '%s\n%s\n' "$installed" "$tag" | sort -V | tail -n1)"
    if [[ "$newest" == "$installed" ]]; then
        ok "happ v$installed is newer than latest release ($tag) — keeping"
        return 0
    fi
    step "Upgrading happ $installed -> $tag"
    sudo dnf install -y "$url"
    ok "happ upgraded $installed -> $tag"
}

step "Checking Happ (VLESS/Reality proxy client)"
install_or_upgrade_happ

# --- 5. Symlinks -------------------------------------------------------------
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

# --- 6. Audio services -------------------------------------------------------
step "Enabling audio services (pipewire / wireplumber)"
systemctl --user enable --now pipewire       || true
systemctl --user enable --now wireplumber    || true
systemctl --user enable --now pipewire-pulse || true
ok "audio services requested"

# --- 7. Groups ---------------------------------------------------------------
# brightnessctl needs the 'video' group to adjust backlight without root.
step "Adding $USER to the 'video' group (for brightnessctl)"
sudo usermod -aG video "$USER"
ok "usermod done (re-login required for group change to take effect)"

# --- 8. Done -----------------------------------------------------------------
step "Setup complete"

# Re-surface the upgrade failure so it can't be missed under the install output.
if (( UPGRADE_FAILED )); then
    err "system upgrade FAILED after 3 attempts — system unchanged, continuing with install flow; retry later with --upgrade"
fi

printf '%s\n' "Launch the desktop with: ${GREEN}sway${RESET}   (from a tty)"
printf '%s\n' "Remember to create ${YELLOW}~/.gitconfig.local${RESET} with your user.name and user.email:"
printf '%s\n' "    git config --file ~/.gitconfig.local user.name  \"Your Name\""
printf '%s\n' "    git config --file ~/.gitconfig.local user.email \"you@example.com\""
