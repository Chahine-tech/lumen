# Mirroring into the airgap zone

`mirror.yaml` lists everything the airgap zone needs from the internet
(issue #31):

- **images**: the images of the airgap registry (`192.168.2.2:5000`), for
  `linux/arm64`. Those that no rendered manifest references name the file
  that uses them (`used_by`): install scripts, CI jobs, Ansible.
- **charts**: the Helm charts that are not vendored in
  `03-airgap-zone/manifests` (Traefik, MetalLB), pinned by sha256.
- **files**: release files, pinned by sha256 (the CloudNativePG operator
  manifests of each upgrade step, the Barman Cloud plugin manifest).

`scripts/check/image-list.sh` (CI) fails when a rendered manifest references
an image that is not in the list, when a listed image is used nowhere, or
when a `used_by` file does not exist.

## Pull, push, verify

```bash
# Connected zone (internet): images, charts, files into 01-connected-zone/artifacts
make mirror-pull                 # or: ./scripts/mirror.py pull [--only TEXT]

# Carry 01-connected-zone/artifacts to a host that reaches the registry, then
make mirror-push                 # REGISTRY=host:port to override 192.168.2.2:5000
make mirror-verify               # every pulled image is in the registry, same digest
```

- **pull** saves each image as an OCI layout under `artifacts/images/`. The
  layout keeps the upstream digest (a docker or crane tarball does not: the
  manifest is rebuilt, measured on 16 November 2026). The digests go to
  `artifacts/mirror.lock`. Charts and files are checked against their
  sha256; what is already there and matches is skipped. An image with
  `archive` (Garage) is saved as a docker archive for `docker load` instead.
  The crane image is saved as `artifacts/tools/crane.tar`.
- **push** loads crane from `tools/crane.tar` when it is not there, pushes
  each layout to the registry (plain HTTP) and fails when the digest in the
  registry differs from `mirror.lock`.
- **verify** compares the registry with `mirror.lock`, without pushing.

crane and Helm run in containers (`CRANE_IMAGE`, `HELM_IMAGE` in
`scripts/check/images.sh`), with the host network.

## How it was tested

On 16 November 2026, against a local `registry:2` (`localhost:5001`), with a
subset of the list: Argo Rollouts, Traefik and its chart, MetalLB and its
chart, FRR, every CloudNativePG image and file, Garage, kubectl.

| Case | Result |
|---|---|
| verify before push | fails, every image missing |
| push, crane image absent | loaded from `tools/crane.tar`, every digest the upstream one |
| verify after push | passes |
| `mirror.lock` digest changed | verify and push fail on that image |
| registry tag overwritten with another image | verify fails; push restores it |
| chart, file or Garage digest wrong in mirror.yaml | pull fails, nothing written |
| pull again | everything skipped |

Not tested: a full pull of the list, and a push to the real registry. The
host that runs `push` must reach `192.168.2.2:5000` from a container
(`docker run --network host`); from Docker Desktop on macOS this was not
checked.
