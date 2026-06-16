# Signer playbook

For the five ISRM Product Security keyholders in `@thomsonreuters/tuf-keyholders`.
You hold a YubiKey that authorizes the `root` and `targets` roles under a
**3-of-5** threshold. Your job is to sign signing events when your signature is
needed. The online roles (`snapshot`, `timestamp`) are KMS-backed and fully
automated — you never touch them.

Adapted from the upstream `tuf-on-ci` signer documentation.

## What you need

- A YubiKey 5 FIPS-series token (one per keyholder, never leaves your possession).
- `tuf-on-ci-sign` installed in a local virtualenv.
- The PKCS#11 module for your platform (`libykcs11`).
- A clone of `thomsonreuters/tuf-root-signing`.

```bash
# ykman + the libykcs11 PKCS#11 module
brew install yubico-piv-tool ykman

python3 -m venv venv && . venv/bin/activate
pip install tuf-on-ci-sign
```

## One-time YubiKey setup

The token ships **FIPS capable** and becomes **FIPS approved** only after the PIN,
PUK, and management key have all been changed from their defaults. Change them in
this order — `--protect` is rejected until the applet is FIPS approved, so do not
use it:

```bash
ykman piv access change-pin                                           # Default: 123456. New PIN is 8 digits.
ykman piv access change-puk                                           # Default: 12345678. New PUK is 8 digits.
ykman piv access change-management-key --generate --algorithm AES256  # Default: 010203040506070801020304050607080102030405060708.
ykman piv info                                                        # Confirm "FIPS approved: True".
```

`--generate` prints a new random management key — copy it to a vault, out of band,
before doing anything else.

Generate a slot-9c signing keypair if required:
```bash
yubico-piv-tool -k -a generate -s 9c -A ECCP256 --touch-policy=always --pin-policy=once -o pub.pem
```

## Configure `.tuf-on-ci-sign.ini`

`tuf-on-ci-sign` reads this file from the git toplevel of your clone. It is
gitignored, so it stays local and per-keyholder.

```ini
[settings]
# Linux: pykcs11lib = /usr/lib/x86_64-linux-gnu/libykcs11.so
pykcs11lib  = /opt/homebrew/lib/libykcs11.dylib
user-name   = <your-github-username>
push-remote = origin
pull-remote = origin
```

`user-name`, `push-remote`, and `pull-remote` are required. `pykcs11lib` is
auto-probed if omitted. Verify the toolchain with a no-op event:

```bash
tuf-on-ci-sign sign/just-testing   # "Nothing to do" means it works
```

## Accept an invitation

When a maintainer adds you (initial ceremony, or a root rotation that brings you
in), they open a signing event that invites you. Run it against that event:

```bash
tuf-on-ci-sign sign/<event-name>
```

The tool generates your keypair on PIV slot 9c — the private key never leaves the
secure element — uploads the public key into the proposed `root.json`, prompts for
a YubiKey touch, and pushes your signature. Confirm the displayed identity is
yours before touching.

## Sign a signing event

Signing events are `sign/**` branches with a pull request. The PR's status comment
lists who has signed and whether the threshold is met. When your signature is
needed:

```bash
git fetch origin
tuf-on-ci-sign sign/<event-name>
```

Read the change the tool prints before you touch the key:

- For a **targets** event, confirm the `trusted_root.json` /
  `signing_config.v0.2.json` diff matches the intended rotation.\
  Ensure that old entries are **retained**, not removed.
- For a **root** event, confirm the keyholder set and threshold are what you
  expect.

Touch the YubiKey to sign. The tool pushes your signature and the
`signing-event` workflow updates the PR comment. You do not need every
keyholder — three signatures satisfy the threshold.

## If your YubiKey is lost or compromised

Declare it immediately to the keyholder team. A single token is sub-threshold and
cannot forge metadata on its own. Recovery is a root rotation that removes your
old public key and enrolls a replacement.
