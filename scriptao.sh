#!/bin/bash

# Sync time
sudo systemctl restart systemd-timesyncd

# Ensure screensaver/sleep doesn't set in during updates
hyprctl dispatch tagwindow +noidle &> /dev/null || true

# Reset all package DBs and then update
sudo pacman -Syyu --noconfirm

# Turn on bluetooth service so blueberry or bluetui works out the box
echo "Let's turn on Bluetooth service so the controls work"
if systemctl is-enabled --quiet bluetooth.service && systemctl is-active --quiet bluetooth.service; then
  # Bluetooth is already enabled, nothing to change
  :
else
  sudo systemctl enable --now bluetooth.service
fi

set_docker_config

set_default_apps

source "$OMARCHY_PATH/install/login/plymouth.sh"
echo "Switching to polkit-gnome for better fingerprint authentication compatibility"

if ! command -v /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &>/dev/null; then
  sudo pacman -S --noconfirm --needed polkit-gnome
  systemctl --user stop hyprpolkitagent
  systemctl --user disable hyprpolkitagent
  sudo pacman -Rns --noconfirm hyprpolkitagent
  setsid /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
fi
echo "Migrate to the modular implementation of hyprlock"

if [ -L ~/.config/hypr/hyprlock.conf ]; then
  rm ~/.config/hypr/hyprlock.conf
  cp ~/.local/share/omarchy/config/hypr/hyprlock.conf ~/.config/hypr/hyprlock.conf
fi
echo "Enable battery low notifications for laptops"
if ls /sys/class/power_supply/BAT* &>/dev/null && [[ ! -f ~/.local/share/omarchy/config/systemd/user/omarchy-battery-monitor.service ]]; then
  mkdir -p ~/.config/systemd/user

  cp ~/.local/share/omarchy/config/systemd/user/omarchy-battery-monitor.* ~/.config/systemd/user/

  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-battery-monitor.timer || true
fi

echo "Update to use UWSM and seamless login"

if omarchy-cmd-missing uwsm; then
  sudo rm -f /etc/systemd/system/getty@tty1.service.d/override.conf
  sudo rmdir /etc/systemd/system/getty@tty1.service.d/ 2>/dev/null || true

  if [ -f "$HOME/.bash_profile" ]; then
    # Remove the specific line
    sed -i '/^\[\[ -z \$DISPLAY && \$(tty) == \/dev\/tty1 \]\] && exec Hyprland$/d' "$HOME/.bash_profile"
    echo "Cleaned up .bash_profile"
  fi

  if [ -f "$HOME/.config/environment.d/fcitx.conf" ]; then
    echo "Removing GTK_IM_MODULE from fcitx config for Wayland..."
    sed -i 's/^GTK_IM_MODULE=fcitx$//' "$HOME/.config/environment.d/fcitx.conf"
  fi

  source $OMARCHY_PATH/install/login/plymouth.sh
fi
echo "Add override to only require one network interface to be online"

if [[ ! -f /etc/systemd/system/systemd-networkd-wait-online.service.d/wait-for-only-one-interface.conf ]]; then
  sudo mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
  sudo tee /etc/systemd/system/systemd-networkd-wait-online.service.d/wait-for-only-one-interface.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any
EOF
fi
echo "Set a default fontconfig"

if [[ ! -f "$HOME/.config/fontconfig/fonts.conf" ]]; then
  mkdir -p ~/.config/fontconfig
  cp ~/.local/share/omarchy/config/fontconfig/fonts.conf ~/.config/fontconfig/
  fc-cache -fv
fi
echo "Setting up GPG configuration with multiple keyservers for better reliability"

if [[ ! -f /etc/gnupg/dirmngr.conf ]]; then
  sudo mkdir -p /etc/gnupg
  sudo cp ~/.local/share/omarchy/default/gpg/dirmngr.conf /etc/gnupg/
  sudo chmod 644 /etc/gnupg/dirmngr.conf
  sudo gpgconf --kill dirmngr || true
  sudo gpgconf --launch dirmngr || true
fi
echo "Add color and animation to pacman installs"

grep -q '^Color' /etc/pacman.conf || sudo sed -i '/^\[options\]/a Color' /etc/pacman.conf
grep -q '^ILoveCandy' /etc/pacman.conf || sudo sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf
echo "Add new matte black theme"

if [[ ! -L "~/.config/omarchy/themes/matte-black" ]]; then
  ln -snf ~/.local/share/omarchy/themes/matte-black ~/.config/omarchy/themes/
fi
echo "Install missing docker-buildx package for out-of-the-box Kamal compatibility"

omarchy-pkg-add docker-buildx

echo "Prevent docker from requiring network readiness on boot"

