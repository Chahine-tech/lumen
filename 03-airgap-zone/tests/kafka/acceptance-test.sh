#!/bin/bash
# Acceptance test of the Kafka cluster (issue #44):
#
#   1. layout: one broker per node, the topic replicated 3 times;
#   2. access: a client needs a certificate, a matching ACL and the label
#      kafka-client=true, and each control below has a positive twin;
#   3. a node is stopped during a write load (acks=all): every acknowledged
#      message is read back;
#   4. control: a second node stopped, writes are refused, since fewer than
#      min.insync.replicas brokers remain;
#   5. both nodes back: the replicas catch up with no action, writes resume
#      and nothing acknowledged is missing.
#
# Stops two nodes: run it on a test cluster. The client runs on the control
# plane node, the two others are stopped. NODE_RUNTIME is the command that
# stops and starts a node by its name: "k3d node" (default), or multipass.
# KUBECTL overrides the kubectl command, NS the namespace.
set -euo pipefail

K=${KUBECTL:-kubectl}
NS=${NS:-kafka}
NODE_RUNTIME=${NODE_RUNTIME:-k3d node}
MESSAGES=${MESSAGES:-6000}
RATE=${RATE:-100}
TOPIC=kafka-acceptance-test
BOOTSTRAP=lumen-kafka-bootstrap.$NS.svc.cluster.local:9093
STOPPED=""

k() {
  # shellcheck disable=SC2086
  $K -n "$NS" "$@"
}
# node stop|start NAME
node() {
  # shellcheck disable=SC2086
  $NODE_RUNTIME "$1" "$2"
}
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }
# c CMD...: a shell command in the client pod
c() { k exec kafka-test-client -- sh -c "$*"; }

cleanup() {
  for n in $STOPPED; do node start "$n" >/dev/null 2>&1 || true; done
  k delete pod kafka-test-client kafka-test-unlabelled --ignore-not-found --now >/dev/null 2>&1 || true
  k delete kafkauser kafka-test-writer kafka-test-reader kafka-test-noacl --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  k delete kafkatopic "$TOPIC" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
}
trap cleanup EXIT

