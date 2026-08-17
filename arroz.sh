#!/usr/bin/env bash
#
# arroz — post-install setup for a machine installed with the Omarchy ISO.
#
# The ISO owns the parts worth not rewriting: disk layout, LUKS, btrfs
# subvolumes, limine, UKI generation, snapper, and the hardware quirks under
# install/hardware/. This script owns everything after that — the layer whose
# defaults don't match how this machine is actually used.
#
# Idempotent. Safe to re-run; every phase checks before it acts.
#
#   curl -fsSL https://edbar42.github.io/arroz/arroz.sh | bash
#
# Phases can be run individually:
#
#   ./arroz.sh locale packages
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# English interface, Brazilian formats. This split is the entire reason this
# phase exists: the Omarchy ISO configurator hardcodes sys_lang to en_US.UTF-8
# and never asks, so a stock install has no way to express it.
LANG_MAIN="en_US.UTF-8"
LANG_FORMATS="pt_BR.UTF-8"
LOCALES_TO_GENERATE=("$LANG_MAIN UTF-8" "$LANG_FORMATS UTF-8")

TIMEZONE="America/Fortaleza"

DOTFILES_REPO_SSH="git@github.com:edbar42/dotfiles"
DOTFILES_REPO_HTTPS="https://github.com/edbar42/dotfiles"

LOGIN_SHELL="/bin/zsh"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
#
# Only what Omarchy does not already install. Base, hardware, boot and
# snapshot packages come from the ISO and are deliberately absent here.
# Installed with yay so AUR and repo packages resolve in one pass.

PKGS_SHELL=(
  zsh zsh-autocomplete zsh-autosuggestions zsh-completions
  zsh-syntax-highlighting zsh-vi-mode
  keychain
  # starship is in quattro's omarchy-base.packages — already installed.
)

PKGS_TERMINAL=(
  ghostty
)

PKGS_DESKTOP=(
  # NOT quickshell: quattro ships quickshell-git, which declares
  # `Conflicts With: quickshell`. The omarchy package depends on quickshell
  # and quickshell-git provides it, so the shell is already there. Listing
  # quickshell explicitly here fails the whole pacman transaction.
  wofi              # walker is gone in quattro; this is the launcher
  awww              # wallpaper daemon
  nwg-look
  python-pywal16
  keyd              # capslock -> esc/meta, see configure_keyd
)

PKGS_CLI=(
  yazi chafa duf procs git-delta oxker-bin tuicr
  7zip
)

PKGS_APPS=(
  zen-browser-bin
  keepassxc
  mullvad-vpn
  telegram-desktop
  vesktop-bin
  onlyoffice-bin
  bruno-bin
  flameshot
  steam
  syncthing
  chezmoi
)

PKGS_DOCS=(
  zathura zathura-pdf-mupdf zathura-cb zathura-djvu zathura-ps
)

PKGS_DEV=(
  dotnet-sdk-10.0
  azure-cli
  rider
  mono
  msbuild
  # herdr is in quattro's omarchy-base.packages — already installed.
)

PKGS_FONTS=(
  ttf-cascadia-code ttf-cascadia-code-nerd ttf-cascadia-mono-nerd
  otf-cascadia-code woff2-cascadia-code
)

PACKAGES=(
  "${PKGS_SHELL[@]}" "${PKGS_TERMINAL[@]}" "${PKGS_DESKTOP[@]}"
  "${PKGS_CLI[@]}" "${PKGS_APPS[@]}" "${PKGS_DOCS[@]}"
  "${PKGS_DEV[@]}" "${PKGS_FONTS[@]}"
)

