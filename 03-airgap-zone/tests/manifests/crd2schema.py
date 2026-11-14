#!/usr/bin/env python3
"""Write a JSON schema for every CRD version found in the given YAML files,
in the layout kubeconform reads with
  -schema-location '<dir>/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

Strict, like openapi2jsonschema in kubeconform: an object with properties
rejects unknown fields, unless the CRD says
x-kubernetes-preserve-unknown-fields. int-or-string fields accept both.

Usage: crd2schema.py <output dir> <yaml file>...
"""
import json
import os
import sys

import yaml

# PyYAML resolves a bare "=" (an enum value in prometheus-operator CRDs) to
# the YAML 1.1 "value" tag, which it cannot construct: keep it a string
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_yaml_str)


def strict(node):
    if isinstance(node, dict):
        if node.get("x-kubernetes-int-or-string"):
            node.pop("type", None)
            node["oneOf"] = [{"type": "string"}, {"type": "integer"}]
        if "properties" in node and "additionalProperties" not in node \
                and not node.get("x-kubernetes-preserve-unknown-fields"):
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def main(out, files):
    count = 0
    for f in files:
        for doc in yaml.safe_load_all(open(f)):
            if not doc or doc.get("kind") != "CustomResourceDefinition":
                continue
            spec = doc["spec"]
            group, kind = spec["group"], spec["names"]["kind"].lower()
            for v in spec.get("versions", []):
                schema = (v.get("schema") or {}).get("openAPIV3Schema")
                if not schema:
                    continue
                schema = strict(schema)
                # apiVersion and kind are set by every manifest
                schema.setdefault("properties", {}).update(
                    {"apiVersion": {"type": "string"}, "kind": {"type": "string"},
                     "metadata": {"type": "object"}})
                os.makedirs(os.path.join(out, group), exist_ok=True)
                with open(os.path.join(out, group, f"{kind}_{v['name']}.json"), "w") as fh:
                    json.dump(schema, fh)
                count += 1
    print(f"{count} CRD schemas written to {out}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
