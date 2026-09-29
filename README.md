# caelestia-autoinstall

[![shellcheck](https://github.com/nytrek/caelestia-autoinstall/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/nytrek/caelestia-autoinstall/actions/workflows/shellcheck.yml)

Unattended installer for the [Caelestia](https://github.com/caelestia-dots/caelestia)
dots (Hyprland + Quickshell) on Arch-based distros. It fixes the usual conflicts,
builds the right `quickshell-git`, runs the official installer and leaves a
login screen ready, so the first reboot lands on a working desktop.

```
curl -fsSL https://raw.githubusercontent.com/nytrek/caelestia-autoinstall/main/install.sh | bash
```

It asks for your password once. When it's done, reboot and pick the Hyprland session.

> Unofficial. Caelestia is made by [caelestia-dots](https://github.com/caelestia-dots);
> this script prepares the system and drives their installer.

## Requirements

- Arch Linux, CachyOS, EndeavourOS, Garuda or another Arch derivative, x86_64
- A normal user with `sudo`
- About 6 GB free, plus the size of `~/.config` (the official installer copies it)
- NVIDIA users: install the drivers first

Manjaro works with a warning (its packages lag behind the AUR). Artix gets
everything installed but services and the login screen are left to you.
On Debian, Ubuntu, Fedora or openSUSE the script explains why it can't and exits
without changing anything.

## What it does

```
 [01/16] Detecting the system ─────────────────────────────
   [*] CachyOS (cachyos, like arch)
   [+] Arch family

 [02/16] Checking requirements ────────────────────────────
   [+] User: nytrek
   [+] Architecture: x86_64
   [+] Internet: connected
   [+] Disk: 812 GB free on /, 812 GB in home
 ...
 [10/16] Caelestia dependencies ───────────────────────────
   [*] 47 from the repos, 11 from the AUR
   [+] Repository packages 1m12s
   [⠼] Building quickshell-git (5-15 min) 3m41s
```

1. Checks the distro, architecture, sudo, internet, disk space and whether it's a VM.
2. Shows an optional apps menu (see below).
3. Backs up your current configs to `~/caelestia-backup-DATE.tar.gz`.
4. Updates the keyrings, then the system. If a mirror is broken it re-ranks them
   with your distro's tool (`cachyos-rate-mirrors`, `pacman-mirrors`, `reflector`)
   and retries. If another package manager is running, it waits.
5. Installs `base-devel`, `git` and `yay`.
6. Resolves known conflicts:
   - other quickshell builds such as CachyOS' `noctalia-qs`, which claims to provide
     `quickshell-git` and makes Caelestia fail with `Unrecognized pragma "DefaultEnv"`.
     It's only removed once the repo packages are in and the AUR answers, and never
     if that would take your login screen or desktop with it.
   - `jack2`/`pulseaudio` against PipeWire.
   - `darkly` against `darkly-bin`.
7. Installs the dependencies listed in Caelestia's
   [`manifest.toml`](https://github.com/caelestia-dots/caelestia/blob/main/manifest.toml),
   read on every run so the list never goes stale.
8. Runs `caelestia install --noconfirm`, or `caelestia update` if it's already installed.
9. Makes sure the session boots: `uwsm` if a session entry needs it, a login screen
   (keeps yours, enables one that's installed but disabled, or installs SDDM),
   NetworkManager, Bluetooth and power-profiles-daemon when nothing else handles them.
10. Removes build caches.

Command output goes to `~/caelestia-install-DATE.log`. If something fails you get
the step, the last lines of the log, and running the script again resumes from there.

## Apps

Before installing, it asks which apps you want:

```
     Browsers                        Media & chat
       1  Brave                        9  Spotify + Spicetify
       2  Google Chrome               10  Discord (Equibop)
       3  Zen Browser                 11  Telegram
                                      12  VLC
     Development                      13  OBS Studio
       4  VS Code (OSS)
       5  VSCodium                    Productivity
       6  PyCharm Community           14  KeePassXC
       7  Zed                         15  Obsidian
       8  Neovim                      16  LibreOffice
                                      17  qBittorrent
                                      18  GIMP

   Numbers or ranges (1 4-6), a for all, Enter for none.
   [?] > 1 6 9 14
```

Spotify, Discord, Zen, VS Code, VSCodium, Zed and Neovim are installed as Caelestia
components, so they get its theming. The rest are plain packages. An app that fails
to install is reported at the end and doesn't stop anything.

Skip the menu with `--apps brave,pycharm,keepassxc` or `-y`.

## Options

| Option            | Description                                               |
|-------------------|-----------------------------------------------------------|
| `--apps LIST`     | Install these apps without asking (ids or menu numbers)   |
| `-y`, `--yes`     | Don't show the apps menu                                  |
| `--enable LIST`   | Extra Caelestia components, e.g. `uwsm,todoist`           |
| `--disable LIST`  | Default components to skip, e.g. `firefox`                |
| `--dm MANAGER`    | Login screen: `auto` (default), `sddm`, `greetd`, `none`  |
| `--no-cleanup`    | Keep build caches                                         |
| `--reboot`        | Reboot when done                                          |
| `--dry-run`       | Show what would be done without changing anything         |

With `curl | bash`, options go after `-s --`:

```
curl -fsSL https://raw.githubusercontent.com/nytrek/caelestia-autoinstall/main/install.sh | bash -s -- --apps brave,spotify
```

Or read it first, which is always a good idea:

```
curl -fsSLO https://raw.githubusercontent.com/nytrek/caelestia-autoinstall/main/install.sh
less install.sh
bash install.sh --dry-run
bash install.sh
```

## After installing

- Your tweaks go in `~/.config/caelestia/`: `hypr-user.lua` for monitors and Hyprland
  settings, `hypr-vars.lua` for default apps and keybinds. Don't edit `~/.config/hypr/`,
  updates overwrite it.
- Update with `caelestia update`.

## Uninstall

```
curl -fsSL https://raw.githubusercontent.com/nytrek/caelestia-autoinstall/main/uninstall.sh | bash
```

Shows what it's going to do and asks before touching anything. It stops the shell,
deletes the files Caelestia deployed, restores the backup from the first install,
removes `caelestia-shell`, `caelestia-cli` and `quickshell-git` with whatever only
they needed, and switches the login screen back if the installer changed it.

| Option            | Description                                                         |
|-------------------|---------------------------------------------------------------------|
| `--purge`         | Also remove the packages the installer added and `~/.config/caelestia` |
| `--keep-configs`  | Don't restore the backup                                            |
| `-y`, `--yes`     | Don't ask for confirmation                                          |
| `--dry-run`       | Show what would be done                                             |

`--purge` compares against a package list taken before the first install, so it only
removes what the installer brought in. The kernel, drivers, network, audio, the login
screen and `yay` are never removed.

## Troubleshooting

- AUR errors like `failed to clone`, `404` or `unexpected EOF` usually mean the AUR
  is down for a while. Wait and run the script again.
- Virtual machines need 3D acceleration enabled. Their graphics can't give the shell
  an EGL surface (`Could not create EGL surface`), so in a VM the script adds
  `hl.env("LIBGL_ALWAYS_SOFTWARE", "1")` to `~/.config/caelestia/hypr-user.lua` and
  the bar starts on every login. Delete that line if you move the configs to real hardware.
- To restore your old configs by hand: `tar -xzf ~/caelestia-backup-DATE.tar.gz -C ~`.
  The official installer also leaves a full copy of `~/.config` in `~/.config.bak`.

## License

MIT, see [LICENSE](LICENSE).
