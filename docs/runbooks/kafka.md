# Kafka and the event stream

Issue #44. lumen-api publishes its events to Kafka through an outbox.
PostgreSQL stays the source of truth: a topic can be rebuilt from it.

```
lumen-api ── transaction ──> items + events
                               └─ trigger ──> outbox
                                                │  relay (lumen-api relay)
                                                ▼  acks=all, mTLS
                                          lumen.events ── consumer (lumen-api consume)
                                                              ├─> processed_events + event_counts
                                                              └─> lumen.events.dlq (unreadable)
```

| What | Where |
|---|---|
| Operator | `manifests/strimzi-helm`, Application `strimzi` |
| Cluster, topics, users, metrics, workers | `manifests/kafka`, Application `kafka` |
| Namespace, NetworkPolicies | `network-policies/20-allow-kafka.yaml` |
| PostgreSQL credentials of the workers | `vso/07-kafka-workers-secret.yaml`, Vault role `kafka-workers` |
| Schema | migration `00003_outbox.sql` |
| Code | `01-connected-zone/app/internal/eventstream` |
| Alerts | `kube-prometheus-stack/kafka-rules.yaml` |
| Tests | `03-airgap-zone/tests/kafka` |

## Prerequisites

- **Kubernetes 1.32 or later** (Strimzi 1.3). `group_vars` pins K3s v1.28.5:
  [k3s-upgrade-path](k3s-upgrade-path.md).
- **3 nodes**, `node-3` included: the brokers have a `required` anti-affinity
  and do not schedule on fewer.