if [[ ! -f /etc/systemd/system/docker.service.d/no-block-boot.conf ]]; then
  sudo mkdir -p /etc/systemd/system/docker.service.d/
  sudo tee /etc/systemd/system/docker.service.d/no-block-boot.conf <<'EOF'
[Unit]
DefaultDependencies=no
EOF

  sudo mkdir -p /etc/systemd/system/plymouth-quit.service.d/
  sudo tee /etc/systemd/system/plymouth-quit.service.d/wait-for-graphical.conf <<'EOF'
[Unit]
After=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl mask plymouth-quit-wait.service
fi
echo "Fix Plymouth login positioning in multi-monitor setups + limit password from overflowing"
omarchy-refresh-plymouth
echo "Add hyprsunset blue light filter"
if ! command -v hyprsunset &>/dev/null; then
  sudo pacman -S --noconfirm --needed hyprsunset
fi
echo "Enable auto-discovery of network printers"

if [[ ! -f /etc/systemd/resolved.conf.d/10-disable-multicast.conf ]]; then
  omarchy-pkg-add avahi nss-mdns

  # Disable multicast dns in resolved. Avahi will provide this for better network printer discovery
  sudo mkdir -p /etc/systemd/resolved.conf.d
  echo "[Resolve]\nMulticastDNS=no" | sudo tee /etc/systemd/resolved.conf.d/10-disable-multicast.conf
  sudo systemctl enable --now avahi-daemon.service
fi

if ! grep -q '^CreateRemotePrinters Yes' /etc/cups/cups-browsed.conf; then
  omarchy-pkg-add cups-browsed
  # Enable automatically adding remote printers
  echo 'CreateRemotePrinters Yes' | sudo tee -a /etc/cups/cups-browsed.conf
  sudo systemctl enable --now cups-browsed.service
fi
echo "Add support for accessing Android phone data via file manager"

omarchy-pkg-add gvfs-mtp

echo "Set SwayOSD max volume back to 100"

if ! grep -q "max_volume = 100" ~/.config/swayosd/config.toml; then
  sed -i 's/max_volume = 150/max_volume = 100/' ~/.config/swayosd/config.toml
  omarchy-restart-swayosd
fi
echo "Add xmlstarlet needed for updating fonts via Omarchy menu"

omarchy-pkg-add xmlstarlet
echo "Fix multicast dns config for printers"

echo -e "[Resolve]\nMulticastDNS=no" | sudo tee /etc/systemd/resolved.conf.d/10-disable-multicast.conf
echo "Make new Osaka Jade theme available as new default"

if [[ ! -L ~/.config/omarchy/themes/osaka-jade ]]; then
  rm -rf ~/.config/omarchy/themes/osaka-jade
  git -C ~/.local/share/omarchy checkout -f themes/osaka-jade
  ln -nfs ~/.local/share/omarchy/themes/osaka-jade ~/.config/omarchy/themes/osaka-jade
fi
echo "Update Waybar config to fix path issue with update-available icon click"

if grep -q "alacritty --class Omarchy --title Omarchy -e omarchy-update" ~/.config/waybar/config.jsonc; then
  sed -i 's|\("on-click": "alacritty --class Omarchy --title Omarchy -e \)omarchy-update"|\1omarchy-update"|' ~/.config/waybar/config.jsonc
  omarchy-restart-waybar
fi
echo "Fix the expand icon margin in the Waybar style"

omarchy-refresh-config waybar/style.css
echo "Tune MTU probing for more reliable SSH"

echo "net.ipv4.tcp_mtu_probing=1" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
echo "Disable systemd-networkd-wait-online"

sudo rm -rf /etc/systemd/system/systemd-networkd-wait-online.service.d/wait-for-only-one-interface.conf
sudo systemctl disable systemd-networkd-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
echo "Update polkit policy to yield to fingerprint and fido2"

# If fprint exists in polkit, it was wrong and needs reset
if [ -f /etc/pam.d/polkit-1 ] && grep -Fq 'pam_fprintd.so' /etc/pam.d/polkit-1; then
  sudo tee /etc/pam.d/polkit-1 >/dev/null <<'EOF'
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
fi

# If fido2 is in sudo, it won't be in polkit either way
if grep -q pam_u2f.so /etc/pam.d/sudo && [ -f /etc/pam.d/polkit-1 ] && ! grep -q 'pam_u2f.so' /etc/pam.d/polkit-1; then
  sudo sed -i '1i auth      sufficient pam_u2f.so cue authfile=/etc/fido2/fido2' /etc/pam.d/polkit-1
elif grep -q pam_u2f.so /etc/pam.d/sudo && [ ! -f /etc/pam.d/polkit-1 ]; then
  sudo tee /etc/pam.d/polkit-1 >/dev/null <<'EOF'
