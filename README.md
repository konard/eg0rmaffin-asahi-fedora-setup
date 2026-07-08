# asahi-fedora-setup

Minimal Fedora Asahi Remix setup: Sway + Steam for Left 4 Dead 2.

Declarative, idempotent `install.sh` + symlinked dotfiles. Wayland-only, no
desktop environment. Steam comes straight from the Asahi repos included in the
Remix (`dnf install steam`), which pulls the whole x86 emulation stack
(FEX + muvm + Vulkan) automatically.

The only third-party repo is RPM Fusion **free** (for `telegram-desktop`); no
nonfree, no COPRs, no Flatpak. Steam and the emulation stack are pinned to the
Fedora/Asahi repos: `install.sh` writes `excludepkgs=steam*` into every
`rpmfusion-free*` repo so no upgrade can ever swap Steam (or its mesa bits) for
RPM Fusion's build. `dnf info steam` always resolves to the Asahi/Fedora repo.

## Prerequisite (run once on a fresh system, before install.sh)

```
sudo dnf upgrade --refresh
sudo reboot
```

The latest Asahi drivers (kernel + mesa) are required before installing Steam,
so bring the system fully up to date and reboot into the new kernel first.
`install.sh` performs no upgrade by default; pass `--upgrade` (see below) if you
want it to run this step for you with mirror-hardened download settings.

## Install

```
sudo dnf install -y git
git clone <repo-url>
cd <cloned-dir> && ./install.sh
```

Clone the repo anywhere you like — `install.sh` derives its own location, so the
setup is independent of the clone path. `bin/` scripts are symlinked into
`~/.local/bin`, and configs reference that stable location rather than the clone
directory.

`install.sh` is fully idempotent — safe to re-run whenever you add a package to
the list, or after moving the repo (it re-points every symlink).

### Optional: `--upgrade`

By default `install.sh` never upgrades the system (offline-first). If you want
it to bring the system fully up to date first, pass `--upgrade`:

```
./install.sh --upgrade
```

This runs a full `dnf upgrade --refresh` before the normal flow, with download
settings hardened against flaky mirrors (`max_parallel_downloads=2`,
`retries=10`, `timeout=120`) and up to 3 attempts. Because dnf downloads every
package before touching the rpm transaction, a mid-download failure leaves the
system consistent and retrying is cheap. If all attempts fail the script prints
a loud warning (system unchanged) and **continues with the rest of the install
flow** — symlinks/packages/services still run — then repeats the warning in the
final summary and exits 0; retry the upgrade later with `--upgrade`. After a
successful upgrade it runs `dnf check` (informational) and, if a newer kernel
than the running one was installed, recommends a reboot. Without the flag,
behaviour is unchanged — no upgrade is attempted.

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
