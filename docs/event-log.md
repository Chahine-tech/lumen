# Event Log (Audit Trail) — lumen-api v1.6.0

Pattern: **append-only Event Log** in PostgreSQL, inspired by Event Sourcing, with per-type Prometheus counters.

---

## Concept

Every mutation on `items` writes an event to the `events` table **within the same PostgreSQL transaction** as the mutation itself. If the transaction rolls back, the event is not written — atomicity guaranteed.

```
POST /items   → tx { INSERT items + INSERT events(ItemCreated) } → commit → counter.Inc()
DELETE /items → tx { DELETE items + INSERT events(ItemDeleted) } → commit → counter.Inc()
```

The `events` table is **append-only**: no UPDATE, no DELETE. It represents the immutable history of facts.

---

## Schema

```sql
CREATE TABLE events (
    id         BIGSERIAL PRIMARY KEY,
    type       TEXT NOT NULL,        -- "ItemCreated", "ItemDeleted"
    aggregate  TEXT NOT NULL,        -- "item"
    payload    JSONB NOT NULL,       -- {"id": 1, "name": "foo"}
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX events_type_idx       ON events (type);
CREATE INDEX events_created_at_idx ON events (created_at DESC);
```

Migration runs automatically on startup (`migrate()` in `store/postgres.go`).

---

## API

### `GET /events`

Returns the 100 most recent events (read from the PostgreSQL replica).

**Query params:**
| Parameter | Type   | Default | Description |
|-----------|--------|---------|-------------|
| `type`    | string | —       | Filter by event type (`ItemCreated`, `ItemDeleted`) |
| `limit`   | int    | 100     | Max results (capped at 1000) |

**Examples:**
```bash
# All recent events
curl https://lumen-api.airgap.local/events

# Creations only
curl https://lumen-api.airgap.local/events?type=ItemCreated

# Last 10 deletions
curl https://lumen-api.airgap.local/events?type=ItemDeleted&limit=10
```

**Response:**
```json
[
  {
    "id": 42,
    "type": "ItemCreated",
    "aggregate": "item",
    "payload": {"id": 7, "name": "foo"},
    "created_at": "2026-02-27T14:32:01Z"
  },
  {
    "id": 41,
    "type": "ItemDeleted",
    "aggregate": "item",
    "payload": {"id": 3},
    "created_at": "2026-02-27T14:31:55Z"
  }
]
```

---

## Prometheus Metrics

Counter exposed on `/metrics`:

```
lumen_events_total{type="ItemCreated"} 42
lumen_events_total{type="ItemDeleted"} 7
```

### Useful PromQL queries

```promql
# Item creation rate (per minute)
rate(lumen_events_total{type="ItemCreated"}[5m]) * 60

# Deletion rate (alert on spike)
rate(lumen_events_total{type="ItemDeleted"}[5m])

# Deletion-to-creation ratio
rate(lumen_events_total{type="ItemDeleted"}[5m])
/
rate(lumen_events_total{type="ItemCreated"}[5m])
```

### Example alert

```yaml
# PrometheusRule — alert on abnormal deletion rate
- alert: HighItemDeletionRate
  expr: rate(lumen_events_total{type="ItemDeleted"}[5m]) > 2
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Abnormally high item deletion rate"
```

---

## Observability

### Loki

Every event produces an OTel span and a structured slog log. In Grafana → Loki:

```logql
{namespace="lumen"} | json
```

### Tempo

A `POST /items` trace contains:
```
items.create
  └── db.insert.item   (INSERT items + INSERT events, same tx)
```

The `trace_id` in Loki logs links directly to the corresponding Tempo trace.

---

## Data flow

```
POST /items
  │
  ├── handler (items.go) — span "items.create"
  │     └── pgStore.CreateItem(ctx, name)
  │           ├── tx.Begin()
  │           ├── INSERT INTO items → item{id, name, created_at}
  │           ├── INSERT INTO events (ItemCreated, payload JSON)
  │           ├── tx.Commit()
  │           └── eventsTotal{type="ItemCreated"}.Inc()
  │
  └── HTTP 201 {id, name, created_at}
```

---

## Files

| File | Role |
|------|------|
| [store/postgres.go](../01-connected-zone/app/internal/store/postgres.go) | `Event` struct, `events` table, transactional `CreateItem`/`DeleteItem`, `GetEvents` |
| [handlers/events.go](../01-connected-zone/app/internal/handlers/events.go) | `GET /events` handler with filters and OTel spans |
| [metrics/prometheus.go](../01-connected-zone/app/internal/metrics/prometheus.go) | `lumen_events_total` CounterVec |
| [app/app.go](../01-connected-zone/app/internal/app/app.go) | `GET /events` route + `eventsTotal` injection into `NewPostgresStore` |

---

## Event Log vs Event Sourcing

This pattern is an **Event Log** (simplified Outbox), not full Event Sourcing:

| | Event Log (here) | Full Event Sourcing |
|---|---|---|
| Source of truth | `items` table | `events` table only |
| Reads | `SELECT * FROM items` | Replay all events |
| Complexity | Low | High (projections, snapshots) |
| Audit trail | ✅ Yes | ✅ Yes |
| History replay | Partial | Complete |
| Production usage | Stripe, GitHub outbox | Kafka, EventStoreDB |

This gives **80% of the value** (audit, observability, metrics) for **20% of the complexity**.