auth      sufficient pam_u2f.so cue authfile=/etc/fido2/fido2
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
fi

echo "Add start burst limit to login"

if [ -f /etc/systemd/system/omarchy-seamless-login.service ]; then
  cat <<EOF | sudo tee /etc/systemd/system/omarchy-seamless-login.service
[Unit]
Description=Omarchy Seamless Auto-Login
Documentation=https://github.com/basecamp/omarchy
Conflicts=getty@tty1.service
After=systemd-user-sessions.service getty@tty1.service plymouth-quit.service systemd-logind.service
PartOf=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/seamless-login uwsm start -- hyprland.desktop
Restart=always
RestartSec=2
StartLimitIntervalSec=30
StartLimitBurst=2
User=$USER
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal+console
PAMName=login

[Install]
WantedBy=graphical.target
EOF
fi
echo "Ensure DNS resolver configuration is properly symlinked"

sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
echo "Reset DNS configuration to DHCP (remove forced Cloudflare DNS)"

# Reset DNS to use DHCP by default instead of forcing Cloudflare
# This preserves local development environments (.local domains, etc.)
# Users can still opt-in to Cloudflare DNS using: omarchy-setup-dns cloudflare

if [ -f /etc/systemd/resolved.conf ]; then
  # Backup current config with timestamp
  backup_timestamp=$(date +"%Y%m%d%H%M%S")
  sudo cp /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.bak.${backup_timestamp}"

  # Remove explicit DNS entries to use DHCP
  sudo sed -i '/^DNS=/d' /etc/systemd/resolved.conf
  sudo sed -i '/^FallbackDNS=/d' /etc/systemd/resolved.conf

  # Add empty DNS entries to ensure DHCP is used
  echo "DNS=" | sudo tee -a /etc/systemd/resolved.conf >/dev/null
  echo "FallbackDNS=" | sudo tee -a /etc/systemd/resolved.conf >/dev/null

  # Remove any forced DNS config from systemd-networkd
  if [ -f /etc/systemd/network/99-omarchy-dns.network ]; then
    sudo rm -f /etc/systemd/network/99-omarchy-dns.network
    sudo systemctl restart systemd-networkd
  fi

  # Restart systemd-resolved to apply changes
  sudo systemctl restart systemd-resolved

  echo "DNS configuration reset to use DHCP (router DNS)"
  echo "To use Cloudflare DNS, run: omarchy-setup-dns Cloudflare"
fiecho "Ensure fcitx5 does not overwrite xkb layout"

FCITX5_CONF_DIR="$HOME/.config/fcitx5/conf"
FCITX5_XCB_CONF="$FCITX5_CONF_DIR/xcb.conf"

if [[ ! -f $FCITX5_XCB_CONF ]]; then
  mkdir -p "$FCITX5_CONF_DIR"
  cp "$OMARCHY_PATH/config/fcitx5/conf/xcb.conf" "$FCITX5_XCB_CONF"
fi

echo "Ensure TTE and dependencies are installed"

omarchy-pkg-add python-poetry-core python-terminaltexteffects
echo "Add potentially missing dependency for power profile controls"

omarchy-pkg-add python-gobject
echo "Disable USB autosuspend"

bash "$OMARCHY_PATH/install/config/hardware/usb-autosuspend.sh"
#!/bin/bash

echo "Use verbose package lists for pacman"

sudo sed -i '/^ILoveCandy$/a VerbosePkgLists' /etc/pacman.conf
echo "Migrate AUR packages to official repos where possible"

reinstall_package_opr() {
  if omarchy-pkg-present $1; then
    sudo pacman -Rns --noconfirm $1
    sudo pacman -S --noconfirm ${2:-$1}
  fi
}

echo "Checking and correcting Snapper configs if needed"
if command -v snapper &>/dev/null; then
  if ! sudo snapper list-configs 2>/dev/null | grep -q "root"; then
    sudo snapper -c root create-config /
  fi

  if ! sudo snapper list-configs 2>/dev/null | grep -q "home"; then
    sudo snapper -c home create-config /home
  fi
fi
echo "Add Samba network drive support to the file manager"

omarchy-pkg-add gvfs-smb

omarchy-pkg-add qt5-wayland
echo "Fix audio input on AMD Framework laptops"

source $OMARCHY_PATH/install/config/hardware/fix-f13-amd-audio-input.sh || true
echo "Enable UFW systemd service for existing installations"

if omarchy-cmd-present ufw; then
    if sudo ufw status | grep -q "Status: active\|22/tcp\|53317"; then
        if ! systemctl is-enabled ufw >/dev/null 2>&1; then
            sudo systemctl enable ufw --now
            echo "UFW systemd service enabled"
        fi
    fi
fi

echo "Add locale to the waybar clock format"

