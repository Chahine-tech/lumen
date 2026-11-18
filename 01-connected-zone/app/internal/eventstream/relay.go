package eventstream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
)

const (
	// relayLock is the advisory lock of the active relay. One replica
	// publishes at a time: two would interleave batches and could reorder
	// the events of an item. The others take over at the next poll.
	relayLock int64 = 44_0001

	relayBatch     = 100
	relayPoll      = 500 * time.Millisecond
	relayBackoff   = 2 * time.Second
	produceTimeout = 30 * time.Second
)

// Message is the value of a Kafka record.
type Message struct {
	EventID   int64           `json:"event_id"`
	Type      string          `json:"type"`
	Aggregate string          `json:"aggregate"`
	Payload   json.RawMessage `json:"payload"`
	Actor     *string         `json:"actor"`
	CreatedAt time.Time       `json:"created_at"`
}

// recordKey keeps the events of one aggregate in one partition, in order.
func recordKey(m Message) string {
	var p struct {
		ID json.Number `json:"id"`
	}
	if err := json.Unmarshal(m.Payload, &p); err != nil || p.ID == "" {
		return m.Aggregate
	}
	return m.Aggregate + ":" + p.ID.String()
}

// Producer is the part of the Kafka client the relay uses.
type Producer interface {
	ProduceSync(ctx context.Context, rs ...*kgo.Record) kgo.ProduceResults
}

// Relay publishes the outbox to Kafka.
type Relay struct {
	db       *pgxpool.Pool
	producer Producer
	topic    string
	metrics  *Metrics
}

// NewRelay returns a relay that publishes to topic.
func NewRelay(db *pgxpool.Pool, producer Producer, topic string, metrics *Metrics) *Relay {
	return &Relay{db: db, producer: producer, topic: topic, metrics: metrics}
}

// NewKafkaClient returns a client that waits for every in-sync replica.
func NewKafkaClient(cfg Config, extra ...kgo.Opt) (*kgo.Client, error) {
	opts, err := cfg.clientOptions()
	if err != nil {
		return nil, err
	}
	opts = append(opts, kgo.RequiredAcks(kgo.AllISRAcks()))
	return kgo.NewClient(append(opts, extra...)...)
}

// Run publishes until ctx is done. A failure of PostgreSQL or Kafka is
// retried: the events wait in the outbox. A topic deleted and created again
// has a new id, which the client does not pick up (measured on k3d: every
// produce fails until it restarts): Run returns, and the pod starts again.
func (r *Relay) Run(ctx context.Context) error {
	for ctx.Err() == nil {
		n, err := r.PublishBatch(ctx)
		if errors.Is(err, kerr.UnknownTopicID) {
			return fmt.Errorf("topic %s was recreated: %w", r.topic, err)
		}
		if err != nil && ctx.Err() == nil {
			r.metrics.PublishErrors.Inc()
			slog.Warn("Outbox: publication failed, retrying", "error", err)
		}
		if err := r.measure(ctx); err != nil && ctx.Err() == nil {
			slog.Warn("Outbox: measure failed", "error", err)
		}
		wait := relayPoll
		switch {
		case err != nil:
			wait = relayBackoff
		case n == relayBatch:
			continue // more to publish
		}
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
	}
	return nil
}

// PublishBatch publishes the oldest events of the outbox and deletes their
// rows once Kafka has acknowledged all of them. It returns how many were
// published: 0 when the outbox is empty or another replica is active.
//
// A crash between the acknowledgement and the commit publishes the batch
// again. The consumer ignores the events it has already applied.
func (r *Relay) PublishBatch(ctx context.Context) (int, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var active bool
	if err := tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock($1)`, relayLock).Scan(&active); err != nil {
		return 0, fmt.Errorf("relay lock: %w", err)
	}
	if !active {
		r.metrics.RelayActive.Set(0)
		return 0, nil
	}
	r.metrics.RelayActive.Set(1)

	ids, records, err := r.readBatch(ctx, tx)
	if err != nil || len(records) == 0 {
		return 0, err
	}

	produceCtx, cancel := context.WithTimeout(ctx, produceTimeout)
	defer cancel()
	if err := r.producer.ProduceSync(produceCtx, records...).FirstErr(); err != nil {
		return 0, fmt.Errorf("produce: %w", err)
	}

	if _, err := tx.Exec(ctx, `DELETE FROM outbox WHERE id = ANY($1)`, ids); err != nil {
		return 0, fmt.Errorf("delete: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	r.metrics.Published.Add(float64(len(records)))
	return len(records), nil
}

func (r *Relay) readBatch(ctx context.Context, tx pgx.Tx) ([]int64, []*kgo.Record, error) {
	rows, err := tx.Query(ctx, `
		SELECT o.id, e.id, e.type, e.aggregate, e.payload, e.actor, e.created_at
		FROM outbox o JOIN events e ON e.id = o.event_id
		ORDER BY o.id
		LIMIT $1
		FOR UPDATE OF o`, relayBatch)
	if err != nil {
		return nil, nil, fmt.Errorf("read outbox: %w", err)
	}
	defer rows.Close()

	var ids []int64
	var records []*kgo.Record
	for rows.Next() {
		var id int64
		var m Message
		if err := rows.Scan(&id, &m.EventID, &m.Type, &m.Aggregate, &m.Payload, &m.Actor, &m.CreatedAt); err != nil {
			return nil, nil, fmt.Errorf("read outbox: %w", err)
		}
		value, err := json.Marshal(m)
		if err != nil {
			return nil, nil, fmt.Errorf("encode event %d: %w", m.EventID, err)
		}
		ids = append(ids, id)
		records = append(records, &kgo.Record{Topic: r.topic, Key: []byte(recordKey(m)), Value: value})
	}
	return ids, records, rows.Err()
}

func (r *Relay) measure(ctx context.Context) error {
	var pending int64
	var age float64
	err := r.db.QueryRow(ctx, `
		SELECT count(*), COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)), 0)::float8
		FROM outbox`).Scan(&pending, &age)
	if err != nil {
		return err
	}
	r.metrics.OutboxPending.Set(float64(pending))
	r.metrics.OutboxOldestAge.Set(age)
	return nil
}

// rebuildTimeout bounds the retries of Rebuild. A new pod cannot connect for
// its first seconds, until its NetworkPolicies are programmed (measured on
// k3d: connection refused at once).
var rebuildTimeout = time.Minute

// Rebuild queues every event of the events table again, to restore a lost
// topic. It returns how many were queued; an event still in the outbox is
// not queued twice.
func Rebuild(ctx context.Context, db *pgxpool.Pool) (int64, error) {
	deadline := time.Now().Add(rebuildTimeout)
	for {
		tag, err := db.Exec(ctx, `
			INSERT INTO outbox (event_id)
			SELECT id FROM events ORDER BY id
			ON CONFLICT (event_id) DO NOTHING`)
		if err == nil {
			return tag.RowsAffected(), nil
		}
		if time.Now().After(deadline) {
			return 0, err
		}
		slog.Warn("Outbox: rebuild failed, retrying", "error", err)
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(relayBackoff):
		}
	}
}