IMAGE=$(k get kafka lumen -o jsonpath='{.spec.kafka.image}')
CLIENT_NODE=$($K get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')

echo "== Test topic and users"
k apply -f - >/dev/null <<EOF
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: $TOPIC
  labels: {strimzi.io/cluster: lumen}
spec:
  partitions: 3
  replicas: 3
  config: {min.insync.replicas: 2}
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: kafka-test-writer
  labels: {strimzi.io/cluster: lumen}
spec:
  authentication: {type: tls}
  authorization:
    type: simple
    acls:
      - resource: {type: topic, name: $TOPIC, patternType: literal}
        operations: [Describe, Write]
      - resource: {type: cluster}
        operations: [IdempotentWrite]
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: kafka-test-reader
  labels: {strimzi.io/cluster: lumen}
spec:
  authentication: {type: tls}
  authorization:
    type: simple
    acls:
      - resource: {type: topic, name: $TOPIC, patternType: literal}
        operations: [Describe, Read]
      - resource: {type: group, name: kafka-test, patternType: prefix}
        operations: [Describe, Read]
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: kafka-test-noacl
  labels: {strimzi.io/cluster: lumen}
spec:
  authentication: {type: tls}
  authorization:
    type: simple
    acls:
      - resource: {type: topic, name: another-topic, patternType: literal}
        operations: [Describe]
EOF
k wait kafkatopic "$TOPIC" --for=condition=Ready --timeout=120s >/dev/null
k wait kafkauser kafka-test-writer kafka-test-reader kafka-test-noacl --for=condition=Ready --timeout=120s >/dev/null

# pod NAME LABELS: a client on the control plane node
pod() {
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: $2
spec:
  nodeName: $CLIENT_NODE
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: client
      image: $IMAGE
      command: [sleep, "3600"]
      env:
        - {name: LOG_DIR, value: /tmp/logs}
      resources:
        requests: {cpu: 100m, memory: 512Mi}
        limits: {cpu: "1", memory: 512Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
        - {name: ca, mountPath: /certs/ca, readOnly: true}
        - {name: writer, mountPath: /certs/writer, readOnly: true}
        - {name: reader, mountPath: /certs/reader, readOnly: true}
        - {name: noacl, mountPath: /certs/noacl, readOnly: true}
  volumes:
    - {name: tmp, emptyDir: {}}
    - {name: ca, secret: {secretName: lumen-cluster-ca-cert}}
    - {name: writer, secret: {secretName: kafka-test-writer}}
    - {name: reader, secret: {secretName: kafka-test-reader}}
    - {name: noacl, secret: {secretName: kafka-test-noacl}}
EOF
  k wait pod "$1" --for=condition=Ready --timeout=120s >/dev/null
}
pod kafka-test-client '{kafka-client: "true"}'
pod kafka-test-unlabelled '{app: kafka-test}'

# The client properties: /tmp/USER.properties, and none.properties with no
# client certificate
c 'for u in writer reader noacl none; do
  {
    echo security.protocol=SSL
    echo ssl.truststore.type=PKCS12
    echo ssl.truststore.location=/certs/ca/ca.p12
    echo "ssl.truststore.password=$(cat /certs/ca/ca.password)"
    if [ "$u" != none ]; then
      echo ssl.keystore.type=PKCS12
      echo "ssl.keystore.location=/certs/$u/user.p12"
      echo "ssl.keystore.password=$(cat /certs/$u/user.password)"
    fi
    echo acks=all
    echo enable.idempotence=true
    echo retries=2147483647
  } > /tmp/$u.properties
done'

# produce USER COUNT RATE OUTPUT [DELIVERY_TIMEOUT_MS]: JSON lines in OUTPUT
produce() {
  c "cp /tmp/$1.properties /tmp/p.$4.properties
     echo request.timeout.ms=5000 >> /tmp/p.$4.properties
     echo delivery.timeout.ms=${5:-120000} >> /tmp/p.$4.properties
     bin/kafka-verifiable-producer.sh --bootstrap-server $BOOTSTRAP --topic $TOPIC \
       --max-messages $2 --throughput $3 --acks -1 --command-config /tmp/p.$4.properties \
       > /tmp/$4 2>/tmp/$4.err || true"
}
# count FILE NAME: lines of FILE that report the event NAME
count() { c "grep -c '\"name\":\"$2\"' /tmp/$1 || true"; }
# acked FILE: the values acknowledged in FILE, sorted
acked() { c "grep '\"name\":\"producer_send_success\"' /tmp/$1" | sed 's/.*"value":"\([0-9]*\)".*/\1/' | sort -n; }
# consume USER GROUP: every value of the topic, sorted
consume() {
  c "bin/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP --topic $TOPIC --from-beginning \
       --group $2 --timeout-ms 30000 --command-config /tmp/$1.properties 2>/tmp/consume.err || true" | sort -n
}
echo "== 1. Layout"
nodes=$(k get pods -l strimzi.io/pool-name=combined -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
[ "$nodes" -eq 3 ] || fail "brokers on $nodes nodes"
ok "3 brokers on 3 nodes"
[ "$(k get kafkatopic "$TOPIC" -o jsonpath='{.spec.replicas}')" = 3 ] || fail "replicas"
ok "topic replicated 3 times"

echo "== 2. Access"
produce writer 20 -1 first
[ "$(count first producer_send_success)" -eq 20 ] || fail "the writer could not write: $(c 'head -n 4 /tmp/first.err; tail -n 3 /tmp/first')"
ok "writer with its ACL: 20 messages acknowledged"
[ "$(consume reader kafka-test-a | wc -l)" -eq 20 ] || fail "the reader could not read: $(c 'tail -n 5 /tmp/consume.err')"
ok "reader with its ACL: 20 messages read"

produce reader 1 -1 denied-write 15000
[ "$(count denied-write producer_send_success)" -eq 0 ] || fail "the reader was not refused a write"
c "cat /tmp/denied-write /tmp/denied-write.err" | grep -q 'AuthorizationException' \
  || fail "the reader was not refused a write: $(c 'cat /tmp/denied-write.err; tail -n 3 /tmp/denied-write' | cut -c1-300)"
ok "reader refused a write"
consume writer kafka-test-b >/dev/null
c "cat /tmp/consume.err" | grep -q 'AuthorizationException\|Not authorized' || fail "the writer was not refused a read"
ok "writer refused a read"
produce noacl 1 -1 denied-noacl 15000
[ "$(count denied-noacl producer_send_success)" -eq 0 ] || fail "a user without an ACL was not refused"
c "cat /tmp/denied-noacl /tmp/denied-noacl.err" | grep -q 'AuthorizationException' \
  || fail "a user without an ACL was not refused: $(c 'cat /tmp/denied-noacl.err; tail -n 3 /tmp/denied-noacl' | cut -c1-300)"
ok "user without an ACL refused"
produce none 1 -1 denied-nocert 15000
[ "$(count denied-nocert producer_send_success)" -eq 0 ] || fail "a client without a certificate wrote"
c "cat /tmp/denied-nocert /tmp/denied-nocert.err" | grep -q 'SSL handshake failed\|SslAuthenticationException\|Failed authentication\|TimeoutException' \
  || fail "no refusal reported for the client without a certificate"
ok "client without a certificate refused"

tcp='timeout 5 bash -c "exec 3<>/dev/tcp/lumen-kafka-bootstrap/9093" && echo open || echo closed'
[ "$(k exec kafka-test-client -- bash -c "$tcp" 2>/dev/null)" = open ] || fail "port 9093 closed to a labelled pod"
[ "$(k exec kafka-test-unlabelled -- bash -c "$tcp" 2>/dev/null)" = closed ] || fail "port 9093 open to a pod without the label"
ok "port 9093: open with the label kafka-client=true, closed without"

echo "== 3. A node stopped during a write load"
# By address: restarted in this order, k3d containers get their address back
# (the next free one), and K3s does not start on another address
VICTIMS=()
while read -r _ n; do VICTIMS+=("$n"); done < <(
  for n in $(k get pods -l strimzi.io/pool-name=combined -o jsonpath='{.items[*].spec.nodeName}'); do
    [ "$n" = "$CLIENT_NODE" ] && continue
    echo "$($K get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}') $n"
  done | sort -t. -k4 -n)
[ "${#VICTIMS[@]}" -eq 2 ] || fail "expected 2 nodes without the client, got ${#VICTIMS[*]}"
produce writer "$MESSAGES" "$RATE" load &
LOAD=$!
sleep 15
echo "  stopping ${VICTIMS[0]}"
node stop "${VICTIMS[0]}" >/dev/null 2>&1
STOPPED=${VICTIMS[0]}
wait "$LOAD"
sent=$(count load producer_send_success)
errors=$(count load producer_send_error)
[ "$sent" -eq "$MESSAGES" ] || fail "$sent of $MESSAGES acknowledged, $errors errors"
ok "$sent of $MESSAGES messages acknowledged, $errors errors, with one node down"

first_seen=$(mktemp); read_back=$(mktemp); trap 'rm -f "$first_seen" "$read_back"; cleanup' EXIT
acked load > "$first_seen"
consume reader kafka-test-c > "$read_back"
[ -s "$read_back" ] || fail "the reader read nothing, which says nothing about the messages: $(c 'tail -n 5 /tmp/consume.err' | cut -c1-400)"
missing=$(comm -23 <(sort -u "$first_seen") <(sort -u "$read_back") | wc -l)
[ "$missing" -eq 0 ] || fail "$missing acknowledged messages missing"
ok "every acknowledged message read back, with one node down"

echo "== 4. Control: a second node stopped, writes are refused"
node stop "${VICTIMS[1]}" >/dev/null 2>&1
STOPPED="$STOPPED ${VICTIMS[1]}"
produce writer 5 -1 refused 20000
[ "$(count refused producer_send_success)" -eq 0 ] || fail "a write was acknowledged with one broker left"
ok "no write acknowledged with one broker left"

echo "== 5. Both nodes back"
node start "${VICTIMS[0]}" >/dev/null 2>&1
node start "${VICTIMS[1]}" >/dev/null 2>&1
STOPPED=""
$K wait node "${VICTIMS[0]}" "${VICTIMS[1]}" --for=condition=Ready --timeout=300s >/dev/null || fail "nodes not back"
# A pod of a stopped node keeps its last status: only a pod that is not being
# deleted, on a node that is back, counts
ready_brokers() {
  k get pods -l strimzi.io/pool-name=combined \
    -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}deleting{"\n"}{end}{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
    | awk '/deleting/{d++} /True/{t++} END{print t-d}'
}
for _ in $(seq 1 90); do
  [ "$(ready_brokers)" -eq 3 ] && break
  sleep 5
done
[ "$(ready_brokers)" -eq 3 ] || fail "brokers not ready"
ok "3 brokers ready, no action on them"
for _ in $(seq 1 30); do
  produce writer 20 -1 resumed 30000
  [ "$(count resumed producer_send_success)" -eq 20 ] && break
  sleep 10
done
[ "$(count resumed producer_send_success)" -eq 20 ] || fail "writes did not resume"
ok "writes resumed"
consume reader kafka-test-d > "$read_back"
[ -s "$read_back" ] || fail "the reader read nothing, which says nothing about the messages: $(c 'tail -n 5 /tmp/consume.err' | cut -c1-400)"
missing=$(comm -23 <(sort -u "$first_seen") <(sort -u "$read_back") | wc -l)
[ "$missing" -eq 0 ] || fail "$missing acknowledged messages missing after the recovery"
ok "every acknowledged message read back after the recovery"

echo "PASS"
