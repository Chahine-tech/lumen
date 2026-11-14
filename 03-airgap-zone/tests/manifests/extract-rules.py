#!/usr/bin/env python3
"""Write the groups of every PrometheusRule found in the rendered manifests
to <out>/<name>.yml, the format promtool reads.

Usage: extract-rules.py <out dir> <yaml file>...
"""
import os
import sys

import yaml

yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_yaml_str)

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
count = 0
for f in sys.argv[2:]:
    for doc in yaml.safe_load_all(open(f)):
        if doc and doc.get("kind") == "PrometheusRule":
            name = f"{doc['metadata'].get('namespace', 'default')}-{doc['metadata']['name']}"
            with open(os.path.join(out, name + ".yml"), "w") as fh:
                yaml.safe_dump({"groups": doc["spec"]["groups"]}, fh)
            count += 1
print(f"{count} PrometheusRules extracted to {out}", file=sys.stderr)