sed -i \
  -e 's/{:%A %H:%M}/{:L%A %H:%M}/' \
  -e 's/{:%d %B W%V %Y}/{:L%d %B W%V %Y}/' \
  "$HOME/.config/waybar/config.jsonc"echo "Fix DHCP DNS to allow VPN DNS override"

if [ -f /etc/systemd/resolved.conf ]; then
  if grep -q "^DNS=$" /etc/systemd/resolved.conf && grep -q "^FallbackDNS=$" /etc/systemd/resolved.conf; then
    sudo sed -i '/^DNS=$/d; /^FallbackDNS=$/d' /etc/systemd/resolved.conf
    sudo systemctl restart systemd-resolved
  fi
fiecho "Enable mDNS resolution for existing Avahi installations"

if systemctl is-enabled avahi-daemon.service >/dev/null 2>&1; then
  if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
    sudo sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve files myhostname dns/' /etc/nsswitch.conf
  fi
echo "6Ghz Wi-Fi + Intel graphics acceleration for existing installations"

bash "$OMARCHY_PATH/install/config/hardware/set-wireless-regdom.sh"
bash "$OMARCHY_PATH/install/config/hardware/intel.sh"
echo "Add screen recording indicator to Waybar"

echo "Update plymouth theme to avoid freetype2 issue that broke the styled login screen"
omarchy-refresh-plymouth
echo "Enabling vim keys in btop"

CONFIG_FILE=~/.config/btop/btop.conf

if [[ -f $CONFIG_FILE ]]; then
  if grep -q "^vim_keys = " "$CONFIG_FILE"; then
    sed -i 's/^vim_keys = False/vim_keys = True/' "$CONFIG_FILE"
  fi
fi
echo "Create ~/Work with ./bin in the path for contained projects"

mise_config="$HOME/Work/.mise.toml"

if [[ -f $mise_config ]]; then
  cp $mise_config "$mise_config.bak.$(date +%s)"
fi

source "$OMARCHY_PATH/install/config/mise-work.sh"

echo "Ensure .config/hypr/looknfeel.conf is available and included"

if [[ ! -f ~/.config/hypr/looknfeel.conf ]]; then
  cp $OMARCHY_PATH/config/hypr/looknfeel.conf ~/.config/hypr/looknfeel.conf
fi

if [[ -f ~/.config/hypr/hyprland.conf ]]; then
  grep -qx 'source = ~/.config/hypr/looknfeel.conf' ~/.config/hypr/hyprland.conf ||
    sed -i '/^source = ~\/.config\/hypr\/envs\.conf$/a source = ~/.config/hypr/looknfeel.conf' ~/.config/hypr/hyprland.conf
fi
echo "Set \$TERMINAL and \$EDITOR in ~/.config/uwsm/default so entire system can rely on it"

# Set terminal and editor default in uwsm
omarchy-refresh-config uwsm/default
omarchy-refresh-config uwsm/env
omarchy-state set reboot-required

# Ensure scrolltouchpad setting applies to all terminals
if grep -q "scrolltouchpad 1.5, class:Alacritty" ~/.config/hypr/input.conf; then
  sed -i 's/windowrule = scrolltouchpad 1\.5, class:Alacritty/windowrule = scrolltouchpad 1.5, tag:terminal/' ~/.config/hypr/input.conf
fi

# Use default editor for keybinding
if grep -q "bindd = SUPER, N, Neovim" ~/.config/hypr/bindings.conf; then
  sed -i '/SUPER, N, Neovim, exec/ c\bindd = SUPER, N, Editor, exec, omarchy-launch-editor' ~/.config/hypr/bindings.conf
fi

# Use default terminal for keybinding
if grep -q "terminal = uwsm app" ~/.config/hypr/bindings.conf; then
  sed -Ei '/terminal = uwsm[- ]app -- alacritty/ c\$terminal = uwsm-app -- $TERMINAL' ~/.config/hypr/bindings.conf
fi

echo "Add thunderbolt support to boot image"

omarchy-pkg-add bolt

if [[ ! -f /etc/mkinitcpio.conf.d/thunderbolt_module.conf ]]; then
  sudo tee /etc/mkinitcpio.conf.d/thunderbolt_module.conf <<EOF >/dev/null
MODULES+=(thunderbolt)
EOF
fi

if omarchy-cmd-present limine-update; then
  sudo limine-update
fi
#!/bin/bash
set -e

error_exit() {
  echo -e "\033[31mERROR: Migration failed! Manual intervention required.\033[0m" >&2
  echo -e "\033[31mDO NOT REBOOT - System may be in inconsistent state until the error is fixed.\033[0m" >&2
  exit 1
}

trap error_exit ERR

echo "Change display manager to SDDM"