- **One CoreDNS replica per node** (role `k3s`). See [Tested](#tested): with
  the single replica K3s deploys, losing its node interrupts Kafka.

The namespace requests about 1 CPU and 4.1 GiB of memory (sum of the
manifests). What is left on each node of lumen was not measured.

## Design

| Choice | Why |
|---|---|
| 3 KRaft nodes, broker and controller, one per K3s node | one node lost keeps the quorum (2 of 3) |
| Replication 3, `min.insync.replicas` 2, `acks=all`, no unclean election | an acknowledged message is on 2 brokers at least |
| A trigger fills the outbox | the row commits with the event, whichever version of lumen-api wrote it |
| One active relay (advisory lock), a second on standby | two would interleave batches and could reorder the events of an item |
| Key `item:<id>` | the events of an item stay in one partition, in order |
| At least once | a relay that stops after the acknowledgement publishes the batch again |
| The consumer records each event id with its effect, in one transaction | a redelivered event changes nothing |
| Workers in `kafka` | Strimzi keeps the client certificates in that namespace |

lumen-api has no connection to Kafka: while Kafka is down, events wait in
the outbox.

A relay or a consumer exits when its topic was deleted and created again
(`UNKNOWN_TOPIC_ID`): the client keeps the former topic id. The kubelet
restarts it with a new client.

## Operations

```bash
kubectl get kafka,kafkanodepool,kafkatopic,kafkauser -n kafka
kubectl get pods -n kafka

# What waits to be published
kubectl exec -n lumen lumen-db-1 -c postgres -- psql -U postgres -d app -c \
  "SELECT count(*), min(created_at) FROM outbox"

# Which relay is active: lumen_outbox_relay_active is 1 on that pod
kubectl port-forward -n kafka deploy/lumen-outbox-relay 9090 &
curl -s localhost:9090/metrics | grep '^lumen_outbox'
```

### A new client

1. A `KafkaUser` in `kafka/03-users.yaml`, with the ACLs it needs.
2. The label `kafka-client: "true"` on its pods: the listener refuses the
   others.
3. Mount the Secret of the user and `ca.crt` of `lumen-cluster-ca-cert`.

### Reading the dead letter topic

Each message keeps its key and value, with the headers `error`,
`source-topic`, `source-partition` and `source-offset`. From a pod with the
label `kafka-client=true` and a user allowed to read the topic (see
`tests/kafka/event-stream-test.sh` for such a pod):

```bash
bin/kafka-console-consumer.sh --bootstrap-server lumen-kafka-bootstrap:9093 \
  --command-config /tmp/client.properties --topic lumen.events.dlq \
  --from-beginning --property print.headers=true --timeout-ms 10000
```

### Rebuilding a topic from PostgreSQL

Every event of the `events` table is queued again. Events already applied
are not counted twice.

```bash
kubectl apply -f 03-airgap-zone/manifests/kafka/02-topics.yaml    # if the topic is gone
kubectl wait kafkatopic lumen.events -n kafka --for=condition=Ready
```

Then run `lumen-api outbox-rebuild` once, as a Job with the environment of
the relay and the label `app: lumen-outbox-relay` (step 6 of
`tests/kafka/event-stream-test.sh`). Check that `outbox` drains, and that the
topic holds as many messages as `events` has rows.

### Replacing a broker

Not rehearsed. A broker keeps its data on the `local-path` volume of its
node. When a node is lost for good, delete the PVC and the pod of its broker:
Strimzi creates them again, and the broker copies its replicas from the two
others.

## Alerts

| Alert | When |
|---|---|
| `KafkaOfflinePartitions` (critical) | partitions without a leader for 1 minute |
| `KafkaNoActiveController` (critical) | not exactly one active controller for 2 minutes |
| `KafkaUnderReplicatedPartitions` | replicas out of sync for 10 minutes |
| `KafkaMetricsAbsent` | no broker metric for 10 minutes |
| `KafkaConsumerLagHigh` | more than 1000 messages waiting for 10 minutes |
| `LumenOutboxEventsDelayed` (critical) | oldest event in the outbox older than 5 minutes, for 5 minutes |
| `LumenOutboxRelayAbsent` (critical) | no relay metric for 10 minutes |
| `LumenEventsDeadLettered` | a message reached the dead letter topic |

Notifications: [alerting](alerting.md).

## Tested

On 18 November 2026, on k3d (K3s v1.33.6, 3 nodes), with Strimzi 1.3.1, Kafka
4.3.2, the NetworkPolicies of `kafka` and `lumen` (default deny included), and
a PostgreSQL 16.6 pod in place of CNPG.

`tests/kafka/acceptance-test.sh`:

| Case | Result | Control |
|---|---|---|
| Client with its ACL | writes and reads | a reader cannot write, a writer cannot read, a user without an ACL and a client without a certificate are refused |
| Port 9093 | open with the label `kafka-client=true` | closed without it |
| One node stopped under load, `acks=all` | 6000 of 6000 acknowledged, all read back | two nodes stopped: no write acknowledged |
| Both nodes back | brokers ready, writes resume, nothing missing, no action | |
| CoreDNS, one replica per node, one on the stopped node | 3 runs of 3 pass, then 3 more on the final configuration | one replica, on the stopped node: 4 runs of 4 fail (2 lost writes, 2 could not read back) |
| K3s restarted with 3 CoreDNS replicas | manifest applied again, 3 replicas kept | a changed memory limit was reverted, so the manifest was applied |

`tests/kafka/event-stream-test.sh`:

| Case | Result |
|---|---|
| Events inserted in PostgreSQL | all published, each counted once |
| The relays deleted under load | all published, each counted once |
| Kafka stopped | 30 events accepted and kept in the outbox, all published once it is back |
| Every message delivered again | the count does not change |
| A message that cannot be read | in the dead letter topic, the consumer carries on |
| Topic deleted, then rebuilt | holds every event, the count does not change, new events go through |

Found while testing:
- after a topic is recreated, the relay and the consumer failed forever on
  the former topic id: they now exit and restart;
- `outbox-rebuild` failed in a new pod, before its NetworkPolicies were
  programmed: it now retries for a minute.

The Go tests run against a real PostgreSQL and an in-memory Kafka (kfake).
Each one was checked to fail when the code it covers is broken. The metrics of
the alerts were read on the running brokers, Kafka Exporter and relay; the
alerts themselves are unit-tested with promtool.

Not tested:
- the lumen cluster, CNPG, and the Ansible and Terraform changes;
- VSO and Vault for the workers (a Secret was created by hand);
- lumen-api itself writing events: the tests insert rows in `events`, which
  fires the same trigger;
- Prometheus scraping the PodMonitors;
- ArgoCD syncing these Applications;
- a Strimzi or Kafka upgrade, and replacing a broker.

## Limits

- **`processed_events` keeps every event id**, without retention: the
  consumer needs them to recognize a rebuilt topic.
- **`local-path` volumes**: a broker is tied to its node. Kafka replicates its
  data, but a lost node leaves 2 replicas until the broker is replaced.
- **The cluster CA is read when a worker starts.** The client certificate is
  read at each connection. After a renewal of the cluster CA, restart the
  workers.
- **The consumer is a demonstration**: it counts events per type
  (`event_counts`).
