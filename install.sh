#!/usr/bin/env bash
#
# Minimal Fedora Asahi Remix setup: Sway + Steam (for Left 4 Dead 2) + dotfiles.
#
# Declarative and fully idempotent: safe to re-run any number of times.
# No system upgrades are performed here (see README for the manual prerequisite).
#
set -euo pipefail

# --- Pretty output -----------------------------------------------------------
CYAN=$'\e[36m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
RESET=$'\e[0m'

step() { printf '%s==>%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()   { printf '%s  ok:%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !!:%s %s\n' "$YELLOW" "$RESET" "$*"; }

# Absolute path to this repo (where the dotfiles live).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