omarchy-pkg-add sddm libsecret gnome-keyring || error_exit

sudo mkdir -p /etc/sddm.conf.d

cat <<EOF | sudo tee /etc/sddm.conf.d/autologin.conf
[Autologin]
User=$USER
Session=hyprland-uwsm

[Theme]
Current=breeze
EOF

sudo systemctl disable omarchy-seamless-login.service
sudo systemctl unmask plymouth-quit-wait.service
sudo systemctl enable getty@tty1.service
sudo systemctl enable sddm.service
sudo systemctl daemon-reload

if systemctl is-enabled omarchy-seamless-login.service >/dev/null 2>&1; then
  echo -e "\033[31mError: omarchy-seamless-login.service is still enabled\033[0m" >&2
  error_exit
fi

if systemctl is-masked plymouth-quit-wait.service >/dev/null 2>&1; then
  echo -e "\033[31mError: plymouth-quit-wait.service is still masked\033[0m" >&2
  error_exit
fi

if ! systemctl is-enabled getty@tty1.service >/dev/null 2>&1; then
  echo -e "\033[31mError: getty@tty1.service is not enabled\033[0m" >&2
  error_exit
fi

if ! systemctl is-enabled sddm.service >/dev/null 2>&1; then
  echo -e "\033[31mError: sddm.service is not enabled\033[0m" >&2
  error_exit
fi

sudo rm -f /usr/local/bin/seamless-login
sudo rm -f /etc/systemd/system/plymouth-quit.service.d/wait-for-graphical.conf
sudo rm -f /etc/systemd/system/omarchy-seamless-login.service
echo "Update UKI to custom named entry"

if command -v limine &>/dev/null && [[ -f /etc/default/limine ]]; then
  if grep -q "^ENABLE_UKI=yes" /etc/default/limine; then
    if ! grep -q "^CUSTOM_UKI_NAME=" /etc/default/limine; then
      sudo sed -i '/^ENABLE_UKI=yes/a CUSTOM_UKI_NAME="omarchy"' /etc/default/limine
    fi

    # Remove the archinstall-created Limine entry
    while IFS= read -r bootnum; do
      sudo efibootmgr -b "$bootnum" -B >/dev/null 2>&1
    done < <(efibootmgr | grep -E "^Boot[0-9]{4}\*? Arch Linux Limine" | sed 's/^Boot\([0-9]\{4\}\).*/\1/')

    sudo limine-update

    uki_file=$(find /boot/EFI/Linux/ -name "omarchy*.efi" -printf "%f\n" 2>/dev/null | head -1)

    if [[ -n "$uki_file" ]]; then
      while IFS= read -r bootnum; do
        sudo efibootmgr -b "$bootnum" -B >/dev/null 2>&1
      done < <(efibootmgr | grep -E "^Boot[0-9]{4}\*? Omarchy" | sed 's/^Boot\([0-9]\{4\}\).*/\1/')

      # Skip EFI entry creation on Apple hardware
      if ! cat /sys/class/dmi/id/bios_vendor 2>/dev/null | grep -qi "Apple"; then
        sudo efibootmgr --create \
          --disk "$(findmnt -n -o SOURCE /boot | sed 's/p\?[0-9]*$//')" \
          --part "$(findmnt -n -o SOURCE /boot | grep -o 'p\?[0-9]*$' | sed 's/^p//')" \
          --label "Omarchy" \
          --loader "\\EFI\\Linux\\$uki_file"
      fi
    fi
  else
    echo "Not using UKI. Not making any changes."
  fi
else
  echo "Boot config is non-standard. Not making any changes."
fi

echo "Fix Tailscale split DNS compatibility by removing [!UNAVAIL=return] from nsswitch.conf"

if grep -q '\[!UNAVAIL=return\]' /etc/nsswitch.conf; then
  sudo sed -i 's/resolve \[!UNAVAIL=return\]/resolve/g' /etc/nsswitch.conf
fiecho "Enable fast shutdown"
source $OMARCHY_PATH/install/config/fast-shutdown.sh 
echo "Adding hidden entries for electron apps"

cp $OMARCHY_PATH/applications/hidden/electron*.desktop ~/.local/share/applications/
echo "Update Hyprlock with better placeholder position and show all fail text"

omarchy-refresh-hyprlock
echo "Symlink systemd-resolved to /etc/resolv.conf"

# Backup if /etc/resolv.conf was modified after system birth
system_birth=$(stat -c %W /)
resolvconf_modified=$(stat -c %Y /etc/resolv.conf)

