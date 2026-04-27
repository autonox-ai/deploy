# Air-gap image transfer

Use this path when the customer's environment cannot pull from `ghcr.io` or
proxy through JFrog. The workflow is:

1. **On a connected host** — pull every image from
   [`../manifest.txt`](../manifest.txt) and save each to a `.tar` file.
2. **Transfer the tar directory** to the target by the customer's approved
   method (SFTP, removable media, approved share, etc.).
3. **On the target host** — load the tars into the local Docker daemon.

## On the connected host

```bash
bash images/airgap/pull-and-save.sh ./tars                # default platform: linux/amd64
bash images/airgap/pull-and-save.sh ./tars linux/arm64    # to override
```

The `./tars/` directory will contain one `.tar` per image, named after the
image reference (slashes and colons replaced with underscores).

## Transfer

This is intentionally out of scope. The script writes regular files —
transport them however the customer's policy allows.

## On the target host

```bash
bash images/airgap/load.sh ./tars
docker images
```

## Verify

After loading, sanity-check that every image in the manifest is present:

```bash
grep -v -e '^\s*#' -e '^\s*$' images/manifest.txt | while read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 \
    && echo "ok    $img" \
    || echo "MISS  $img"
done
```

## Updating the manifest

Edit [`../manifest.txt`](../manifest.txt) to track the AutoNox release the
customer is being upgraded to. Keep the third-party pins in sync with:

- `postgres/compose/compose.yaml`
- `postgres/kustomize/components/images/kustomization.yaml`
- `metabase/compose/compose.yaml`
- `metabase/kustomize/components/images/kustomization.yaml`
