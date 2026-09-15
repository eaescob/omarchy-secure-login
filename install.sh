#!/bin/bash

# Installs the omarchy-secure-login commands to /usr/local/bin.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if (( EUID == 0 )); then
  install -m755 bin/omarchy-secure-login /usr/local/bin/
  install -m755 bin/omarchy-secure-login-keyring-migrate /usr/local/bin/
else
  sudo install -m755 bin/omarchy-secure-login /usr/local/bin/
  sudo install -m755 bin/omarchy-secure-login-keyring-migrate /usr/local/bin/
fi

echo "Installed. Run: omarchy-secure-login"