# Omarchy ships these by default. They are applications, not infrastructure —
# removing them does not touch hardware support, boot, or snapshots.
#
# Deliberately NOT removed: the omarchy and omarchy-settings packages
# themselves. They carry install/hardware/, the limine and snapper config, and
# the udev/systemd drop-ins. Removing them is what turns this into a distro
# project instead of a setup script.
# Verified against quattro's own install/omarchy-base.packages, not guessed.
# Every entry below is confirmed present in that list, and none of them appear
# in the omarchy package's depends=() array, so -Rns will not be blocked.
#
# Regenerate after an Omarchy release:
#
#   gh api 'repos/basecamp/omarchy/contents/install/omarchy-base.packages?ref=quattro' \
#     --jq '.content' | base64 -d | grep -v '^#\|^$' | sort
#
# Notably absent from quattro, so NOT worth listing: waybar, mako, walker,
# omarchy-walker, alacritty, spotify, typora, 1password, impala, bluetui,
# wiremix, gnome-calculator. The quickshell rewrite dropped the bar,
# notification daemon and launcher; the rest were retired earlier.
OMARCHY_UNWANTED=(
  omarchy-nvim                    # own neovim config via chezmoi
  libreoffice-fresh               # onlyoffice
  kdenlive pinta xournalpp evince
  gnome-disk-utility sushi
  lazygit lazydocker
  localsend aether hyprsunset
)