# Run a backup if resolv.conf isn't a symlink and was modified after install
if [[ -s /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]] && [[ $resolvconf_modified > $system_birth ]]; then
  # Backup the destination file (with timestamp) to avoid clobbering (Ex: resolv.conf.bak.1753817951)
  backup_file="/etc/resolv.conf.bak.$(date +%s)"

  # Create backup
  sudo cp -f /etc/resolv.conf "$backup_file" 2>/dev/null

  # Inform users
  echo -e "\e[31mReplaced /etc/resolv.conf with symlink to systemd-resolved. \nSaved backup as ${backup_file}.\e[0m"
  echo -e "\e[31mSee https://wiki.archlinux.org/title/Systemd-resolved.\e[0m"
fi

# Write the symlink
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Add slurp in case it hadn't been picked up from an old migration
omarchy-pkg-add slurp gpu-screen-recorder
echo "Add the new Flexoki Light theme"

if [[ ! -L ~/.config/omarchy/themes/flexoki-light ]]; then
  ln -nfs ~/.local/share/omarchy/themes/flexoki-light ~/.config/omarchy/themes/
fi
echo "Add a default keyring for gnome-keyring that unlocks on login"

if [ -f "$HOME/.local/share/keyrings/Default_keyring.keyring" ] || [ -f "$HOME/.local/share/keyrings/default" ]; then
    if gum confirm "Do you want to replace existing keyring with one that's auto-unlocked on login?"; then
        bash "$OMARCHY_PATH/install/login/default-keyring.sh"
    fi
else
    bash "$OMARCHY_PATH/install/login/default-keyring.sh"
fi
echo "Add Chromium crash workaround flag for Hyprland to existing configs"

# Add flag to chromium-flags.conf if it exists and doesn't already have it
if [[ -f ~/.config/chromium-flags.conf ]]; then
  if ! grep -qF -- "--disable-features=WaylandWpColorManagerV1" ~/.config/chromium-flags.conf; then
    sed -i '$a # Chromium crash workaround for Wayland color management on Hyprland - see https://github.com/hyprwm/Hyprland/issues/11957\n--disable-features=WaylandWpColorManagerV1' ~/.config/chromium-flags.conf
  fi
fi

# Add flag to brave-flags.conf if it exists and doesn't already have it
if [[ -f ~/.config/brave-flags.conf ]]; then
  if ! grep -qF -- "--disable-features=WaylandWpColorManagerV1" ~/.config/brave-flags.conf; then
    sed -i '$a # Chromium crash workaround for Wayland color management on Hyprland - see https://github.com/hyprwm/Hyprland/issues/11957\n--disable-features=WaylandWpColorManagerV1' ~/.config/brave-flags.conf
  fi
fi

echo "Add nfs support by default to Nautilus"
omarchy-pkg-add gvfs-nfs

echo "Install expac and inxi for omarchy-debug"
omarchy-pkg-add expac inxi
echo "Set nvim as default via xdg-mime"

echo "Setting up xdg-terminal-exec for gtk-launch terminal support"
# Solve for hardcoded glib terminals
# https://github.com/basecamp/omarchy/issues/1852

# Remove old symlink if it exists -- if someone ran the previous migration early
if [ -L /usr/local/bin/xdg-terminal-exec ]; then
  sudo rm /usr/local/bin/xdg-terminal-exec
fi

echo "Add usage package to provide tab completion for mise"

echo "Install exfatprogs to support exfat in format-drive"

omarchy-pkg-add exfatprogs
echo "Configure XDPH config for screensharing to remember token selection"

cp $OMARCHY_PATH/config/hypr/xdph.conf ~/.config/hypr/
systemctl --user restart xdg-desktop-portal-hyprland
echo "Make Alacritty compatible with X-TerminalArgs"

echo "Ensure lockout limit is reset on reboot"

sudo sed -i '/pam_faillock\.so preauth/d' /etc/pam.d/sddm-autologin
sudo sed -i '/auth.*pam_permit\.so/a auth        required    pam_faillock.so authsucc' /etc/pam.d/sddm-autologin

echo "Add custom share portal picker"
omarchy-pkg-add hyprland-preview-share-picker

mkdir -p ~/.config/hyprland-preview-share-picker
omarchy-refresh-config hyprland-preview-share-picker/config.yaml

if ! grep -q "custom_picker_binary" ~/.config/hypr/xdph.conf; then
  sed -i '/screencopy {/a\    custom_picker_binary = hyprland-preview-share-picker' ~/.config/hypr/xdph.conf
fi

sleep 1
killall -e xdg-desktop-portal-hyprland
killall -e xdg-desktop-portal-wlr
killall xdg-desktop-portal
/usr/lib/xdg-desktop-portal-hyprland &
sleep 2
/usr/lib/xdg-desktop-portal &

echo "Increase faillock attempts to 10"
sudo sed -i 's/^# *deny = .*/deny = 10/' /etc/security/faillock.conf
echo "Add missing dotnet 9.0 for Pinta"

