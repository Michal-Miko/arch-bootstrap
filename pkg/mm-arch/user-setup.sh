#!/bin/bash

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

mkdir -p ~/.config
rm -fr ~/.config/fish
git clone git@github.com:Michal-Miko/fish-config.git ~/.config/fish
ln -sf fish/starship.toml ~/.config/starship.toml

rm -fr ~/.config/nvim
git clone git@github.com:Michal-Miko/astro-nvim-config.git ~/.config/nvim
