#!/usr/bin/env python3
"""Mirror what mirror.yaml lists into the airgap zone (issue #31).

  mirror.py pull    connected zone: images, charts and files into the
                    artifacts directory
  mirror.py push    transit: the images into the airgap registry
  mirror.py verify  the registry holds every image with the pulled digest

pull checks that each tag still points to the digest of mirror.yaml, saves
the image for the platform of mirror.yaml as an OCI layout, which keeps
that digest, and records the digests in <artifacts>/mirror.lock. An image with `archive` is saved as a docker
archive instead (docker load, not the registry). An image with
`dockerfile` is built for that platform and saved as a docker archive,
which push sends to the registry. Charts and files are
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
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# mirror_path, shared with the image list check (not a package)
_spec = importlib.util.spec_from_file_location(
    "image_list", os.path.join(ROOT, "03-airgap-zone/tests/manifests/image_list.py"))
_image_list = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_image_list)
mirror_path = _image_list.mirror_path


def pinned(name):
    out = subprocess.run(["bash", "-c", f'. scripts/check/images.sh && echo "${name}"'],
                         cwd=ROOT, check=True, capture_output=True, text=True)
    return out.stdout.strip()


CRANE = pinned("CRANE_IMAGE")
# docker load drops a reference by digest (classic image store): crane is
# pulled by digest, then run and saved under its tag
CRANE_TAG = CRANE.split("@")[0]
HELM = pinned("HELM_IMAGE")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, **kw)


def crane(art, *args):
    """crane in its container, artifacts directory at /a, host network."""
    out = run(["docker", "run", "--rm", "--network", "host", "-v", f"{art}:/a", CRANE_TAG, *args],
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
        with open(os.path.join(path, "index.json")) as f:
            return json.load(f)["manifests"][0]["digest"]
    except (OSError, KeyError, IndexError, ValueError):
        return None


def selected(entries, only, *keys):
    return [e for e in entries if not only or any(only in str(e.get(k, "")) for k in keys)]


def pull(cfg, art, only):
    run(["docker", "pull", "-q", CRANE], capture_output=True)
    run(["docker", "tag", CRANE, CRANE_TAG])
    platform = cfg["platform"]
    lock_file = os.path.join(art, "mirror.lock")
    lock = {}
    if os.path.exists(lock_file):
        with open(lock_file) as f:
            lock = dict(line.split() for line in f)
    prev = dict(lock)
    os.makedirs(os.path.join(art, "images"), exist_ok=True)
    for e in selected([e for e in cfg["images"] if "source" in e], only, "source"):
        src = e["source"]
        digest = crane(art, "digest", "--platform", platform, src)
        if "digest" in e and digest != e["digest"]:
            sys.exit(f"{src}: {digest} upstream, mirror.yaml says {e['digest']}: the tag moved, "
                     "update the digest in mirror.yaml once the new image is checked")
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
    # Built at each pull: the tag does not change with the Dockerfile, and
    # with the build cache an unchanged Dockerfile gives the same digest
    for e in selected([e for e in cfg["images"] if "dockerfile" in e], only, "mirror"):
        ref = mirror_ref(e)
        tar = layout_dir(ref) + ".tar"
        df = os.path.join(ROOT, e["dockerfile"])
        run(["docker", "build", "-q", "--platform", platform, "-t", ref, "-f", df, os.path.dirname(df)],
            capture_output=True)
        run(["docker", "save", "-o", os.path.join(art, tar), ref])
        lock[ref] = crane(art, "digest", "--tarball", "/a/" + tar)
        print(f"{'=' if lock.get(ref) == prev.get(ref) else '+'} {ref} built from {e['dockerfile']}")
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
    run(["docker", "save", "-o", os.path.join(tools, "crane.tar"), CRANE_TAG])


def ensure_crane(art):
    if subprocess.run(["docker", "image", "inspect", CRANE_TAG], capture_output=True).returncode != 0:
        run(["docker", "load", "-i", os.path.join(art, "tools", "crane.tar")], capture_output=True)


def read_lock(art, only):
    lock_file = os.path.join(art, "mirror.lock")
    if not os.path.exists(lock_file):
        sys.exit(f"no {lock_file}: run mirror.py pull first")
    with open(lock_file) as f:
        return [line.split() for line in f if not only or only in line]


def push(art, registry, only):
    ensure_crane(art)
    for ref, digest in read_lock(art, only):
        path = layout_dir(ref)
        if os.path.exists(os.path.join(art, path + ".tar")):  # built here (dockerfile)
            path += ".tar"
        crane(art, "push", "--insecure", "/a/" + path, f"{registry}/{ref}")
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
    with open(a.config) as f:
        cfg = yaml.safe_load(f)
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