omarchy-pkg-add dotnet-runtime-9.0
echo "Change to openai-codex instead of openai-codex-bin"

echo "Migrate legacy NVIDIA GPUs to nvidia-580xx driver (if needed)"

# Only migrate GTX 9xx or 10xx (Pascal/Maxwell)
NVIDIA="$(lspci | grep -i 'nvidia')"
if echo "$NVIDIA" | grep -qE "GTX 9|GTX 10"; then
  if ! pacman -Qq | grep -qE '^linux(-[a-z0-9]+)?-headers$'; then
    echo "Error: no linux headers package installed (required for DKMS drivers). Please install the appropriate headers and re-run this migration."
    exit 1
  fi

  # Piping yes to override existing packages
  yes | sudo pacman -S nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils

  # Verify packages were installed
  if ! pacman -Qq nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils &>/dev/null; then
    echo "Error: NVIDIA 580xx driver packages failed to install"
    exit 1
  fi
fi
echo "Update terminal scrolltouchpad setting to Hyprland 0.53 style"

if grep -q "scrolltouchpad" ~/.config/hypr/input.conf; then
  sed -Ei 's/^windowrule = scrolltouchpad ([^,]+), class:\(([^)]+)\)$/windowrule = match:class (\2), scroll_touchpad \1/' ~/.config/hypr/input.conf
  sed -Ei 's/^windowrule = scrolltouchpad ([^,]+), class:([^ ]+)$/windowrule = match:class \2, scroll_touchpad \1/' ~/.config/hypr/input.conf
  sed -Ei 's/^windowrule = scrolltouchpad ([^,]+), tag:terminal$/windowrule = match:class (Alacritty|kitty), scroll_touchpad 1.5\nwindowrule = match:class com.mitchellh.ghostty, scroll_touchpad 0.2/' ~/.config/hypr/input.conf
fi

# Ensure we restart to pair new Hyprland settings with new version
omarchy-state set reboot-required

omarchy-pkg-add yq

# Move user-added backgrounds from Omarchy theme folders to user config
OMARCHY_DIR="$HOME/.local/share/omarchy"
USER_BACKGROUNDS_DIR="$HOME/.config/omarchy/backgrounds"

