# arroz

Post-install setup for a machine installed with the Omarchy ISO.

The ISO owns the parts worth not rewriting — disk layout, LUKS, btrfs subvolumes,
limine, UKI generation, snapper, and the hardware quirks under `install/hardware/`.
`arroz.sh` owns everything after that: the layer whose defaults don't match how
this machine is actually used.

The script is idempotent. Every phase checks before it acts, so re-running it is
safe and mostly prints "already configured".

## Running it

`.github/workflows/deploy-pages.yml` publishes the installer to GitHub Pages at
`https://edbar42.github.io/arroz/arroz.sh`, which you can open in a browser to
read before running.

```bash
bash <(curl -fsSL https://edbar42.github.io/arroz/arroz.sh)
```

Use this form rather than `curl … | bash`. Piping makes the script *itself* the
process's stdin, so any command that reads stdin — `chsh` authenticating through
PAM, `ssh`, `nvim`, a `yay` prompt — swallows the remaining script text instead
of reading from the terminal. `chsh` in particular fails with
`Authentication token manipulation error`, and the phases after it silently never
run. Process substitution hands the script over on a file descriptor and leaves
stdin attached to the terminal.

If your shell has no process substitution, download first:

```bash
curl -fsSL https://edbar42.github.io/arroz/arroz.sh -o arroz.sh && bash arroz.sh
```

Run as your normal user, not root. `sudo` is invoked where it's needed, and
preflight validates it up front so nothing fails three minutes into a package
transaction.

## Phases

With no arguments every phase runs in order. Named phases run just those:

```bash
./arroz.sh                          # everything, prompt before rebooting
./arroz.sh --no-reboot              # unattended-safe
./arroz.sh configure_locale         # just the locale fix
./arroz.sh --reboot configure_nvme_apst
```

| Phase | What it does |
| --- | --- |
| `configure_locale` | English interface (`en_US.UTF-8`) with Brazilian formats (`pt_BR.UTF-8`) and the `America/Fortaleza` timezone. The ISO configurator hardcodes `sys_lang` and never asks. |
| `configure_keyd` | Capslock becomes esc when tapped, meta when held; esc becomes capslock. System-level, so it applies at the TTY and display manager too. |
| `configure_nvme_apst` | Disables NVMe APST on Samsung 980 drives, whose firmware fails to wake from deep power states — surfacing as an I/O timeout that remounts the btrfs root read-only. Written as a `limine-entry-tool` drop-in so a reinstall doesn't lose it. |
| `configure_background_renderer` | Disables the `omarchy.background` shell plugin so `awww` owns the wallpaper layer instead of fighting it. |
| `install_packages` | Everything Omarchy doesn't already ship, via `yay` so AUR and repo packages resolve in one pass. |
| `remove_omarchy_defaults` | Removes Omarchy default applications that go unused, plus its preinstalled web apps and TUIs. Deliberately keeps the `omarchy` and `omarchy-settings` packages. |
| `configure_firewall` | Opens Syncthing through `ufw`. |
| `configure_shell` | Sets the login shell to zsh. |
| `apply_dotfiles` | `chezmoi init --apply` from the dotfiles repo, over SSH when a working key is present and HTTPS otherwise. |
| `configure_nvim_plugins` | Headless `Lazy! sync`, so the first `nvim` launch isn't a multi-minute wait. |
| `configure_docker` | Enables rootless Docker as the default context, enables user lingering, and disables the system daemon/socket after verification. Refuses to interrupt running system containers; existing data is retained. |
| `enable_services` | `keyd` and `mullvad-daemon`. Syncthing is left disabled on purpose. |

Options: `--reboot` never asks, `--no-reboot` never reboots, `-h` prints usage.
By default the run ends with a single prompt listing every reason a reboot is
pending, rather than each phase deciding on its own.

## Firewall

Omarchy enables `ufw` with a default-deny inbound policy, which blocks
Syncthing's listener outright — the daemon starts, finds no peers, and reports
"Disconnected" indefinitely with nothing in its own log to explain it.

Arch's `syncthing` package ships no `ufw` application profile (Debian's does), so
`configure_firewall` writes `/etc/ufw/applications.d/syncthing` first and then
allows both profiles by name, which keeps `ufw status` readable:

- **`syncthing`** — `22000/tcp`, `22000/udp` (QUIC), `21027/udp` (local discovery)
- **`syncthing-gui`** — `8384/tcp`

The GUI binds to `127.0.0.1` by default, so the `syncthing-gui` rule is inert
until the GUI is repointed at a non-loopback address.

## Restore order

Syncthing is installed but not enabled, and the dotfiles repo defaults to HTTPS
when no key is present. Both are deliberate — starting Syncthing before
`~/personal` and `~/.ssh` are restored produces sync-conflict files instead of a
restored machine.

1. Run `arroz.sh`.
2. Restore `~/.ssh` from the backup drive, then
   `chezmoi git remote set-url origin git@github.com:edbar42/dotfiles`.
3. Restore `~/personal`, then `systemctl --user enable --now syncthing.service`.

## Docker and shell history

Atuin is included in the shell packages. Docker uses `docker-rootless-extras`
from the AUR with RootlessKit and slirp4netns. Run `./arroz.sh configure_docker`
after installing the packages to configure it independently.

Existing rootful images, containers and volumes do not automatically appear in
the rootless daemon. Stop and migrate existing workloads first; recreate Compose
projects with `docker --context rootless compose`, checking bind-mount ownership.
The installer preserves `/var/lib/docker` for rollback. It does not add users to
the root-equivalent `docker` group. Docker-aware tools should use the `rootless`
context; tools that require a socket can use `/run/user/$(id -u)/docker.sock`.
