# asahi-fedora-setup

Minimal Fedora Asahi Remix setup: Sway + Steam for Left 4 Dead 2.

Declarative, idempotent `install.sh` + symlinked dotfiles. Wayland-only, no
desktop environment. Steam comes straight from the Asahi repos included in the
Remix (`dnf install steam`), which pulls the whole x86 emulation stack
(FEX + muvm + Vulkan) automatically — no RPM Fusion, no COPRs, no Flatpak.

## Prerequisite (run once on a fresh system, before install.sh)

```
sudo dnf upgrade --refresh
sudo reboot
```

The latest Asahi drivers (kernel + mesa) are required before installing Steam,
so bring the system fully up to date and reboot into the new kernel first.
`install.sh` itself never performs upgrades.

## Install

```
sudo dnf install -y git
git clone <repo-url> ~/fedora-asahi
cd ~/fedora-asahi && ./install.sh
```

`install.sh` is fully idempotent — safe to re-run whenever you add a package to
the list.

## Post-install

- Start the desktop with `sway` from a tty.
- Create `~/.gitconfig.local` with your identity:
  ```
  git config --file ~/.gitconfig.local user.name  "Your Name"
  git config --file ~/.gitconfig.local user.email "you@example.com"
  ```
- The **first** Steam launch is slow — muvm sets up the x86 environment. This is
  normal; subsequent launches are faster.
- Install the **native Linux** version of Left 4 Dead 2. It is a native x86
  game, so no Proton is needed.
- x86 emulation is memory-hungry: 16 GB RAM is recommended for most games.