if [[ -d "$OMARCHY_DIR/themes" ]]; then
  cd "$OMARCHY_DIR"

  # Get list of git-tracked background files (relative to omarchy dir)
  mapfile -t TRACKED_BACKGROUNDS < <(git ls-files --cached 'themes/*/backgrounds/*' 2>/dev/null)

  # Find all background files and check if they're untracked (user-added)
  for theme_dir in themes/*/; do
    theme_name=$(basename "$theme_dir")
    backgrounds_dir="themes/$theme_name/backgrounds"

    [[ -d "$backgrounds_dir" ]] || continue

    for bg_file in "$backgrounds_dir"/*; do
      [[ -f "$bg_file" ]] || continue

      # Check if this file is tracked by git
      is_tracked=false
      for tracked in "${TRACKED_BACKGROUNDS[@]}"; do
        if [[ "$tracked" == "$bg_file" ]]; then
          is_tracked=true
          break
        fi
      done

      if [[ "$is_tracked" == "false" ]]; then
        # This is a user-added background, move it to user config
        user_theme_bg_dir="$USER_BACKGROUNDS_DIR/$theme_name"
        mkdir -p "$user_theme_bg_dir"
        mv "$bg_file" "$user_theme_bg_dir/"
        echo "Moved user background: $bg_file -> $user_theme_bg_dir/"
      fi
    done
  done
fi

THEMES_DIR="$HOME/.config/omarchy/themes"
CURRENT_THEME_LINK="$HOME/.config/omarchy/current/theme"

# Get current theme name before removing anything
CURRENT_THEME_NAME=""
if [[ -L $CURRENT_THEME_LINK ]]; then
  CURRENT_THEME_NAME=$(basename "$(readlink "$CURRENT_THEME_LINK")")
elif [[ -d $CURRENT_THEME_LINK ]]; then
  CURRENT_THEME_NAME=$(basename "$CURRENT_THEME_LINK")
elif [[ -f "$HOME/.config/omarchy/current/theme.name" ]]; then
  CURRENT_THEME_NAME=$(cat "$HOME/.config/omarchy/current/theme.name")
fi

# Remove all symlinks from ~/.config/omarchy/themes
find "$THEMES_DIR" -mindepth 1 -maxdepth 1 -type l -delete

# Re-apply the current theme with the new system
if [[ -n $CURRENT_THEME_NAME ]]; then
  omarchy-theme-set "$CURRENT_THEME_NAME"
else
  # Backup to ensure a theme is set if we can't deduce the name
  omarchy-theme-set "Tokyo Night"
fi
echo "Use correct idle-timer sensitive timeouts for lock screen"

sed -i 's/timeout = 300/timeout = 151/' ~/.config/hypr/hypridle.conf
echo "Add Omarchy AI skill for assistance tailoring the system"

source $OMARCHY_PATH/install/config/omarchy-ai-skill.sh
echo "Add opencode with system themeing"

omarchy-pkg-add opencode

# Add config using omarchy theme by default
if [[ ! -f ~/.config/opencode/opencode.json ]]; then
  mkdir -p ~/.config/opencode
  cp $OMARCHY_PATH/config/opencode/opencode.json ~/.config/opencode/opencode.json
fi
echo "Add Voxtype to Waybar"

STYLE_FILE=~/.config/waybar/style.css
CONFIG_FILE=~/.config/waybar/config.jsonc

# Add voxtype CSS if not present
if ! grep -q "#custom-voxtype" "$STYLE_FILE"; then
  sed -i 's/margin-left: 8\.75px;/margin-left: 5px;/' "$STYLE_FILE"
  sed -i '/#custom-screenrecording-indicator {/,/}/ s/font-size: 10px;/font-size: 10px;\n  padding-bottom: 1px;/' "$STYLE_FILE"
  cat >> "$STYLE_FILE" << 'EOF'

#custom-voxtype {
  min-width: 12px;
  margin: 0 0 0 7.5px;
}

#custom-voxtype.recording {
  color: #a55555;
}
EOF
fi

# Add voxtype to modules-center if not present
if ! grep -q "custom/voxtype" "$CONFIG_FILE"; then
  # Add to modules-center array
  sed -i 's/"custom\/screenrecording-indicator"]/"custom\/voxtype", "custom\/screenrecording-indicator"]/' "$CONFIG_FILE"

  # Add voxtype config block before tray config
  sed -i '/"tray": {/i\  "custom/voxtype": {\n    "exec": "omarchy-voxtype-status",\n    "return-type": "json",\n    "format": "{icon}",\n    "format-icons": {\n      "idle": "",\n      "recording": "󰍬",\n      "transcribing": "󰔟"\n    },\n    "tooltip": true,\n    "on-click-right": "omarchy-voxtype-config",\n    "on-click": "omarchy-voxtype-model"\n  },' "$CONFIG_FILE"
fi

omarchy-restart-waybar
echo "Add icons for additional audio profiles in Waybar"

if ! grep -q '"headphone": ""' "$HOME/.config/waybar/config.jsonc"; then
  sed -i '
    /"pulseaudio": {/,/^[ ]*}/{
      /"format-icons": {/,/^[ ]*}/{
        /"default":/i\
\      "headphone": "",
      }
    }
  ' "$HOME/.config/waybar/config.jsonc"

  omarchy-restart-waybar
fi
echo "Ensure Chromium is able to start on first run after ISO 3.3.0 install"

rm -rf ~/.config/chromium/SingletonLock

# Re-enable screensaver/sleep after updates
hyprctl dispatch tagwindow -- -noidle &> /dev/null || true

set_docker_config() {
  echo "Ensure Docker config is set"
  if [[ ! -f /etc/docker/daemon.json ]]; then
    sudo mkdir -p /etc/docker
    echo '{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "5" }, "dns": ["172.17.0.1"], "bip": "172.17.0.1/16" }' | sudo tee /etc/docker/daemon.json

  sudo systemctl restart systemd-resolved
  sudo systemctl restart docker
}
set_default_apps() {
  DEFAULT_VIDEO_PLAYER="mpv.desktop"
  DEFAULT_BROWSER="zen.desktop"
  DEFAULT_TEXT_EDITOR="nvim.desktop"

  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/mp4
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-msvideo
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-matroska
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-flv
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-ms-wmv
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/mpeg
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/ogg
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/webm
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/quicktime
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/3gpp
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/3gpp2
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-ms-asf
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-ogm+ogg
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" video/x-theora+ogg
  xdg-mime default "$DEFAULT_VIDEO_PLAYER" application/ogg
  xdg-mime default "$DEFAULT_BROWSER" x-scheme-handler/http
  xdg-mime default "$DEFAULT_BROWSER" x-scheme-handler/https
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/plain
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/english
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-makefile
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-c++hdr
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-c++src
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-chdr
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-csrc
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-java
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-moc
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-pascal
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-tcl
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-tex
  xdg-mime default "$DEFAULT_TEXT_EDITOR" application/x-shellscript
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-c
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/x-c++
  xdg-mime default "$DEFAULT_TEXT_EDITOR" application/xml
  xdg-mime default "$DEFAULT_TEXT_EDITOR" text/xml
}
