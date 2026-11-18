# Redis with Sentinel

Issue #8. One StatefulSet `redis` of 3 pods (`manifests/app/02-redis.yaml`).
Each pod runs a Redis server and a Sentinel, with a volume for the data
(RDB and AOF) and for its Sentinel's configuration. Any pod can be the
master: Sentinel elects it.

```
redis-0 ─┐   redis-N.redis-headless.lumen.svc.cluster.local, announced by
redis-1 ─┼─  Redis (replica-announce-ip) and Sentinel (announce-ip):
redis-2 ─┘   the topology survives the pods' IP changes

lumen-api ── redis-sentinel:26379 ── which pod is the master ── that pod :6379
```

## Configuration

| Setting | Value | Why |
|---|---|---|
| `maxmemory` | 128 MB, half the 256 Mi limit | a save or an AOF rewrite forks, and the copy-on-write pages count against the same limit |
| `maxmemory-policy` | `noeviction` | idempotency records, locks and rate limit counters are not evicted silently. When full, writes fail and lumen-api answers 503 |
| Persistence | RDB, plus AOF `everysec` | at most one second of writes lost on a crash |
| Replication buffers | backlog 16 MB, replica output buffer 64 MB / 32 MB for 60s | bounded |
| Password | `requirepass` on Redis **and** Sentinel, `sentinel-pass` between Sentinels | Secret `lumen-redis-vault` (Vault `lumen/redis`). lumen-api sends it to both (`SentinelPassword`) |
| Sentinel | quorum 2, `down-after-milliseconds` 5000 | |
| Pods | `podManagementPolicy: Parallel`, preferred spread over the nodes, PDB `maxUnavailable: 1` | |

**Which pod is the master** is decided by the init container of each pod
(`init.sh` in the ConfigMap), in this order:
1. what a Sentinel of another pod answers (a running cluster);
2. the master this pod's Sentinel last recorded on its volume (a full
   restart);
3. `redis-0` (first start).

The Sentinel configuration is created once on the volume. After that,
Sentinel rewrites it as the topology changes, and the init container only
refreshes the passwords.

## Operations

```bash
# Who is the master (any pod)
kubectl exec -n lumen redis-0 -c sentinel -- sh -c \
  'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -p 26379 sentinel get-master-addr-by-name mymaster'

# Failover test: master's node cordoned and pod deleted, then every Sentinel
# restarted; checks the topology and a key (disruptive)
03-airgap-zone/tests/redis/failover-test.sh

# Memory test: fills the master past maxmemory while it saves; checks that
# writes are refused and that no container reached its limit (test cluster)
03-airgap-zone/tests/redis/memory-test.sh
```

## Moving from the former topology

Before: `redis-master`, `redis-replica` and `redis-sentinel`, three
StatefulSets with fixed roles.

**Release lumen-api first.** The new Sentinels require a password, and a
lumen-api without `SentinelPassword` (v1.7.0 and older) gets `NOAUTH`
from them. The new client works with the former Sentinels too (measured,
see Tested): ship it in a release, then change Redis.

Then push. ArgoCD creates the StatefulSet `redis`, points the Service
`redis-sentinel` at its pods, and prunes the three former StatefulSets.
lumen-api finds the new master through the Sentinels.

- The data of the former Redis is not copied: idempotency records (24h),
  counters, rate limit windows. For the next 24 hours, a retry with a key
  recorded before the switch runs again. Do it when traffic is low.
- The former volume `redis-data-redis-master-0` stays: delete it once the
  new Redis runs (`kubectl delete pvc -n lumen redis-data-redis-master-0`).
- `REDIS_ADDR` (`redis:6379`) in `lumen-api-config` is only read in
  standalone mode. The Service `redis` is gone.

## Tested

On 17 November 2026, on k3d (K3s v1.33.6), two nodes like lumen, with
`app/01-namespace.yaml` (Pod Security `restricted`), the NetworkPolicies
01 to 04 of `lumen` (default deny included), and lumen-api built from this
branch in sentinel mode, without PostgreSQL.

| Case | Result | Control |
|---|---|---|
| First start | 3 pods ready, on both nodes, `redis-0` master | |
| lumen-api through the Sentinels with the password | connected | `redis-cli` to a Sentinel without the password: `NOAUTH` |
| `failover-test.sh`, three runs | master's node cordoned, pod deleted: new master in 7 to 9s; topology consistent (all Sentinels agree, 2 linked replicas), key kept | |
| Every Sentinel restarted after a failover to `redis-2` | still `redis-2`, as in each Sentinel's file on its volume | a failover back to `redis-0` could not tell persisted from reset Sentinels, hence that run |
| `/health` of lumen-api every 0.5s during a failover | 2 × 503 (3s), then 200, no restart | |
| `memory-test.sh` | 240,000 writes of 1 KB with saves and AOF rewrites: `used_memory` stops at `maxmemory`, writes refused (`OOM command not allowed`), 0 evicted keys, peak 60% of the limit on the master, 42 to 46% on the replicas, no restart | |
| Go client with `SentinelPassword`, against a Sentinel without a password (Redis 7.4.12) | master found | |

Found while testing:
- A master pod deleted without the cordon comes back within seconds,
  under the same name, before `down-after-milliseconds`. It stays master
  with its data, and nothing fails over. The test cordons the node to
  force a real failover.
- `/hello` answers 200 even when Redis fails (the counter falls back to
  0). `/health` is the one that shows it.

Not tested:
- the lumen cluster;
- the move from the former topology (above);
- memory under writes heavier than the test's; the 60% peak is the
  test's, not a bound.

## Limits

- **3 pods on 2 nodes, until `node-3` is deployed** (#44): one node carries
  two Sentinels. If that node is lost, only one Sentinel is left, short of
  the majority a failover needs. If the master was on that node, Redis stays
  without a master until the node comes back. Redis on 3 nodes was not tested.
- **Asynchronous replication**: a failover loses the writes the new master
  had not received yet, idempotency records included (#33).
- **Full restart**: each pod restarts from its own Sentinel's last record.
  If the Sentinels disagreed when they all stopped, two pods could start
  as master, until the Sentinels converge. Not tested.
