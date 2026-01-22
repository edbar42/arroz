#!/bin/bash

set -e

# Common place variables for the script
BASE_PACKAGES="$HOME/.local/share/chezmoi/base_packages.list"
BLOAT_LIST="$HOME/.local/share/chezmoi/bloat.list"
FIRST_RUN_FILE="$HOME/.config/arroz/first_run"
FIRST_RUN=$([ ! -f "$FIRST_RUN_FILE" ] && echo true || echo false)
GH_USER="edbar42" # GIthub user for dotfiles repo
LOCAL_USER="edbar"

if $FIRST_RUN; then
  echo "It seems this is the first time you are running this script."
  echo "We will configure everything from a base omarchy install."
fi

if $FIRST_RUN || [ "$1" == "backup" ]; then
  echo "Backing up legacy config..."
  mkdir ~/.backup
  mv ~/.config ~/.backup/config
  mv ~/.local/share/applications/ ~/.backup/applications
fi

if $FIRST_RUN || [ "$1" == "locale" ]; then
  set -e
  echo "Generating locale: pt_BR.UTF-8..."
  sudo sed -i 's/^#pt_BR.UTF-8/pt_BR.UTF-8/' /etc/locale.gen
  sudo locale-gen
  echo "Locale successfully generated"
fi

if $FIRST_RUN || [ "$1" == "dotfiles" ]; then
  echo "Fetching dotfiles from remote and applying to system..."
  sudo pacman -Sy chezmoi
  chezmoi init --apply $GH_USER
  chezmoi cd
  # change remote to ssh after cloning
  git remote set-url origin git@github.com:edbar42/dotfiles.git

  echo "Adding keyd remapping..."
  sudo pacman -Sy keyd
  bash ~/.bin/remap
fi

if $FIRST_RUN || [ "$1" == "shell" ]; then
  echo "Switching shells to zsh..."
  sudo pacman -Sy zsh
  chsh -s /bin/zsh $LOCAL_USER
  chsh /bin/zsh $LOCAL_USER
fi

if $FIRST_RUN || [ "$1" == "install" ]; then
  echo "Installing base packages..."
  yay -S --needed $(cat $BASE_PACKAGES)
fi

if [ "$1" == "debloat" ]; then
  if [[ ! -f $BLOAT_LIST ]]; then
    echo "Error: bloat.list not found at $BLOAT_LIST"
    exit 1
  fi
  
  echo "Checking for bloat packages..."
  installed_bloat=()
  
  while IFS= read -r pkg; do
    if yay -Qq "$pkg" &>/dev/null; then
      installed_bloat+=("$pkg")
    fi
  done < "$BLOAT_LIST"
  
  if [[ ${#installed_bloat[@]} -eq 0 ]]; then
    echo "No bloat found."
  else
    echo "Removing bloat packages: ${installed_bloat[*]}"
    yay -Rns "${installed_bloat[@]}"
    echo "Debloat complete!"
  fi
fi

# Create first run file if it does not exist
# if [[ ! -f $FIRST_RUN ]]; then
#   mkdir -p ~/.config/arroz
#   touch $FIRST_RUN
# fi
