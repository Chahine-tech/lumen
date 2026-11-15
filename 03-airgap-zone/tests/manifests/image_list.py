#!/usr/bin/env python3
"""Compare the images of the rendered manifests with images.yaml.

Fails when a manifest references an image absent from the list, or when a
list entry is referenced by no manifest. Floating tags (`latest`, no tag,
or an entry marked `floating: true`) are reported without failing.

Read: the `image` and `imageName` fields, and container args that pass an
image to an operator (--name=<registry>/...). Skipped: CRDs, and Helm test
hooks, which ArgoCD does not create.

Usage: image_list.py <images.yaml> <rendered dir>
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
    data = yaml.safe_load(open(path))
    registry = data["registry"]
    exact, any_tag = {}, {}
    for e in data["images"]:
        mirror = e.get("mirror") or e["source"]
        if mirror.startswith(registry + "/"):
            mirror = mirror[len(registry) + 1:]
        if "build" in e and ":" not in mirror:
            any_tag[mirror] = e
        else:
            exact[mirror_path(mirror)] = e
    return registry, exact, any_tag


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
    registry, exact, any_tag = load_list(list_file)
    used, missing, floating = set(), [], []
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
                    if tag == "latest" or exact[(name, tag)].get("floating"):
                        floating.append(f"{ref}  ({where})")
                else:
                    missing.append(f"{ref}  ({where})")
    unused = [":".join(k) for k in exact if k not in used] + [k for k in any_tag if k not in used]

    for title, items in (("floating tags (not enforced yet)", floating),
                         ("referenced by a manifest, absent from " + list_file, missing),
                         ("listed in " + list_file + ", referenced by no manifest", unused)):
        if items:
            print(f"{title}:")
            for i in sorted(set(items)):
                print(f"  {i}")
    print(f"{len(used)} listed images in use, {len(missing)} missing, {len(unused)} unused")
    return 1 if missing or unused else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
