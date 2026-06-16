# Maintainer playbook

For the ISRM Product Security members who administer
`thomsonreuters/tuf-root-signing`. A maintainer bootstraps the repository, opens
and drives signing events to merge, manages the keyholder set, and rotates keys
and targets. Signing itself is done by keyholders with their YubiKeys (see
[SIGNER.md](SIGNER.md)).

Adapted from the upstream `tuf-on-ci` maintainer documentation.

## What you need

- Everything in [SIGNER.md](SIGNER.md) — you are also a keyholder.
- `tuf-on-ci` (the maintainer CLI, including `tuf-on-ci-delegate`).
- AWS access to read the online KMS key during delegation: assume
  `a209440-PowerUser2` for `tuf-on-ci-delegate` steps that touch `snapshot` /
  `timestamp`.

## Role policy

Every delegation below uses this fixed policy. Do not deviate without an
architecture review.

| Role      | Signers                | Threshold | Expiry | Signing period |
|-----------|------------------------|-----------|--------|----------------|
| root      | 5 keyholders (YubiKey) | 3         | 365 d  | 60 d           |
| targets   | 5 keyholders (YubiKey) | 3         | 365 d  | 60 d           |
| snapshot  | Online (KMS)           | 1         | 10 d   | 7 d            |
| timestamp | Online (KMS)           | 1         | 7 d    | 6 d            |

The KMS key is the single `alias/tuf-online-signing` — both online roles authorize
the same keyid.

## Drive a signing event to merge

Every change is a `sign/**` branch and its pull request. To open one, push the
branch with the proposed change. `signing-event.yml` opens the PR and tracks
signature collection. Then:

1. Keyholders sign until **3 of 5** signatures are collected (PR status comment
   reports progress).
2. The PR also requires review by **2** members of `@thomsonreuters/tuf-keyholders`
   — review is distinct from signing.
3. Merge once the threshold is met and checks pass. The merge fires
   `online-sign.yml` (KMS-signs snapshot + timestamp) and `publish.yml` (deploys
   to S3 + CloudFront).

You cannot weaken these gates: branch protection and CODEOWNERS are pinned by a
GitHub **organization ruleset** owned by PLE DevEx, not by repository settings.

## Bootstrap the repository

A one-time ceremony, the only operation requiring all keyholders in real time.

1. Acquire the trust material with the `tooling/` scripts. A second member reviews
   the output (validity windows, leaf-first chain order, Rekor `logId`).
2. Initialize the four roles per the policy table:

   ```bash
   tuf-on-ci-delegate sign/bootstrap root
   tuf-on-ci-delegate sign/bootstrap targets
   tuf-on-ci-delegate sign/bootstrap snapshot timestamp
   ```

3. Push `sign/bootstrap`. Each keyholder signs until both `root` and `targets`
   reach 3 signatures. Merge. The online-sign and publish workflows produce
   version 1.

## Add or remove a signer

A keyholder change is a **root rotation** — `root` authorizes the keyholder set
and threshold.

```bash
tuf-on-ci-delegate sign/keyholder-change-<date> root targets
```

`tuf-on-ci` enforces chain-of-continuity: the new `root.json` must be signed by 3
of the **old** keys *and* 3 of the **new** keys. A departing keyholder signs as
their last act. A joining keyholder accepts the invitation and signs with the key
their YubiKey mints. Practice in a staging repository first. After merge, rebuild
the `secpipe` installer with the new `N.root.json` embedded.

## Rotate the online key

Yearly, or immediately on suspected compromise. AWS KMS does not auto-rotate
asymmetric keys, so rotation means a new key.

1. Provision a new KMS key via Terraform (`tr/prodsec_tuf_infra`).
2. PLE Landing Zone grants the new key ARN to the `a209440-tuf-online-signer` role
   (alongside the old).
3. Open a root-signed event that replaces the public key for both online roles:

   ```bash
   tuf-on-ci-delegate sign/rotate-online-<year> snapshot timestamp
   ```

Because this edits `root.json`, the **root keyholders** sign it (3 of 5). After
one snapshot lifetime (10 d), request PLE Landing Zone to schedule deletion of the
old key.

## Update a target (Sigstore anchor rotation)

The most frequent change: a Fulcio CA, Rekor key, CT log key, or TSA chain
rotation. Regenerate `trusted_root.json` / `signing_config.v0.2.json` with the
`tooling/` scripts, stage them under `targets/`, and open a `sign/**` event signed
by the targets keyholders.

The invariant across all anchor rotations: **never remove old entries**. Append
the new entry with a future `validFor.start`, and add `validFor.end` to the old
entry only at cutover. Removing a retired entry makes every historical signature
verified against it unverifiable.

## Compromise response

A single YubiKey is sub-threshold — recover by a root rotation that drops the key.
The online KMS key recovers by rotation within hours. A threshold of keyholders is
catastrophic and requires out-of-band rebuild. Disable the relevant IAM role or
lock `main` to contain, then follow the matching rotation procedure above.
