# Air-gap image transfer

Use this path when the customer's environment cannot pull from `ghcr.io` or
proxy through JFrog. The workflow is:

1. **On a connected host** — pull every image from
   [`../manifest.txt`](../manifest.txt) and save each to a `.tar` file.
2. **Transfer the bundle directory** to the target by the customer's approved
   method (SFTP, removable media, approved share, etc.).
3. **On the target host** — load the bundle into the local Docker daemon.

Bundles are **generated on demand, never committed**, and never written inside
this repository — both scripts require an explicit directory. They are derived
entirely from `manifest.txt`, so the manifest is the only thing worth
version-controlling. Build a bundle when you need one, ship it, and let it go
stale on disk; regenerating is cheaper than keeping a copy honest.

Multi-gigabyte bundles do not belong under `/etc`, so pick a path with room —
`$AUTONOX_HOME/var/tars` below is only a convention.

## On the connected host

```bash
bash images/airgap/pull-and-save.sh "$AUTONOX_HOME/var/tars"              # default platform: linux/amd64
bash images/airgap/pull-and-save.sh "$AUTONOX_HOME/var/tars" linux/arm64  # to override
```

The bundle directory becomes self-describing: one `.tar` per image
(named after the image reference, slashes and colons replaced with
underscores), plus a **`bundle.lock`** recording, for each manifest entry, the
resolved image ID, the registry digest, and the tar it lives in.

`pull-and-save.sh` always pulls before deciding anything. Every entry in
`manifest.txt` is pinned to an immutable tag, but a tag is still a name a
publisher can repoint, so the presence of a tar says nothing about whether it
holds what the manifest currently resolves to. If the pulled image ID still
matches `bundle.lock` the save is skipped (`keep`); if it has moved, the tar is
rebuilt (`stale ... re-saving`).

Tars left over from an older manifest are reported at the end of the run. They
are inert — `load.sh` only reads the lock — but they cost transfer bytes, so
remove them before shipping.

## Transfer

This is intentionally out of scope. The script writes regular files —
transport them however the customer's policy allows. Transfer `bundle.lock`
along with the tars; without it the target host cannot verify what it loaded.

## On the target host

```bash
bash images/airgap/load.sh "$AUTONOX_HOME/var/tars"
```

`load.sh` loads exactly the images `bundle.lock` lists and verifies each
against its recorded image ID. It exits non-zero if a tar is missing, fails to
produce its expected reference, or resolves to a different image than the
bundle claims — so a stale or truncated tar fails loudly instead of installing
a build nobody asked for. Tars in the directory that the lock does not mention
are reported and skipped.

A bundle built before `bundle.lock` existed still loads, but unverified and
with a warning. Regenerate it with `pull-and-save.sh` to get verification.

## Updating the manifest

Edit [`../manifest.txt`](../manifest.txt) to track the AutoNox release the
customer is being upgraded to, then regenerate the bundle. Keep the third-party
pins in sync with:

- `postgres/compose/compose.yaml`
- `postgres/kustomize/components/images/kustomization.yaml`
- `metabase/compose/compose.yaml`
- `metabase/kustomize/components/images/kustomization.yaml`
