#!/usr/bin/env python3
"""Compare the images of the rendered manifests with mirror.yaml.

Fails when a manifest references an image absent from the list, when a
list entry is referenced by no manifest and names no `used_by` file, or
when a `used_by` file does not exist, or when a reference carries another
digest than the one of mirror.yaml. Floating tags (`latest`, no tag, or an
entry marked `floating: true`) and references without a digest are
reported without failing.

Read: the `image` and `imageName` fields, and container args that pass an
image to an operator (--name=<registry>/...). Skipped: CRDs, and Helm test
hooks, which ArgoCD does not create.

Usage: image_list.py <mirror.yaml> <rendered dir>
"""
import glob
import os
import re
import sys

import yaml

TEST_HOOKS = {"test", "test-success", "test-failure"}
# Image names an operator receives but does not run here
NOT_RUN = {
    "thanos/thanos",  # prometheus-operator default for a Thanos sidecar, none configured
    "jetstack/cert-manager-acmesolver",  # ACME HTTP-01 solver, the only issuer is Vault
}


def mirror_path(ref):
    """The path and tag of ref in the airgap registry."""
    ref = ref.split("@", 1)[0]
    first, _, rest = ref.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        host, ref = first, rest
    else:
        host = "docker.io"
    if host == "docker.io" and ref.startswith("library/"):
        ref = ref[len("library/"):]
    name, sep, tag = ref.rpartition(":")
    if not sep or "/" in tag:
        name, tag = ref, "latest"
    return name, tag


def load_list(path):
    """The registry, the images by (path, tag), the build images by path
    (any tag), and the used_by files that do not exist."""
    data = yaml.safe_load(open(path))
    registry = data["registry"]
    exact, any_tag, no_file = {}, {}, []
    for e in data["images"] + data.get("charts", []) + data.get("files", []):
        if e.get("used_by") and not os.path.exists(e["used_by"]):
            no_file.append(e["used_by"])
    for e in data["images"]:
        if "archive" in e:  # not in the registry
            continue
        mirror = e.get("mirror") or e["source"]
        if mirror.startswith(registry + "/"):
            mirror = mirror[len(registry) + 1:]
        if "build" in e and ":" not in mirror:
            any_tag[mirror] = e
        else:
            exact[mirror_path(mirror)] = e
    return registry, exact, any_tag, no_file


def refs(obj, key=None):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from refs(v, k)
    elif isinstance(obj, list):
        for v in obj:
            yield from refs(v, key)
    elif isinstance(obj, str):
        if key in ("image", "imageName"):
            yield obj
        elif key in ("args", "command"):
            m = re.match(r"--[\w-]+=(\S+/\S+:\S+)$", obj)
            if m and "://" not in obj:
                yield m.group(1)


def main(list_file, rendered):
    registry, exact, any_tag, no_file = load_list(list_file)
    used, missing, floating, no_digest, bad_digest = set(), [], [], [], []
    for f in sorted(glob.glob(os.path.join(rendered, "*.yaml"))):
        for doc in yaml.load_all(open(f), Loader=yaml.BaseLoader):
            if not isinstance(doc, dict) or doc.get("kind") == "CustomResourceDefinition":
                continue
            meta = doc.get("metadata") or {}
            hook = (meta.get("annotations") or {}).get("helm.sh/hook", "")
            if TEST_HOOKS & set(hook.split(",")):
                continue
            where = f"{os.path.basename(f)} {doc.get('kind')}/{meta.get('name')}"
            for ref in refs(doc):
                r = ref[len(registry) + 1:] if ref.startswith(registry + "/") else ref
                name, tag = mirror_path(r)
                if name in NOT_RUN:
                    continue
                if name in any_tag:
                    used.add(name)
                elif (name, tag) in exact:
                    used.add((name, tag))
                    e = exact[(name, tag)]
                    if tag == "latest" or e.get("floating"):
                        floating.append(f"{ref}  ({where})")
                    _, at, digest = ref.partition("@")
                    if not at:
                        no_digest.append(f"{ref}  ({where})")
                    elif digest != e.get("digest"):
                        bad_digest.append(f"{ref}  ({where}), mirror.yaml: {e.get('digest')}")
                else:
                    missing.append(f"{ref}  ({where})")
    unused = [":".join(k) for k, e in exact.items() if k not in used and "used_by" not in e]
    unused += [k for k, e in any_tag.items() if k not in used and "used_by" not in e]

    for title, items in (("floating tags (not enforced yet)", floating),
                         ("without a digest (not enforced yet)", no_digest),
                         ("digest differs from " + list_file, bad_digest),
                         ("referenced by a manifest, absent from " + list_file, missing),
                         ("listed in " + list_file + ", referenced by no manifest, no used_by", unused),
                         ("used_by files that do not exist", no_file)):
        if items:
            print(f"{title}:")
            for i in sorted(set(items)):
                print(f"  {i}")
    print(f"{len(used)} listed images in use, {len(missing)} missing, {len(unused)} unused, "
          f"{len(set(no_digest))} references without a digest")
    return 1 if missing or unused or no_file or bad_digest else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
