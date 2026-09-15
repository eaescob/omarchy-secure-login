#!/bin/bash

# Validates omarchy-secure-login end-to-end on a disposable QEMU VM driven by
# the Omarchy repo's test/vm harness, and captures the screenshots/ evidence
# set with the default Omarchy theme.
#
# The run: boot a clone of the golden base, seed test secrets, run the utility
# from the desktop (typing the VM password into the real gcr dialog over QMP),
# verify every file it touched, reboot to capture the changed SDDM experience,
# log in with the password, prove the keyring unlocked silently with that
# login, screenshot status, then uninstall and verify the restoration.
#
# Leaves the VM running on failure with instructions; destroys it on success.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/vm
BASE=${OMARCHY_SECURE_LOGIN_BASE:-lab}
VM=${OMARCHY_SECURE_LOGIN_VM:-securelogin}
SHOTS=$REPO/screenshots

GREEN=$'\e[32m'
RED=$'\e[31m'
BOLD=$'\e[1m'
RESET=$'\e[0m'
ok() { echo -e "${GREEN}✓${RESET} $*"; }
fail() { echo -e "${RED}✗${RESET} $*"; }
step() { echo -e "${BOLD}::$RESET $*"; }

VM_TOOL=${OMARCHY_SECURE_LOGIN_VM_TOOL:-}
if [[ -z $VM_TOOL ]]; then
  for candidate in "$HOME/dev/omarchy/test/vm" "$REPO/../omarchy/test/vm"; do
    [[ -x $candidate ]] && VM_TOOL=$candidate && break
  done
fi
[[ -n $VM_TOOL && -x $VM_TOOL ]] || { echo "omarchy test/vm harness not found (clone omarchy alongside this repo)" >&2; exit 1; }
[[ -f $STATE/bases/$BASE/base.json ]] || { echo "golden base '$BASE' missing — run: cd ../omarchy && ./test/vm install $BASE" >&2; exit 1; }

VM_USER=$(jq -r .user "$STATE/bases/$BASE/base.json")
VM_PASSWORD=$(jq -r .password "$STATE/bases/$BASE/base.json")

vm_ssh() { "$VM_TOOL" ssh "$VM" "$@"; }
vm_sc() { "$VM_TOOL" sc "$VM" "$1" >/dev/null 2>&1 && echo "$STATE/vms/$VM/screenshots/$1.png"; }
vm_ocr() { tesseract "$1" stdout 2>/dev/null; }
vm_type() { "$VM_TOOL" type "$VM" "$1"; }
vm_key() { "$VM_TOOL" key "$VM" "$@"; }

# Poll until a screenshot's OCR matches the pattern, printing the last shot path.
wait_text() {
  local pattern=$1 timeout=${2:-120} shot text
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    shot=$(vm_sc "poll")
    text=$(vm_ocr "$shot")
    if grep -qiE "$pattern" <<<"$text"; then
      echo "$shot"
      return 0
    fi
    sleep 5
  done
  return 1
}