# Omarchy's own small apps, plus its default terminal. Not removed by default.
#
# foot is what xdg-terminal-exec points at, and omarchy-* commands that open a
# terminal go through it — remove foot without repointing xdg-terminal-exec at
# ghostty first and those commands silently stop working. The omacom apps are
# wired into the omarchy menu, so removing them leaves dead entries.
#
# Uncomment individually once you have confirmed the replacement works.
OMARCHY_UNWANTED_RISKY=(
  # foot
  # omacalc omacut omawrite
  # moonlight-qt
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

readonly ANSI_GREEN=$'\033[32m'
readonly ANSI_YELLOW=$'\033[33m'
readonly ANSI_RED=$'\033[31m'
readonly ANSI_RESET=$'\033[0m'

log()  { printf '%s==>%s %s\n' "$ANSI_GREEN" "$ANSI_RESET" "$*"; }
warn() { printf '%sWarning:%s %s\n' "$ANSI_YELLOW" "$ANSI_RESET" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$ANSI_RED" "$ANSI_RESET" "$*" >&2; exit 1; }

trap 'die "failed on line ${BASH_LINENO[0]}: ${BASH_COMMAND}"' ERR

pkg_installed() { pacman -Qq "$1" &>/dev/null; }
cmd_present()   { command -v "$1" &>/dev/null; }

# Phases record why a reboot is needed rather than each deciding on its own, so
# the run ends with one prompt listing every reason instead of several.
REBOOT_REASONS=()
needs_reboot() { REBOOT_REASONS+=("$1"); }

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

preflight() {
  [[ -f /etc/arch-release ]] || die "not an Arch system"
  (( EUID != 0 )) || die "run as your user, not root (sudo is called where needed)"
  cmd_present sudo || die "sudo is required"

  # Fail early rather than three minutes into a package transaction.
  sudo -v || die "sudo authentication failed"

  log "Preflight OK — $(uname -r), user $USER"
}

configure_locale() {
  local locale changed=0

  for locale in "${LOCALES_TO_GENERATE[@]}"; do
    if ! grep -qxF "$locale" /etc/locale.gen 2>/dev/null; then
      log "Enabling locale: $locale"
      # Uncomment if present-but-commented, otherwise append.
      if grep -qxF "#$locale" /etc/locale.gen 2>/dev/null; then
        sudo sed -i "s/^#$locale$/$locale/" /etc/locale.gen
      else
        echo "$locale" | sudo tee -a /etc/locale.gen >/dev/null
      fi
      changed=1
    fi
  done

  if (( changed )); then
    log "Generating locales (this takes a moment)"
    sudo locale-gen
  else
    log "Locales already generated"
  fi

  # LANG picks the interface language; the LC_* overrides pick date, number,
  # currency and paper conventions. Splitting them is the whole point — an
  # English desktop that still writes 16/08/2026 and R$ 1.234,56.
  log "Writing /etc/locale.conf ($LANG_MAIN interface, $LANG_FORMATS formats)"
  sudo tee /etc/locale.conf >/dev/null <<EOF
LANG=$LANG_MAIN
LC_TIME=$LANG_FORMATS
LC_NUMERIC=$LANG_FORMATS
LC_MONETARY=$LANG_FORMATS
LC_PAPER=$LANG_FORMATS
LC_MEASUREMENT=$LANG_FORMATS
LC_ADDRESS=$LANG_FORMATS
LC_TELEPHONE=$LANG_FORMATS
LC_NAME=$LANG_FORMATS
LC_IDENTIFICATION=$LANG_FORMATS
EOF

  if [[ $(timedatectl show -p Timezone --value) != "$TIMEZONE" ]]; then
    log "Setting timezone to $TIMEZONE"
    sudo timedatectl set-timezone "$TIMEZONE"
  fi

  # Already-running processes keep the locale they started with, and that
  # includes the Hyprland session and the shell that launched it.
  [[ ${LANG:-} == "$LANG_MAIN" && ${LC_TIME:-} == "$LANG_FORMATS" ]] ||
    needs_reboot "locale changed to $LANG_MAIN / $LANG_FORMATS; running processes keep the old one"
}

configure_keyd() {
  # System-level remap, so it applies at the TTY and the display manager too,
  # not just inside the Hyprland session. chezmoi can't own this: it's /etc.
  local conf=/etc/keyd/default.conf

  if [[ -f $conf ]] && grep -q 'overload(meta, esc)' "$conf"; then
    log "keyd already configured"
    return
  fi

  log "Writing keyd config (capslock -> esc tapped / meta held)"
  sudo mkdir -p /etc/keyd
  sudo tee "$conf" >/dev/null <<'EOF'
[ids]
*

[main]
# esc when pressed, meta when held
capslock = overload(meta, esc)

# esc to capslock
esc = capslock
EOF
}

configure_nvme_apst() {
  # Samsung 980 firmware does not reliably wake from deep NVMe APST power
  # states. Linux's nvme driver drives them far harder than Windows' does, so
  # a failed wake shows up as an I/O timeout and btrfs (errors=remount-ro)
  # force-remounts the root read-only mid-session. Same hardware never did it
  # under Windows, which is what makes the driver the culprit rather than the
  # disk. Disabling APST costs a little idle power and stops the corruption.
  #
  # Written as a limine-entry-tool drop-in, NOT appended to /etc/default/limine.
  # That file is generated by the ISO from a template (the installer substitutes
  # @@CMDLINE@@ into it), so anything added there is lost on a reinstall — which
  # is precisely how this fix went missing the first time. Drop-ins are also how
  # Omarchy's own hardware fixes do it, e.g. install/hardware/intel/fred.sh.
  local drop_in=/etc/limine-entry-tool.d/arroz-nvme-apst.conf
  local param="nvme_core.default_ps_max_latency_us=0"
  local model matched=""

  for model_file in /sys/class/nvme/nvme*/model; do
    [[ -r $model_file ]] || continue
    model=$(tr -d ' ' <"$model_file")
    # Matches the 980 family, PRO included. Broad on purpose: a read-only root
    # is a far worse outcome than a desktop idling a fraction of a watt higher.
    [[ $model == *SamsungSSD980* ]] && matched="$model"
  done

  if [[ -z $matched && -z ${ARROZ_FORCE_NVME_APST_FIX:-} ]]; then
    log "No Samsung 980 NVMe found; leaving APST alone"
    return
  fi

  if [[ -f $drop_in ]] && grep -qF "$param" "$drop_in"; then
    log "NVMe APST fix already present in $drop_in"
  else
    log "Disabling NVMe APST for ${matched:-forced} via $drop_in"
    sudo mkdir -p /etc/limine-entry-tool.d
    sudo tee "$drop_in" >/dev/null <<EOF
# Samsung 980 firmware fails to wake from deep APST states, which surfaces as
# an nvme I/O timeout and remounts the btrfs root read-only. See arroz.sh.
KERNEL_CMDLINE[default]+=" $param"
EOF

    # The drop-in only takes effect once the boot entries and UKI are rebuilt.
    # limine-mkinitcpio is the wrapper that drives limine-entry-tool with the
    # flags it needs; calling limine-entry-tool bare fails on missing params.
    log "Rebuilding boot entries (limine-mkinitcpio)"
    sudo limine-mkinitcpio
  fi

  # The running kernel keeps its old command line until reboot, so this is
  # informational rather than a failure. This is the one change here that a
  # re-login cannot cover: the cmdline is fixed at boot.
  if ! grep -qF "$param" /proc/cmdline; then
    warn "NVMe APST fix is staged but not active until reboot"
    needs_reboot "NVMe APST fix ($param) is staged in the boot entries but the running kernel predates it"
  fi
}

configure_background_renderer() {
  # Omarchy's shell ships a first-party background service (omarchy.background,
  # kinds: ["service"]) that reads ~/.local/state/omarchy/current/background and
  # paints it as ONE opaque image across ALL monitors, on the same Wayland layer
  # awww-daemon draws to. With awww in charge of per-monitor wallpapers, the two
  # fight and awww loses.
  #
  # Deleting the symlink is not enough: omarchy-theme-set recreates it on every
  # theme change (set_theme_background_link -> ln -nsf). Disabling the plugin is
  # durable, because PluginRegistry.isEnabled() checks disabledPlugins[] BEFORE
  # the first-party auto-enable, so the renderer stays unloaded whether or not
  # the link exists.
  local cfg="$HOME/.config/omarchy/shell.json"
  local link="$HOME/.local/state/omarchy/current/background"
  local plugin="omarchy.background"

  if [[ ! -f $cfg ]]; then
    warn "$cfg not found; skipping background renderer (run after the shell has started once)"
    return
  fi
  cmd_present jq || die "jq is required to edit shell.json"

  if jq -e --arg p "$plugin" '(.disabledPlugins // []) | index($p)' "$cfg" >/dev/null 2>&1; then
    log "$plugin already disabled"
  else
    log "Disabling $plugin so awww owns the wallpaper layer"
    local tmp
    tmp=$(mktemp)
    # Written through a temp file so an interrupted run can't leave a truncated
    # shell.json, which the shell would fall back to defaults over.
    if jq --arg p "$plugin" \
         '.disabledPlugins = ((.disabledPlugins // []) + [$p] | unique)' \
         "$cfg" >"$tmp"; then
      mv "$tmp" "$cfg"
    else
      rm -f "$tmp"
      die "failed to edit $cfg"
    fi

    warn "shell.json is chezmoi-managed — sync this back or the next apply reverts it:"
    warn "  chezmoi re-add ~/.config/omarchy/shell.json"
  fi

  # Stale link from a previous theme-set. Harmless once the plugin is off, but
  # omarchy-bar-text-color still reads it for transparent-bar contrast sampling.
  if [[ -L $link || -e $link ]]; then
    log "Removing background symlink $link"
    rm -f "$link"
  fi

  # Takes effect immediately when the shell is up; otherwise it applies at next
  # start, which on a fresh install is the first graphical login anyway.
  if pgrep -x quickshell >/dev/null 2>&1 && cmd_present omarchy-plugin-disable; then
    omarchy-plugin-disable "$plugin" >/dev/null 2>&1 ||
      warn "could not disable $plugin over IPC; it will apply on next shell start"
  fi
}

install_packages() {
  cmd_present yay || die "yay not found — the Omarchy ISO should have installed it"

  local pkg missing=()
  for pkg in "${PACKAGES[@]}"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done

  if (( ${#missing[@]} == 0 )); then
    log "All ${#PACKAGES[@]} packages already installed"
    return
  fi

  log "Installing ${#missing[@]} of ${#PACKAGES[@]} packages"
  printf '    %s\n' "${missing[@]}"
  yay -S --needed --noconfirm "${missing[@]}"
}

remove_omarchy_defaults() {
  local pkg present=()
  for pkg in "${OMARCHY_UNWANTED[@]}" "${OMARCHY_UNWANTED_RISKY[@]}"; do
    pkg_installed "$pkg" && present+=("$pkg")
  done

  if (( ${#present[@]} == 0 )); then
    log "No unwanted Omarchy defaults present"
    return
  fi

  log "Removing ${#present[@]} unused Omarchy defaults"
  printf '    %s\n' "${present[@]}"

  # -Rns pulls unused dependencies too. Non-fatal: a package another thing
  # legitimately depends on should stay, and that is not an error worth
  # aborting the whole run over.
  sudo pacman -Rns --noconfirm "${present[@]}" || {
    warn "some packages could not be removed (likely still depended on); continuing"
  }

  # Omarchy generates chromium --app= launchers for its web apps. Nothing here
  # uses them, and they clutter every launcher and menu.
  local webapps
  mapfile -t webapps < <(
    grep -ls 'chromium.*--app=' ~/.local/share/applications/*.desktop 2>/dev/null || true
  )
  if (( ${#webapps[@]} > 0 )); then
    log "Removing ${#webapps[@]} generated web app launchers"
    rm -f "${webapps[@]}"
    update-desktop-database ~/.local/share/applications 2>/dev/null || true
  fi
}

configure_shell() {
  local current
  current=$(getent passwd "$USER" | cut -d: -f7)

  if [[ $current == "$LOGIN_SHELL" ]]; then
    log "Login shell already $LOGIN_SHELL"
    return
  fi

  [[ -x $LOGIN_SHELL ]] || die "$LOGIN_SHELL not found — did the package phase run?"

  log "Changing login shell to $LOGIN_SHELL"
  chsh -s "$LOGIN_SHELL"
  needs_reboot "login shell changed to $LOGIN_SHELL; the current session still runs $current"
}

apply_dotfiles() {
  cmd_present chezmoi || die "chezmoi not installed — did the package phase run?"

  if [[ -d ~/.local/share/chezmoi/.git ]]; then
    log "chezmoi already initialized; applying"
    chezmoi apply
    return
  fi

  # The remote is an SSH URL, which needs a key that a fresh machine does not
  # have yet. Restore ~/.ssh from the backup drive first, or this falls back to
  # HTTPS (fine for pulling, but pushing will need the key anyway).
  local repo
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 |
       grep -q 'successfully authenticated'; then
    repo="$DOTFILES_REPO_SSH"
    log "GitHub SSH auth works; using $repo"
  else
    repo="$DOTFILES_REPO_HTTPS"
    warn "no working GitHub SSH key — using HTTPS ($repo)"
    warn "restore ~/.ssh from the backup drive, then: chezmoi git remote set-url origin $DOTFILES_REPO_SSH"
  fi

  log "Initializing dotfiles from $repo"
  chezmoi init --apply "$repo"
}

configure_nvim_plugins() {
  # LazyVim installs plugins on first launch, which turns "open an editor"
  # into a multi-minute wait the first time. Pre-sync them headlessly instead.
  # `Lazy sync` covers install + update + clean (drops anything not in the
  # config's spec, including whatever omarchy-nvim's old plugin dir left
  # behind) in one pass.
  cmd_present nvim || { warn "nvim not found; skipping LazyVim plugin sync"; return; }

  [[ -f ~/.config/nvim/lua/config/options.lua ]] || {
    warn "~/.config/nvim not set up yet; skipping LazyVim plugin sync (run apply_dotfiles first)"
    return
  }

  log "Syncing LazyVim plugins (install + clean, headless)"
  timeout 300 nvim --headless "+Lazy! sync" +qa ||
    warn "LazyVim headless sync failed or timed out; open nvim once by hand to finish"
}

enable_services() {
  # Only services Omarchy does not already enable. Everything hardware, boot
  # and snapshot related is already handled by the ISO.
  local svc
  for svc in keyd.service mullvad-daemon.service; do
    if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      log "Enabling $svc"
      sudo systemctl enable --now "$svc"
    fi
  done

  # Syncthing is deliberately left disabled. It syncs ~/personal, and starting
  # it before the dotfiles and backup drive are in place is how you get
  # sync-conflict files instead of a restored machine.
  if ! systemctl --user is-enabled --quiet syncthing.service 2>/dev/null; then
    warn "syncthing not enabled — start it once ~/personal is restored:"
    warn "  systemctl --user enable --now syncthing.service"
  fi
}

finish() {
  cat <<EOF

$(log "arroz setup complete")

  Locale     $LANG_MAIN interface / $LANG_FORMATS formats
  Timezone   $TIMEZONE
  Shell      $LOGIN_SHELL
  Dotfiles   $(chezmoi source-path 2>/dev/null || echo 'not initialized')

Remaining, by hand:

EOF
}

prompt_reboot() {
  (( ${#REBOOT_REASONS[@]} > 0 )) || return 0

  echo
  warn "A reboot is needed to finish:"
  printf '  - %s\n' "${REBOOT_REASONS[@]}" >&2
  echo

  if [[ ${REBOOT_MODE:-ask} == "never" ]]; then
    log "Skipping reboot (--no-reboot). Reboot when convenient."
    return 0
  fi

  if [[ ${REBOOT_MODE:-ask} == "always" ]]; then
    log "Rebooting (--reboot)"
    sudo reboot
    return 0
  fi

  # Under `curl … | bash` stdin is the script itself, so a bare read would
  # swallow the remaining source instead of waiting for an answer. Read the
  # answer from the terminal directly; when there isn't one (a pipe with no
  # controlling tty, a systemd unit, CI) fall through to a message rather than
  # rebooting a machine nobody is watching.
  # Test by opening it, not with -r: /dev/tty is a readable device node even
  # when the process has no controlling terminal, so a permission test passes
  # and the open then fails at the prompt.
  if ! (exec </dev/tty) 2>/dev/null; then
    warn "No terminal to prompt on — not rebooting. Run: sudo reboot"
    return 0
  fi

  local answer
  if cmd_present gum; then
    if gum confirm "Reboot now?" </dev/tty; then
      log "Rebooting"
      sudo reboot
    else
      log "Not rebooting. Run 'sudo reboot' when convenient."
    fi
    return 0
  fi

  read -r -p "Reboot now? [y/N] " answer </dev/tty || answer=""
  case "$answer" in
    [yY] | [yY][eE][sS])
      log "Rebooting"
      sudo reboot
      ;;
    *)
      log "Not rebooting. Run 'sudo reboot' when convenient."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

ALL_PHASES=(
  configure_locale
  configure_keyd
  configure_nvme_apst
  configure_background_renderer
  install_packages
  remove_omarchy_defaults
  configure_shell
  apply_dotfiles
  configure_nvim_plugins
  enable_services
)

usage() {
  cat <<EOF
Usage: arroz.sh [--reboot|--no-reboot] [phase ...]

With no phase arguments, runs every phase in order.

Options:
  --reboot      Reboot at the end without asking, if anything needs one
  --no-reboot   Never reboot; just print what is still pending
  -h, --help    Show this help

Phases:
$(printf '  %s\n' "${ALL_PHASES[@]}")

Examples:
  ./arroz.sh                          # everything, prompt before rebooting
  ./arroz.sh --no-reboot              # unattended-safe
  ./arroz.sh configure_locale         # just the locale fix
  ./arroz.sh --reboot configure_nvme_apst
EOF
}

main() {
  REBOOT_MODE=ask

  local phases=()
  while (( $# > 0 )); do
    case "$1" in
      -h | --help)  usage; exit 0 ;;
      --reboot)     REBOOT_MODE=always; shift ;;
      --no-reboot)  REBOOT_MODE=never;  shift ;;
      -*)           die "unknown option: $1" ;;
      *)            phases+=("$1"); shift ;;
    esac
  done

  # Validate arguments before preflight so a typo fails instantly instead of
  # after a sudo prompt.
  local phase
  if (( ${#phases[@]} > 0 )); then
    for phase in "${phases[@]}"; do
      declare -F "$phase" >/dev/null || die "unknown phase: $phase"
    done
  else
    phases=("${ALL_PHASES[@]}")
  fi

  preflight

  for phase in "${phases[@]}"; do
    "$phase"
  done

  finish
  prompt_reboot
}

main "$@"
