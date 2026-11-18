#!/bin/bash
# End-to-end test of the event stream (issue #44, docs/runbooks/kafka.md):
#
#   1. events inserted in PostgreSQL reach the consumer, each counted once;
#   2. the active relay is deleted under load: nothing is lost;
#   3. Kafka stopped: events are still accepted and wait in the outbox, then
#      every one is published when Kafka is back;
#   4. every message delivered again: nothing is counted twice;
#   5. a message that cannot be read goes to the dead letter topic, and the
#      consumer carries on;
#   6. the topic deleted, then rebuilt from PostgreSQL: it holds every event.
#
# Stops Kafka, deletes the topic and adds events: run it on a test cluster.
# KUBECTL overrides the kubectl command, PG_POD the PostgreSQL pod (namespace
# lumen, container postgres, database app).
set -euo pipefail

K=${KUBECTL:-kubectl}
NS=kafka
PG_POD=${PG_POD:-lumen-db-1}
TOPIC=lumen.events
DLQ=lumen.events.dlq
GROUP=lumen-events-consumer
BOOTSTRAP=lumen-kafka-bootstrap.$NS.svc.cluster.local:9093
MANIFESTS=${MANIFESTS:-$(cd "$(dirname "$0")/../../manifests/kafka" && pwd)}

k() {
  # shellcheck disable=SC2086
  $K -n "$NS" "$@"
}
sql() {
  # shellcheck disable=SC2086
  $K -n lumen exec "$PG_POD" -c postgres -- psql -U postgres -d app -v ON_ERROR_STOP=1 -tAc "$1"
}
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }
# c CMD...: a shell command in the client pod
c() { k exec kafka-test-stream -- sh -c "$*"; }

cleanup() {
  k scale deployment strimzi-cluster-operator --replicas=1 >/dev/null 2>&1 || true
  k scale deployment lumen-events-consumer lumen-outbox-relay --replicas=2 >/dev/null 2>&1 || true
  k delete pod kafka-test-stream --ignore-not-found --now >/dev/null 2>&1 || true
  k delete kafkauser kafka-test-stream --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
}
trap cleanup EXIT

# insert N TYPE: N events, as lumen-api writes them
insert() {
  sql "INSERT INTO events (type, aggregate, payload, actor)
       SELECT '$2', 'item', jsonb_build_object('id', g), 'event-stream-test' FROM generate_series(1, $1) g" >/dev/null
}
pending() { sql "SELECT count(*) FROM outbox"; }
applied() { sql "SELECT count(*) FROM processed_events"; }
events() { sql "SELECT count(*) FROM events"; }
total() { sql "SELECT COALESCE(sum(total), 0) FROM event_counts"; }

# wait_for DESCRIPTION SECONDS COMMAND EXPECTED
wait_for() {
  local got=""
  for _ in $(seq 1 "$2"); do
    got=$($3 2>/dev/null || true)
    [ "$got" = "$4" ] && return 0
    sleep 1
  done
  fail "$1: got '$got', want '$4'"
}
# drained: every event is published and applied, each counted once
drained() {
  local want
  want=$(events)
  wait_for "outbox" 180 pending 0
  wait_for "applied events" 180 applied "$want"
  [ "$(total)" = "$want" ] || fail "counted $(total) events, want $want"
}
# offsets TOPIC: the messages held by the topic
offsets() {
  c "bin/kafka-get-offsets.sh --bootstrap-server $BOOTSTRAP --command-config /tmp/client.properties --topic $1 2>/dev/null" \
    | awk -F: '{s += $3} END {print s + 0}'
}
# consumed RESULT: the counter of the consumers
consumed() {
  local sum=0 pod port=19090 v
  for pod in $(k get pods -l app=$GROUP --field-selector=status.phase=Running -o name); do
    k port-forward "$pod" "$port:9090" >/dev/null 2>&1 &
    local pf=$!
    sleep 2
    v=$(curl -s "http://127.0.0.1:$port/metrics" | awk -v r="result=\"$1\"" 'index($0, r) && /^lumen_events_consumed_total/ {print $2}')
    kill "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
    sum=$((sum + ${v:-0}))
    port=$((port + 1))
  done
  echo "$sum"
}

echo "== Client"
IMAGE=$(k get kafka lumen -o jsonpath='{.spec.kafka.image}')
k apply -f - >/dev/null <<EOF
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: kafka-test-stream
  labels: {strimzi.io/cluster: lumen}
spec:
  authentication: {type: tls}
  authorization:
    type: simple
    acls:
      - resource: {type: topic, name: lumen.events, patternType: prefix}
        operations: [Describe, Read, Write]
      - resource: {type: group, name: $GROUP, patternType: literal}
        operations: [Describe, Read]
      - resource: {type: group, name: kafka-test, patternType: prefix}
        operations: [Describe, Read]
      - resource: {type: cluster}
        operations: [IdempotentWrite]
EOF
k wait kafkauser kafka-test-stream --for=condition=Ready --timeout=120s >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kafka-test-stream
  labels: {kafka-client: "true"}
spec:
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
        - {name: user, mountPath: /certs/user, readOnly: true}
  volumes:
    - {name: tmp, emptyDir: {}}
    - {name: ca, secret: {secretName: lumen-cluster-ca-cert}}
    - {name: user, secret: {secretName: kafka-test-stream}}