# Wait for the screen to hold still across three samples (the SDDM greeter and
# finished terminals are static; animated screens never settle).
wait_static() {
  local timeout=${1:-180}
  local deadline=$(( $(date +%s) + timeout )) a b c
  while (( $(date +%s) < deadline )); do
    a=$(vm_sc "static-a")
    sleep 6
    b=$(vm_sc "static-b")
    sleep 6
    c=$(vm_sc "static-c")
    if [[ $(md5sum "$a" | cut -d' ' -f1) == $(md5sum "$b" | cut -d' ' -f1) &&
          $(md5sum "$b" | cut -d' ' -f1) == $(md5sum "$c" | cut -d' ' -f1) ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

snap_into() {
  local shot=$1 dest=$2
  [[ -f $shot ]] || { fail "screenshot missing: $shot"; return 1; }
  cp "$shot" "$SHOTS/$dest"
  ok "captured $SHOTS/$dest"
}

cleanup_on_fail() {
  echo
  fail "validation stopped — VM '$VM' left running for inspection"
  echo "  screen: $VM_TOOL sc $VM"
  echo "  shell:  $VM_TOOL ssh $VM"
  echo "  delete:  $VM_TOOL destroy $VM"
  exit 1
}

[[ -d $SHOTS ]] || mkdir -p "$SHOTS"

step "preparing a fresh VM from base '$BASE'"
"$VM_TOOL" destroy "$VM" >/dev/null 2>&1 || true
"$VM_TOOL" up "$VM" --base "$BASE" || cleanup_on_fail
ok "VM up (user $VM_USER, password $VM_PASSWORD)"

# The default idle behavior blanks the display after a few minutes, which would
# black out every screenshot and strand any open dialog. Pin the session awake.
vm_ssh "omarchy-toggle-idle stay-awake" >/dev/null 2>&1 || true

step "pushing the repo and seeding test secrets"
"$VM_TOOL" scp "$VM" "$REPO" '~/' >/dev/null || cleanup_on_fail
cat >/tmp/seed-secrets.py <<'PY'
import gi
gi.require_version("Secret", "1")
from gi.repository import Secret

service = Secret.Service.get_sync(Secret.ServiceFlags.OPEN_SESSION | Secret.ServiceFlags.LOAD_COLLECTIONS, None)
collection = Secret.Collection.for_alias_sync(service, "default", Secret.CollectionFlags.LOAD_ITEMS, None)

# A fresh client sees even a passwordless keyring as locked; unlock explicitly
# (no prompt fires when there is no password to ask for).
service.unlock_sync([collection], None)

def store(label, attrs, value):
    Secret.Item.create_sync(collection, None, attrs, label,
                            Secret.Value.new(value, -1, "text/plain"),
                            Secret.ItemCreateFlags.REPLACE, None)

store("Password for 'tester' on 'gh:github.com'",
      {"user": "tester", "server": "github.com"}, "gh-validation-token")
store("Chrome Safe Storage", {"application": "chrome"}, "chrome-validation-key")
store("Omarchy Secure Login Test Token", {"purpose": "validation"}, "validation-token-123")
print("seeded 3 secrets")
PY
"$VM_TOOL" scp "$VM" /tmp/seed-secrets.py /tmp/ >/dev/null || cleanup_on_fail
vm_ssh "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 /tmp/seed-secrets.py" || cleanup_on_fail

step "running the utility in the desktop terminal"
sleep 10
vm_key meta_l ret
sleep 4
vm_type "~/omarchy-secure-login/bin/omarchy-secure-login --yes"
vm_key ret
sleep 6

# sudo asks for the password in the terminal first
shot=$(wait_text "sudo.*password|password for" 60) || { fail "sudo prompt never appeared"; cleanup_on_fail; }
vm_type "$VM_PASSWORD"
vm_key ret

# The gcr dialog pops once the migration starts: "An application wants to
# create a new keyring". It has two fields (password + confirm), so the
# deterministic sequence is type, TAB, type, ENTER.
shot=$(wait_text "create a new keyring|choose password for new keyring" 120) || { fail "keyring dialog never appeared"; cleanup_on_fail; }
sleep 3
dialog_shot=$(vm_sc "02-keyring-password-dialog")
snap_into "$dialog_shot" "02-keyring-password-dialog.png" || cleanup_on_fail
vm_type "$VM_PASSWORD"
vm_key tab
sleep 1
vm_type "$VM_PASSWORD"
vm_key ret

# Wait for the utility process itself to exit — the desktop never goes
# pixel-static while the welcome toast and clock are alive, so watching the
# process is the only trustworthy completion signal. The bracket in the pgrep
# pattern keeps the probe from matching its own ssh command line.
step "waiting for the utility to finish"
deadline=$(( $(date +%s) + 300 ))
while (( $(date +%s) < deadline )); do
  if ! vm_ssh "pgrep -f 'omarchy-secure[-]login --yes' >/dev/null 2>&1" 2>/dev/null; then
    break
  fi
  sleep 5
done
sleep 3
vm_ssh "[[ \$(cat ~/.local/share/keyrings/default 2>/dev/null) == login ]] && test ! -f ~/.local/share/keyrings/Default_keyring.keyring" || { fail "utility exited without completing the migration"; cleanup_on_fail; }
terminal_shot=$(vm_sc "01-setup-terminal")
snap_into "$terminal_shot" "01-setup-terminal.png" || cleanup_on_fail

step "verifying every piece the utility touched"
vm_ssh "test ! -f /etc/sddm.conf.d/autologin.conf" || { fail "autologin.conf still present"; cleanup_on_fail; }
ok "autologin disabled"
vm_ssh "grep -q '^-auth.*pam_gnome_keyring' /etc/pam.d/sddm && grep -q '^-password.*pam_gnome_keyring' /etc/pam.d/sddm" || { fail "PAM keyring lines missing"; cleanup_on_fail; }
ok "PAM keyring lines present"
# gnome-keyring 50 writes password-protected keyrings in the binary "GnomeKeyring"
# format; the legacy text format stays passwordless.
vm_ssh "head -c 12 ~/.local/share/keyrings/login.keyring | grep -q GnomeKeyring && [[ \$(cat ~/.local/share/keyrings/default) == login ]]" || { fail "keyring not bound"; cleanup_on_fail; }
ok "login keyring encrypted (binary format) and default"
count=$(vm_ssh "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 - <<'PY'
import gi
gi.require_version('Secret', '1')
from gi.repository import Secret
s = Secret.Service.get_sync(Secret.ServiceFlags.LOAD_COLLECTIONS, None)
for c in s.get_collections():
    try:
        if c.get_label() == 'login':
            print(len(c.get_items()))
            break
    except Exception:
        pass
else:
    print(0)
PY")
[[ $count -ge 3 ]] || { fail "expected 3 migrated secrets, found $count"; cleanup_on_fail; }
ok "$count secrets migrated"
vm_ssh "test ! -f ~/.local/share/keyrings/Default_keyring.keyring" || { fail "old keyring left behind"; cleanup_on_fail; }
ok "old passwordless keyring removed"
plaintext=$(vm_ssh "grep -c 'gh-validation-token' ~/.local/share/keyrings/login.keyring || true")
[[ $plaintext == 0 ]] || { fail "seed secret appears in PLAINTEXT in the keyring file"; cleanup_on_fail; }
ok "no plaintext secrets in the keyring file (encrypted at rest)"

step "rebooting to capture the changed login experience"
vm_ssh "echo $VM_PASSWORD | sudo -S reboot" || true
sleep 20

# LUKS prompt comes first (the base is an encrypted install)
shot=$(wait_text "password is required" 180) || { fail "LUKS prompt never appeared after reboot"; cleanup_on_fail; }
vm_type "$VM_PASSWORD"
vm_key ret

# Wait for sshd to return instead of watching pixels: this desktop stack never
# goes pixel-stable, but sshd comes back with the machine regardless of what
# the greeter is showing. One SYN per probe keeps the VM's firewall budget safe.
step "waiting for the machine to come back up"
deadline=$(( $(date +%s) + 600 ))
ssh_port=$(jq -r .ssh_port "$STATE/vms/$VM/vm.json")
until timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$ssh_port" 2>/dev/null; do
  (( $(date +%s) > deadline )) && { fail "machine never came back"; cleanup_on_fail; }
  sleep 5
done
vm_ssh true 2>/dev/null || { sleep 10; vm_ssh true 2>/dev/null; } || { fail "ssh did not return after reboot"; cleanup_on_fail; }

# The real proof the experience changed: the greeter holds seat0 and NO user
# session exists — autologin would have logged tester straight in.
sessions=$(vm_ssh "loginctl --no-legend list-sessions")
if ! grep -q "greeter" <<<"$sessions" || grep -qE "tester.*seat0" <<<"$sessions"; then
  fail "expected the greeter holding seat0 with no user session — got: $sessions"
  cleanup_on_fail
fi
ok "greeter holds the seat, no autologin session (loginctl proves it)"

sleep 10
sddm_shot=$(vm_sc "03-sddm-login")
snap_into "$sddm_shot" "03-sddm-login.png" || cleanup_on_fail
ok "login screen captured (password required — no autologin)"

step "logging in with the password"
vm_type "$VM_PASSWORD"
vm_key ret
shot=$(wait_text "update system|keybindings|super" 300) || { fail "desktop never appeared after login"; cleanup_on_fail; }
sleep 15
desktop_shot=$(vm_sc "04-desktop-after-login")
snap_into "$desktop_shot" "04-desktop-after-login.png" || cleanup_on_fail

step "proving the keyring unlocked silently with the password login"
vm_ssh "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 - <<'PY'
import gi
gi.require_version('Secret', '1')
from gi.repository import Secret
service = Secret.Service.get_sync(Secret.ServiceFlags.OPEN_SESSION | Secret.ServiceFlags.LOAD_COLLECTIONS, None)
collection = Secret.Collection.for_alias_sync(service, 'default', Secret.CollectionFlags.LOAD_ITEMS, None)
assert collection.get_label() == 'login', 'wrong collection'
locked = collection.get_locked()
assert not locked, 'keyring is LOCKED after password login — PAM unlock failed'
item = Secret.Item.create_sync(collection, None, {'purpose': 'unlock-check'}, 'Unlock Check',
                               Secret.Value.new('probe', -1, 'text/plain'), Secret.ItemCreateFlags.REPLACE, None)
value = item.retrieve_secret_sync(None).get_text()
assert value == 'probe'
print('keyring unlocked after password login, secrets readable')
PY" || { fail "keyring was not unlocked by the password login"; cleanup_on_fail; }
ok "keyring unlocked silently by the PAM password login"

step "capturing status"
vm_key meta_l ret
sleep 4
vm_type "~/omarchy-secure-login/bin/omarchy-secure-login status"
vm_key ret
sleep 4
status_shot=$(vm_sc "05-status")
snap_into "$status_shot" "05-status.png" || cleanup_on_fail

step "uninstalling and verifying the restoration"
vm_ssh "echo $VM_PASSWORD | sudo -S -k ~/omarchy-secure-login/bin/omarchy-secure-login uninstall --yes" || { fail "uninstall failed"; cleanup_on_fail; }
vm_ssh "test -f /etc/sddm.conf.d/autologin.conf" || { fail "autologin not restored"; cleanup_on_fail; }
vm_ssh "! grep -q 'pam_fprintd' /etc/pam.d/sddm && ! grep -q '^-auth.*pam_gnome_keyring' /etc/pam.d/sddm" || { fail "PAM lines not removed"; cleanup_on_fail; }
ok "uninstall restored autologin and the stock PAM stack"

"$VM_TOOL" destroy "$VM" >/dev/null || true
rm -f /tmp/seed-secrets.py

echo
ok "validation passed — screenshots updated in $SHOTS"
ls -la "$SHOTS"