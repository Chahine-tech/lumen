#!/usr/bin/env python3
"""Mirror what mirror.yaml lists into the airgap zone (issue #31).

  mirror.py pull    connected zone: images, charts and files into the
                    artifacts directory
  mirror.py push    transit: the images into the airgap registry
  mirror.py verify  the registry holds every image with the pulled digest

pull saves each image for the platform of mirror.yaml as an OCI layout,
which keeps its upstream digest, and records the digests in
<artifacts>/mirror.lock. An image with `archive` is saved as a docker
archive instead (docker load, not the registry). Charts and files are
checked against their sha256. What is already there, with the right
digest or sha256, is skipped. The crane image is saved too
(tools/crane.tar), for push and verify on a host without internet.

push and verify compare the registry with mirror.lock: same digest or
failure. The registry is plain HTTP.

Options: --artifacts DIR (default 01-connected-zone/artifacts),
--registry HOST:PORT (default: registry of mirror.yaml), --only TEXT
(pull: entries whose source, chart name or url contains TEXT; push and
verify: registry paths that contain it), --config FILE
(default mirror.yaml).
Images: CRANE_IMAGE and HELM_IMAGE of scripts/check/images.sh.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "03-airgap-zone/tests/manifests"))
from image_list import mirror_path  # noqa: E402


def pinned(name):
    out = subprocess.run(["bash", "-c", f'. scripts/check/images.sh && echo "${name}"'],
                         cwd=ROOT, check=True, capture_output=True, text=True)
    return out.stdout.strip()


CRANE = pinned("CRANE_IMAGE")
HELM = pinned("HELM_IMAGE")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, **kw)


def crane(art, *args):
    """crane in its container, artifacts directory at /a, host network."""
    out = run(["docker", "run", "--rm", "--network", "host", "-v", f"{art}:/a", CRANE, *args],
              capture_output=True)
    return out.stdout.strip()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def mirror_ref(e):
    name, tag = mirror_path(e.get("mirror") or e["source"])
    return f"{name}:{tag}"


def layout_dir(ref):
    return "images/" + ref.replace("/", "_").replace(":", "_")


def layout_digest(path):
    """The digest of the single image of an OCI layout, or None."""
    try:
        return json.load(open(os.path.join(path, "index.json")))["manifests"][0]["digest"]
    except (OSError, KeyError, IndexError, ValueError):
        return None


def selected(entries, only, *keys):
    return [e for e in entries if not only or any(only in str(e.get(k, "")) for k in keys)]


def pull(cfg, art, only):
    platform = cfg["platform"]
    lock_file = os.path.join(art, "mirror.lock")
    lock = dict(line.split() for line in open(lock_file)) if os.path.exists(lock_file) else {}
    os.makedirs(os.path.join(art, "images"), exist_ok=True)
    for e in selected([e for e in cfg["images"] if "source" in e], only, "source"):
        src = e["source"]
        if "digest" in e:
            got = crane(art, "digest", src)
            if got != e["digest"]:
                sys.exit(f"{src}: digest {got}, mirror.yaml says {e['digest']}")
        if "archive" in e:
            dest = os.path.join(art, e["archive"])
            if os.path.exists(dest):
                print(f"= {src} (archive there)")
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            crane(art, "pull", "--platform", platform, "--format", "tarball", src, "/a/" + e["archive"])
            print(f"+ {src} -> {e['archive']}")
            continue
        ref = mirror_ref(e)
        digest = crane(art, "digest", "--platform", platform, src)
        path = layout_dir(ref)
        if layout_digest(os.path.join(art, path)) == digest:
            print(f"= {src}")
        else:
            shutil.rmtree(os.path.join(art, path), ignore_errors=True)
            crane(art, "pull", "--platform", platform, "--format", "oci", src, "/a/" + path)
            got = layout_digest(os.path.join(art, path))
            if got != digest:
                sys.exit(f"{src}: pulled {got}, upstream {digest}")
            print(f"+ {src} {digest}")
        lock[ref] = digest
    with open(lock_file, "w") as f:
        for ref in sorted(lock):
            f.write(f"{ref} {lock[ref]}\n")

    for c in selected(cfg.get("charts", []), only, "name"):
        dest = os.path.join(art, c["dest"])
        if os.path.exists(dest) and sha256(dest) == c["sha256"]:
            print(f"= chart {c['name']} {c['version']}")
            continue
        with tempfile.TemporaryDirectory(dir=art) as tmp:
            run(["docker", "run", "--rm", "-v", f"{tmp}:/c", "-w", "/c", HELM, "pull", c["name"],
                 "--repo", c["repo"], "--version", str(c["version"])], capture_output=True)
            got = os.path.join(tmp, f"{c['name']}-{c['version']}.tgz")
            if sha256(got) != c["sha256"]:
                sys.exit(f"chart {c['name']} {c['version']}: sha256 {sha256(got)}, mirror.yaml says {c['sha256']}")
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.move(got, dest)
        print(f"+ chart {c['name']} {c['version']}")

    for f in selected(cfg.get("files", []), only, "url"):
        dest = os.path.join(art, f["dest"])
        if os.path.exists(dest) and sha256(dest) == f["sha256"]:
            print(f"= {f['dest']}")
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        run(["curl", "-sfL", "-o", dest + ".part", f["url"]])
        got = sha256(dest + ".part")
        if got != f["sha256"]:
            os.remove(dest + ".part")
            sys.exit(f"{f['url']}: sha256 {got}, mirror.yaml says {f['sha256']}")
        os.replace(dest + ".part", dest)
        print(f"+ {f['dest']}")

    tools = os.path.join(art, "tools")
    os.makedirs(tools, exist_ok=True)
    run(["docker", "pull", "-q", CRANE], capture_output=True)
    run(["docker", "save", "-o", os.path.join(tools, "crane.tar"), CRANE])


def ensure_crane(art):
    if subprocess.run(["docker", "image", "inspect", CRANE], capture_output=True).returncode != 0:
        run(["docker", "load", "-i", os.path.join(art, "tools", "crane.tar")], capture_output=True)


def read_lock(art, only):
    lock_file = os.path.join(art, "mirror.lock")
    if not os.path.exists(lock_file):
        sys.exit(f"no {lock_file}: run mirror.py pull first")
    return [line.split() for line in open(lock_file) if not only or only in line]


def push(art, registry, only):
    ensure_crane(art)
    for ref, digest in read_lock(art, only):
        crane(art, "push", "--insecure", "/a/" + layout_dir(ref), f"{registry}/{ref}")
        got = crane(art, "digest", "--insecure", f"{registry}/{ref}")
        if got != digest:
            sys.exit(f"{registry}/{ref}: {got} after the push, {digest} pulled")
        print(f"pushed {registry}/{ref} {digest}")


def verify(art, registry, only):
    ensure_crane(art)
    bad = 0
    for ref, digest in read_lock(art, only):
        try:
            got = crane(art, "digest", "--insecure", f"{registry}/{ref}")
        except subprocess.CalledProcessError:
            got = "missing"
        if got != digest:
            bad += 1
            print(f"{registry}/{ref}: {got}, {digest} pulled")
    print(f"{bad} image(s) missing or different" if bad else "every pulled image is in the registry")
    return 1 if bad else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("command", choices=["pull", "push", "verify"])
    p.add_argument("--artifacts", default=os.path.join(ROOT, "01-connected-zone/artifacts"))
    p.add_argument("--registry")
    p.add_argument("--only")
    p.add_argument("--config", default=os.path.join(ROOT, "mirror.yaml"))
    a = p.parse_args()
    cfg = yaml.safe_load(open(a.config))
    art = os.path.abspath(a.artifacts)
    os.makedirs(art, exist_ok=True)
    registry = a.registry or cfg["registry"]
    if a.command == "pull":
        pull(cfg, art, a.only)
    elif a.command == "push":
        push(art, registry, a.only)
    else:
        return verify(art, registry, a.only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