EOF
k wait pod kafka-test-stream --for=condition=Ready --timeout=120s >/dev/null
c 'cat > /tmp/client.properties <<EOP
security.protocol=SSL
ssl.truststore.type=PKCS12
ssl.truststore.location=/certs/ca/ca.p12
ssl.truststore.password=$(cat /certs/ca/ca.password)
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/user/user.p12
ssl.keystore.password=$(cat /certs/user/user.password)
EOP'
k rollout status deployment lumen-outbox-relay --timeout=180s >/dev/null
k rollout status deployment lumen-events-consumer --timeout=180s >/dev/null

echo "== 1. Events reach the consumer"
insert 50 ItemCreated
drained
ok "$(events) events published and counted once"

echo "== 2. The relays deleted under load"
insert 200 ItemCreated &
INSERT=$!
k delete pod -l app=lumen-outbox-relay --wait=false >/dev/null
wait "$INSERT"
insert 50 ItemDeleted
k rollout status deployment lumen-outbox-relay --timeout=180s >/dev/null
drained
ok "$(events) events published and counted once"

echo "== 3. Kafka stopped"
k scale deployment strimzi-cluster-operator --replicas=0 >/dev/null
k wait pod -l strimzi.io/kind=cluster-operator --for=delete --timeout=120s >/dev/null 2>&1 || true
k delete strimzipodset lumen-combined --cascade=foreground --wait=false >/dev/null
k wait pod -l strimzi.io/pool-name=combined --for=delete --timeout=180s >/dev/null
insert 30 ItemCreated
sleep 20
[ "$(pending)" = 30 ] || fail "outbox holds $(pending) events with Kafka stopped, want 30"
ok "30 events accepted and waiting in the outbox"
k scale deployment strimzi-cluster-operator --replicas=1 >/dev/null
k wait kafka lumen --for=condition=Ready=false --timeout=120s >/dev/null 2>&1 || true
k wait kafka lumen --for=condition=Ready --timeout=600s >/dev/null
drained
ok "Kafka back: every waiting event published and counted once"

echo "== 4. Every message delivered again"
before=$(total)
k scale deployment lumen-events-consumer --replicas=0 >/dev/null
k wait pod -l app=$GROUP --for=delete --timeout=120s >/dev/null
for _ in $(seq 1 12); do
  c "bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP --command-config /tmp/client.properties \
       --group $GROUP --topic $TOPIC --reset-offsets --to-earliest --execute >/tmp/reset.out 2>&1" && break
  sleep 10
done
held=$(offsets $TOPIC)
[ "$held" -gt 0 ] || fail "the topic holds no message"
k scale deployment lumen-events-consumer --replicas=2 >/dev/null
k rollout status deployment lumen-events-consumer --timeout=180s >/dev/null
for _ in $(seq 1 90); do
  dup=$(consumed duplicate)
  [ "$dup" -ge "$held" ] && break
  sleep 2
done
[ "${dup:-0}" -ge "$held" ] || fail "$dup messages delivered again, want $held"
[ "$(total)" = "$before" ] || fail "counted $(total) events after the redelivery, want $before"
ok "$dup messages delivered again, the count did not change ($before)"

echo "== 5. A message that cannot be read"
dead=$(offsets $DLQ)
c "echo 'this is not an event' | bin/kafka-console-producer.sh --bootstrap-server $BOOTSTRAP \
     --command-config /tmp/client.properties --topic $TOPIC 2>/dev/null"
wait_for "dead letter topic" 60 "offsets $DLQ" "$((dead + 1))"
insert 5 ItemCreated
drained
ok "sent to $DLQ, and the consumer carried on"

echo "== 6. The topic rebuilt from PostgreSQL"
k delete kafkatopic $TOPIC --timeout=120s >/dev/null
k apply -f "$MANIFESTS/02-topics.yaml" >/dev/null
k wait kafkatopic $TOPIC --for=condition=Ready --timeout=120s >/dev/null
sleep 10
[ "$(offsets $TOPIC)" = 0 ] || fail "the new topic is not empty"
before=$(total)
RELAY_IMAGE=$(k get deployment lumen-outbox-relay -o jsonpath='{.spec.template.spec.containers[0].image}')
k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-test-rebuild
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: {app: lumen-outbox-relay, tier: backend}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: rebuild
          image: $RELAY_IMAGE
          args: [outbox-rebuild]
          env:
            - name: PG_USER
              valueFrom: {secretKeyRef: {name: lumen-db-runtime, key: username}}
            - name: PG_PASSWORD
              valueFrom: {secretKeyRef: {name: lumen-db-runtime, key: password}}
            - name: PG_DSN
              value: postgresql://\$(PG_USER):\$(PG_PASSWORD)@lumen-db-rw.lumen.svc.cluster.local:5432/app
            - {name: KAFKA_BROKERS, value: "$BOOTSTRAP"}
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits: {cpu: 250m, memory: 64Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
EOF
k wait job kafka-test-rebuild --for=condition=Complete --timeout=180s >/dev/null \
  || fail "rebuild Job: $(k logs job/kafka-test-rebuild --tail=5 | cut -c1-400)"
k delete job kafka-test-rebuild --wait=false >/dev/null
wait_for "outbox after the rebuild" 180 pending 0
want=$(events)
wait_for "messages in the rebuilt topic" 120 "offsets $TOPIC" "$want"
sleep 15
[ "$(total)" = "$before" ] || fail "counted $(total) events after the rebuild, want $before"
ok "$want events in the rebuilt topic, the count did not change"
insert 5 ItemCreated
drained
ok "new events go through the rebuilt topic"

echo "PASS"
