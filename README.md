# omarchy-secure-login

Opt-in secure login for [Omarchy](https://omarchy.org): turn off autologin, bind the secret keyring to your login password, and use your fingerprint at the login screen if a reader is enrolled. Everything is reversible, and nothing changes until you run it.

## Why

Omarchy's defaults trade a boundary for zero prompts: on encrypted installs SDDM autologins forever ("the LUKS prompt is the auth boundary"), and the shipped keyring has **no password at all** — secrets (gh credentials, browser keys, 2FA seeds) sit unencrypted in `~/.local/share/keyrings/` and any process running as your user can read them, forever, without ever knowing a secret.

This utility restores both boundaries for people who want them:

1. **No more autologin** — SDDM asks for your password (or finger) every login.
2. **Keyring bound to the login password** — secrets are encrypted at rest, the keyring unlocks silently the moment you type your password at SDDM, and it locks between sessions.
3. **Fingerprint at the login screen and lock screen** — when `fprintd` has enrolled fingers.

## The tradeoff to know before enabling fingerprint

The keyring can only be unlocked with a *password*. When you log in with your finger, no password is typed, so:

| Login method | Keyring |
| --- | --- |
| Password at SDDM | Unlocks silently with the login — zero prompts |
| Fingerprint at SDDM | Stays locked; one "Unlock Login Keyring" dialog at the first app that needs a secret |

That dialog is inherent to how PAM and the keyring interact (stock GNOME behaves the same). Both paths are still better than the default: secrets are encrypted at rest either way.

## What changes, exactly

| Piece | Change |
| --- | --- |
| `/etc/sddm.conf.d/autologin.conf` | Backed up to `/var/lib/omarchy-secure-login/`, then removed |
| `/etc/pam.d/sddm` | The `pam_gnome_keyring` `auth`/`password` lines Omarchy's installer strips are restored (silent keyring unlock, automatic re-key on password change); with an enrolled reader, `auth sufficient pam_fprintd.so` is added ahead of them |
| Lock screen | `omarchy-apply-lock` is re-run so the lock screen gets its fingerprint PAM service |
| `~/.local/share/keyrings/` | A password-protected keyring named `login` is created (you type your login password into the standard gcr dialog — it never passes through this tool), every secret is copied out of the passwordless keyring, the default alias is repointed, and the old keyring is deleted **only after the copy is verified** |

`uninstall` restores autologin and the stock PAM stack. The keyring intentionally stays bound — secrets don't get un-encrypted by a downgrade of policy; see the README section on reverting manually.

## Install

```bash
git clone https://github.com/basecamp/omarchy-secure-login
cd omarchy-secure-login
./install.sh          # copies to /usr/local/bin
omarchy-secure-login  # interactive wizard
```

Or run straight from a checkout. `omarchy-secure-login status` reports every piece's current state without changing anything.

## Validation

Every change this tool makes is validated on a disposable QEMU VM before release, with the default Omarchy theme, using the harness in the Omarchy repo (`test/vm`):

```bash
cd ../omarchy && ./test/vm install lab   # once: golden encrypted Omarchy base
cd ../omarchy-secure-login && ./test/validate.sh
```

`validate.sh` boots a fresh VM from the base, seeds test secrets, runs the utility end-to-end (typing the VM's password into the real gcr dialog over QMP), verifies every file it touched, reboots to capture the changed login experience, logs in at the SDDM greeter, and proves the keyring unlocked silently with that password. The evidence set lands in `screenshots/`:

- `01-setup-terminal.png` — the wizard's summary after a successful run
- `02-keyring-password-dialog.png` — the one dialog you type your login password into
- `03-sddm-login.png` — the changed boot experience: the default Omarchy greeter asking for a password instead of autologging in
- `04-desktop-after-login.png` — the desktop after password login, keyring already unlocked
- `05-status.png` — `omarchy-secure-login status`

It finishes by running `uninstall` and verifying the restoration. Limitations that cannot be exercised in QEMU: real fingerprint readers (the config path is validated by stubbing enrollment; hardware behavior is on the reader), and Bluetooth-class attacks (unrelated to this tool).

## Manual revert of the keyring

If you ever want Omarchy's passwordless keyring back: export your secrets first (an app like Seahorse can show them), then `rm ~/.local/share/keyrings/login.keyring` — but be deliberate: this drops every stored secret. Chromium regenerates its own storage key; `gh auth login` re-creates its credentials.

## Relationship to Omarchy

Omarchy proper is moving toward binding the keyring to the login policy natively (see `plans/keyring-security.md` in the Omarchy repo). This utility exists for people who want the boundary today, and its code is structured so the useful pieces can be upstreamed.