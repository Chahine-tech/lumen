# Mirroring into the airgap zone

`mirror.yaml` lists everything the airgap zone needs from the internet
(issue #31):

- **images**: the images of the airgap registry (`192.168.2.2:5000`), for
  `linux/arm64`, each with its digest for that platform. Those that no
  rendered manifest references name the file that uses them (`used_by`):
  install scripts, CI jobs, Ansible.
- **charts**: the Helm charts that are not vendored in
  `03-airgap-zone/manifests` (Traefik, MetalLB), pinned by sha256.
- **files**: release files, pinned by sha256 (the CloudNativePG operator
  manifests of each upgrade step, the Barman Cloud plugin manifest).

`scripts/check/image-list.sh` (CI) fails when a rendered manifest references
an image that is not in the list, when a listed image is used nowhere, when
a `used_by` file does not exist, or when a reference to a pulled image does
not carry the digest of the list (`tag@sha256:...`, or `image@sha256:...`
where a chart drops the tag). Images built here (`build`) are exempt.

## Pull, push, verify

```bash
# Connected zone (internet): images, charts, files into 01-connected-zone/artifacts
make mirror-pull                 # or: ./scripts/mirror.py pull [--only TEXT]

# Carry 01-connected-zone/artifacts to a host that reaches the registry, then
make mirror-push                 # REGISTRY=host:port to override 192.168.2.2:5000
make mirror-verify               # every pulled image is in the registry, same digest
```

- **pull** fails when a tag no longer points to the digest of `mirror.yaml`
  (the image was rebuilt upstream): check the new image, then update the
  digest. It saves each image as an OCI layout under `artifacts/images/`. The
  layout keeps the upstream digest (a docker or crane tarball does not: the
  manifest is rebuilt, measured on 16 November 2026). The digests go to
  `artifacts/mirror.lock`. Charts and files are checked against their
  sha256; what is already there and matches is skipped. An image with
  `archive` (Garage) is saved as a docker archive for `docker load` instead.
  An image with `dockerfile` (the Gitea CI job image) is built for the
  platform at each pull and saved as a docker archive, which push sends to
  the registry; its digest in the lock is the one the registry gets
  (measured with `crane digest --tarball` against a local registry). With
  the build cache, an unchanged Dockerfile gives the same digest (measured;
  without the cache it differs).
  The crane image, pulled by its digest, is saved under its tag as
  `artifacts/tools/crane.tar`: `docker load` drops a reference by digest
  (measured with the classic image store on 16 November 2026).
- **push** loads crane from `tools/crane.tar` when it is not there, pushes
  each layout to the registry (plain HTTP) and fails when the digest in the
  registry differs from `mirror.lock`.
- **verify** compares the registry with `mirror.lock`, without pushing.

crane and Helm run in containers (`CRANE_IMAGE`, `HELM_IMAGE` in
`scripts/check/images.sh`, pinned by digest), with the host network.

## Updates (Renovate)

`renovate.json5`, run by the Renovate GitHub App on the GitHub repository.
Nothing opens a pull request until it is ticked in the dependency
dashboard issue.

- Covered: Go modules, the GitHub Actions, the Dockerfile builder, the
  compose files, `scripts/check/images.sh`, the `docker run` lines of the
  GitHub workflows and the Makefile, and the images marked
  `renovate: true` in `mirror.yaml` with their references in the airgap
  manifests and `.gitea/workflows`.
- One branch per image and major version, whatever the file: a Redis
  update changes `mirror.yaml`, the manifests, the Gitea CI and the check
  image together. Each reference keeps its kind of digest: Renovate reads
  the architecture of the current digest, so the airgap ones stay
  linux/arm64 and the others stay the index.
- Left out: images set by a chart or a vendored manifest (they move with
  it), PostgreSQL (moves with the CNPG cluster), kyverno-cli (the deployed
  version), Helm 4 (ArgoCD embeds Helm 3). `.gitea/workflows` uses no
  action: the checkout is a git step.
- A reference to the airgap registry is looked up at its source through
  `overridePackageName`; one without a rule there is not updated.

The image list check runs on every Renovate pull request: a branch that
changes `mirror.yaml` without the manifests, or the reverse, fails it.
After merging, `mirror.py pull` and `push` carry the new image to the
registry before ArgoCD deploys it.

Measured with Renovate 44.244.2 in lookup mode on 16 November 2026: which
files and references it finds, the branch each update goes to, and that
the proposed digests are the linux/arm64 one (airgap) or the index
(others), checked against crane for golang 1.27.4 and redis 8.10.3. Not
measured: the edits it makes in a real pull request (local mode does not
write), and the GitHub Actions lookups (they need a token).

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
