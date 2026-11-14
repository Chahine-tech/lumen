#!/usr/bin/env python3
"""Render the manifests that reach the cluster, one file per source.

- Every ArgoCD Application in manifests/argocd: a Helm chart is rendered
  with the Application's releaseName, namespace and valueFiles (helm
  template, CRDs included); a plain directory is copied (recursively when
  directory.recurse is set), as ArgoCD reads it.
- The directories applied by scripts instead of ArgoCD (EXTRA_DIRS).

Usage: render.py <repo root> <output dir>
HELM: the helm command, default "helm" (the Makefile runs Helm 3 in a
container; ArgoCD embeds Helm 3).
"""
import os
import shlex
import subprocess
import sys

import yaml

# Applied with kubectl by the install scripts, not by ArgoCD
EXTRA_DIRS = [
    "03-airgap-zone/manifests/argocd",
    "03-airgap-zone/manifests/cnpg",
    "03-airgap-zone/manifests/cnpg/restore-drill",
    "03-airgap-zone/manifests/gitea",
    "03-airgap-zone/manifests/gitea-runner",
    "03-airgap-zone/manifests/vault",
    "03-airgap-zone/manifests/metallb",
    "03-airgap-zone/manifests/chaos-experiments",
]


def yaml_files(path, recurse):
    for root, dirs, files in os.walk(path):
        for f in sorted(files):
            if f.endswith((".yaml", ".yml")):
                yield os.path.join(root, f)
        if not recurse:
            break


def copy_dir(src, out_file, recurse):
    with open(out_file, "w") as out:
        for f in yaml_files(src, recurse):
            out.write(f"# Source: {f}\n")
            out.write(open(f).read().rstrip("\n") + "\n---\n")


def main(root, out):
    os.makedirs(out, exist_ok=True)
    os.chdir(root)
    apps = []
    for f in sorted(os.listdir("03-airgap-zone/manifests/argocd")):
        if not f.endswith((".yaml", ".yml")):
            continue
        for d in yaml.safe_load_all(open(os.path.join("03-airgap-zone/manifests/argocd", f))):
            if d and d.get("kind") == "Application":
                apps.append(d)
    seen = set()
    for app in apps:
        name = app["metadata"]["name"]
        if name in seen:
            continue
        seen.add(name)
        src = app["spec"]["source"]
        path = src["path"]
        ns = app["spec"]["destination"].get("namespace", "default")
        target = os.path.join(out, f"app-{name}.yaml")
        if os.path.exists(os.path.join(path, "Chart.yaml")):
            helm = src.get("helm", {})
            cmd = shlex.split(os.environ.get("HELM", "helm")) + ["template", helm.get("releaseName", name), path,
                   "--namespace", ns, "--include-crds"]
            for v in helm.get("valueFiles", []):
                cmd += ["-f", os.path.join(path, v)]
            if "values" in helm:
                inline = os.path.join(out, f".values-{name}.yaml")
                open(inline, "w").write(helm["values"])
                cmd += ["-f", inline]
            print(f"helm  {name}: {path}", file=sys.stderr)
            with open(target, "w") as fh:
                subprocess.run(cmd, check=True, stdout=fh)
        else:
            recurse = src.get("directory", {}).get("recurse", False)
            print(f"dir   {name}: {path}{' (recursive)' if recurse else ''}", file=sys.stderr)
            copy_dir(path, target, recurse)
    for d in EXTRA_DIRS:
        print(f"extra {d}", file=sys.stderr)
        copy_dir(d, os.path.join(out, "extra-" + d.split("manifests/")[1].replace("/", "-") + ".yaml"), False)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
