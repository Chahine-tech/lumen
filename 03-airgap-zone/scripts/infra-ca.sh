#!/bin/bash
# Infrastructure CA (issue #5): an offline root and an intermediate that
# cert-manager uses to sign the certificates of components that must not
# depend on Vault, Vault's own listener first.
#
#   infra-ca.sh init  [DIR]   create the root and the intermediate in DIR
#   infra-ca.sh apply [DIR]   store the intermediate in the cluster: Secret
#                             infra-ca in cert-manager (ClusterIssuer infra-ca,
#                             manifests/vault/05-infra-ca.yaml)
#   infra-ca.sh server DIR NAME SAN...
#                             a server certificate for a host outside the
#                             cluster (DIR/NAME.crt with the chain, NAME.key),
#                             1 year; SAN: IP:<address> or DNS:<name>
#
# DIR (default ~/.lumen-pki) holds the root key: keep it off the cluster,
# offline once init is done. apply only sends the intermediate key and
# the two certificates. docs/runbooks/vault-tls.md
#
# KUBECTL overrides the kubectl command (default: multipass exec node-1 --
# kubectl).
set -euo pipefail

cmd=${1:-}
dir=${2:-$HOME/.lumen-pki}
KUBECTL=${KUBECTL:-multipass exec node-1 -- kubectl}

init() {
  if [ -e "$dir/root.key" ]; then
    echo "$dir/root.key exists: not overwritten" >&2
    exit 1
  fi
  mkdir -p "$dir"
  chmod 700 "$dir"
  umask 077

  # Root: 10 years, signs intermediates only
  openssl ecparam -name prime256v1 -genkey -noout -out "$dir/root.key"
  openssl req -x509 -new -key "$dir/root.key" -sha256 -days 3650 \
    -subj "/O=lumen/CN=lumen root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$dir/root.crt"

  # Intermediate: 5 years, cannot sign further CAs
  openssl ecparam -name prime256v1 -genkey -noout -out "$dir/infra.key"
  openssl req -new -key "$dir/infra.key" -subj "/O=lumen/CN=lumen infra CA" -out "$dir/infra.csr"
  printf '%s\n' \
    "basicConstraints=critical,CA:TRUE,pathlen:0" \
    "keyUsage=critical,keyCertSign,cRLSign" \
    "subjectKeyIdentifier=hash" \
    "authorityKeyIdentifier=keyid:always" > "$dir/infra.ext"
  openssl x509 -req -in "$dir/infra.csr" -CA "$dir/root.crt" -CAkey "$dir/root.key" \
    -CAcreateserial -sha256 -days 1825 -extfile "$dir/infra.ext" -out "$dir/infra.crt"
  rm -f "$dir/infra.csr" "$dir/infra.ext"

  openssl verify -CAfile "$dir/root.crt" "$dir/infra.crt"
  echo "Created in $dir: root.key root.crt infra.key infra.crt"
  echo "Next: $0 apply $dir, then move root.key offline"
}

apply() {
  for f in infra.key infra.crt root.crt; do
    [ -f "$dir/$f" ] || { echo "$dir/$f missing: run $0 init first" >&2; exit 1; }
  done
  openssl verify -CAfile "$dir/root.crt" "$dir/infra.crt" > /dev/null
  # tls.crt carries the chain up to the root, ca.crt the root: what
  # cert-manager copies into every certificate it signs with this issuer.
  # Built here and sent on stdin: the key is never on a command line
  b64() { base64 < "$1" | tr -d '\n'; }
  # shellcheck disable=SC2086
  $KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: infra-ca
  namespace: cert-manager
type: kubernetes.io/tls
data:
  tls.crt: $(cat "$dir/infra.crt" "$dir/root.crt" | base64 | tr -d '\n')
  tls.key: $(b64 "$dir/infra.key")
  ca.crt: $(b64 "$dir/root.crt")
EOF
  echo "Secret cert-manager/infra-ca applied"
}

server() {
  local name=$1
  shift
  [ -n "$name" ] && [ $# -gt 0 ] || { echo "usage: $0 server DIR NAME SAN..." >&2; exit 2; }
  [ -f "$dir/infra.key" ] || { echo "$dir/infra.key missing: run $0 init first" >&2; exit 1; }
  umask 077
  local sans
  sans=$(IFS=,; echo "$*")
  openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$name.key"
  openssl req -new -key "$dir/$name.key" -subj "/O=lumen/CN=$name" -out "$dir/$name.csr"
  printf '%s\n' \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=$sans" > "$dir/$name.ext"
  openssl x509 -req -in "$dir/$name.csr" -CA "$dir/infra.crt" -CAkey "$dir/infra.key" \
    -CAcreateserial -sha256 -days 365 -extfile "$dir/$name.ext" -out "$dir/$name.leaf"
  cat "$dir/$name.leaf" "$dir/infra.crt" > "$dir/$name.crt"
  rm -f "$dir/$name.csr" "$dir/$name.ext" "$dir/$name.leaf"
  openssl verify -CAfile "$dir/root.crt" -untrusted "$dir/infra.crt" "$dir/$name.crt"
  echo "Created $dir/$name.crt (with the intermediate) and $dir/$name.key"
}

case "$cmd" in
  init) init ;;
  apply) apply ;;
  server) shift 2; server "$@" ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
