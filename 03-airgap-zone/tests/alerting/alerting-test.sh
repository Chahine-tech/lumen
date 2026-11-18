#!/bin/bash
# End-to-end test of the alerting chain (issue #23, docs/runbooks/alerting.md):
#
#   1. the Watchdog alert reaches ntfy on backup-1;
#   2. a critical and a warning alert arrive with their priority, once each
#      although two Alertmanager replicas run;
#   3. an info alert, and a warning hidden by its critical twin, do not arrive;
#   4. a resolved alert is notified;
#   5. a silence survives the restart of both replicas;
#   6. Prometheus stopped: the dead man's switch on backup-1 raises the alarm,
#      and says so when the Watchdog comes back.
#
# Stops Prometheus for about 10 minutes: run it on a test cluster.
# KUBECTL overrides the kubectl command, BACKUP_EXEC the command that runs a
# shell as root on backup-1, NTFY_HOST the address of ntfy there.
set -euo pipefail

K=${KUBECTL:-kubectl}
BACKUP_EXEC=${BACKUP_EXEC:-multipass exec backup-1 -- sudo}
NTFY_HOST=${NTFY_HOST:-192.168.2.4}
NS=monitoring
PROMETHEUS=kube-prometheus-stack-prometheus
AM=alertmanager-kube-prometheus-stack-alertmanager
RUN=$(date +%s)
NAME=LumenAlertingTest$RUN

k() {
  # shellcheck disable=SC2086
  $K -n "$NS" "$@"
}
backup() {
  # shellcheck disable=SC2086
  $BACKUP_EXEC bash -c "$1"
}
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }

cleanup() {
  k patch prometheus "$PROMETHEUS" --type merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1 || true
  k delete prometheusrule alerting-test --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# messages TOPIC TOKEN_VARIABLE: the JSON messages published since the start
messages() {
  backup ". /etc/ntfy/secrets.env; curl -fsS --max-time 20 --cacert /etc/ntfy/ca.crt \
    -H \"Authorization: Bearer \$$2\" 'https://$NTFY_HOST:2586/$1/json?poll=1&since=$RUN'"
}
# count_alerts TEXT PRIORITY: the notifications that hold TEXT, with PRIORITY
# (0: any). The reader has a password and no token: read as the operator would
count_alerts() {
  backup ". /etc/ntfy/secrets.env; curl -fsS --max-time 20 --cacert /etc/ntfy/ca.crt \
    -u \"reader:\$READER_PASSWORD\" 'https://$NTFY_HOST:2586/lumen-alerts/json?poll=1&since=$RUN'" \
    | python3 -c '
import json, sys
text, priority = sys.argv[1], int(sys.argv[2])
n = 0
for line in sys.stdin:
    m = json.loads(line)
    body = m.get("title", "") + "\n" + m.get("message", "")
    if text in body and (priority == 0 or m.get("priority", 3) == priority):
        n += 1
print(n)' "$1" "$2"
}
# forward: a port-forward to the first Alertmanager, ready when it returns
forward() {
  k port-forward "pod/$AM-0" 19093:9093 >/dev/null 2>&1 &
  PF=$!
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 http://127.0.0.1:19093/-/ready >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "Alertmanager does not answer through the port-forward"
}
stop_forward() {
  kill "$PF" 2>/dev/null || true
  wait "$PF" 2>/dev/null || true
}
# wait_alert DESCRIPTION SECONDS TEXT PRIORITY
wait_alert() {
  for _ in $(seq 1 $(($2 / 5))); do
    [ "$(count_alerts "$3" "$4")" -ge 1 ] && return 0
    sleep 5
  done
  fail "$1: no notification with '$3' after $2s"
}

echo "== 1. Watchdog"
for _ in $(seq 1 36); do
  beats=$(messages lumen-watchdog DEADMAN_TOKEN | wc -l | tr -d ' ')
  [ "$beats" -ge 1 ] && break
  sleep 5
done
[ "$beats" -ge 1 ] || fail "no Watchdog notification in 3 minutes"
ok "Watchdog received on backup-1"

echo "== 2. Notifications"
k apply -f - >/dev/null <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: alerting-test
  labels: {release: kube-prometheus-stack}
spec:
  groups:
    - name: alerting-test
      interval: 15s
      rules:
        - alert: ${NAME}Critical
          expr: vector(1)
          labels: {severity: critical, service: alerting-test}
          annotations: {summary: critical test alert}
        - alert: ${NAME}Warning
          expr: vector(1)
          labels: {severity: warning, service: alerting-test}
          annotations: {summary: warning test alert}
        - alert: ${NAME}Info
          expr: vector(1)
          labels: {severity: info, service: alerting-test}
          annotations: {summary: info test alert}
        - alert: ${NAME}Inhibited
          expr: vector(1)
          labels: {severity: critical, service: alerting-test}
          annotations: {summary: inhibiting test alert}
        - alert: ${NAME}Inhibited
          expr: vector(1)
          labels: {severity: warning, service: alerting-test}
          annotations: {summary: inhibited test alert}
EOF
wait_alert "critical" 300 "${NAME}Critical" 5
ok "critical alert notified with priority 5"
wait_alert "warning" 300 "${NAME}Warning" 3
ok "warning alert notified with priority 3"

echo "== 3. What must not arrive"
wait_alert "inhibiting alert" 300 "${NAME}Inhibited" 5
sleep 150
[ "$(count_alerts "${NAME}Critical" 5)" -eq 1 ] || fail "critical alert notified $(count_alerts "${NAME}Critical" 5) times, want 1"
ok "one notification from the two replicas"
[ "$(count_alerts "${NAME}Info" 0)" -eq 0 ] || fail "info alert notified"
ok "info alert not notified"
[ "$(count_alerts "${NAME}Inhibited" 3)" -eq 0 ] || fail "inhibited warning notified"
ok "warning hidden by its critical twin"

echo "== 4. Resolved"
k delete prometheusrule alerting-test >/dev/null
wait_alert "resolved" 600 "Resolved" 0
ok "resolved alert notified"

echo "== 5. A silence survives a restart"
forward
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
end=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
id=$(curl -fsS -H 'Content-Type: application/json' http://127.0.0.1:19093/api/v2/silences -d \
  "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"${NAME}Silenced\",\"isRegex\":false}],\"startsAt\":\"$now\",\"endsAt\":\"$end\",\"createdBy\":\"alerting-test\",\"comment\":\"test\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["silenceID"])')
stop_forward
sleep 5
k delete pod "$AM-0" "$AM-1" >/dev/null
sleep 10
k wait pod "$AM-0" "$AM-1" --for=condition=Ready --timeout=300s >/dev/null
forward
# A silence is pending until its start time on the clock of the pod
for _ in $(seq 1 30); do
  state=$(curl -fsS "http://127.0.0.1:19093/api/v2/silence/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])')
  [ "$state" = active ] && break
  sleep 2
done
stop_forward
[ "$state" = active ] || fail "silence is '$state' after the restart"
ok "silence still active after both replicas restarted"

echo "== 6. Dead man's switch"
k patch prometheus "$PROMETHEUS" --type merge -p '{"spec":{"replicas":0}}' >/dev/null
wait_alert "dead man's switch" 1200 "Lumen alerting is down" 5
ok "alarm raised from backup-1 with Prometheus stopped"
k patch prometheus "$PROMETHEUS" --type merge -p '{"spec":{"replicas":1}}' >/dev/null
wait_alert "recovery" 900 "Lumen alerting is back" 0
ok "recovery notified"

echo "PASS"
