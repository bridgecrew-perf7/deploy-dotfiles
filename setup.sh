#!/bin/bash

set -e

PROGDIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd )

echo "Copying global config"
CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/hre-utils/deploy-dotfiles"
mkdir -p "$CONFDIR"
cp -n "${PROGDIR}"/doc/share/global_config.cfg "${CONFDIR}/config.cfg"

echo "Copying ./doc/share/*"
DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/hre-utils/deploy-dotfiles"
mkdir -p "${DATADIR}"/{files,dist,backup,share}
cp -n "${PROGDIR}"/doc/share/* "${DATADIR}/share/"

git -C "${DATADIR}" init

echo "Moving script to /usr/local/bin"
sudo install -D --mode=755 "${PROGDIR}/deploy-dotfiles.sh" "/usr/local/bin"

# Uninstall:
# rm -rf "${CONFDIR}"
# rm -rf "${DATADIR}"
# rm -f "/usr/local/bin/deploy-dotfiles.sh"
