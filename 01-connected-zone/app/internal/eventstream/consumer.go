package eventstream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
)

const consumeBackoff = 2 * time.Second

// Client is the part of the Kafka client the consumer uses.
type Client interface {
	Producer
	PollFetches(ctx context.Context) kgo.Fetches
	CommitRecords(ctx context.Context, rs ...*kgo.Record) error
}

// Consumer applies the events of the topic to event_counts.
type Consumer struct {
	db         *pgxpool.Pool
	client     Client
	deadLetter string
	metrics    *Metrics
}

// NewConsumer returns a consumer that sends the messages it cannot read to
// the topic deadLetter.
func NewConsumer(db *pgxpool.Pool, client Client, deadLetter string, metrics *Metrics) *Consumer {
	return &Consumer{db: db, client: client, deadLetter: deadLetter, metrics: metrics}
}

// ConsumerOptions are the options of the consumer's Kafka client: offsets are
// committed by hand, after the records are applied. A group with no valid
// offset, as after a topic is rebuilt, starts from the beginning.
func ConsumerOptions(cfg Config) []kgo.Opt {
	return []kgo.Opt{
		kgo.ConsumerGroup(cfg.Group),
		kgo.ConsumeTopics(cfg.Topic),
		kgo.DisableAutoCommit(),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
	}
}

// Run consumes until ctx is done. A topic deleted and created again has a new
// id, which the client does not pick up (measured on k3d: every fetch fails
// until it restarts): Run returns, and the pod starts again.
func (c *Consumer) Run(ctx context.Context) error {
	for ctx.Err() == nil {
		fetches := c.client.PollFetches(ctx)
		var recreated error
		fetches.EachError(func(topic string, partition int32, err error) {
			switch {
			case errors.Is(err, kerr.UnknownTopicID):
				recreated = fmt.Errorf("topic %s was recreated: %w", topic, err)
			case !errors.Is(err, context.Canceled):
				slog.Warn("Consumer: fetch failed", "topic", topic, "partition", partition, "error", err)
			}
		})
		if recreated != nil {
			return recreated
		}
		records := fetches.Records()
		for _, r := range records {
			if err := c.Handle(ctx, r); err != nil {
				return nil // ctx is done: the records are delivered again
			}
		}
		if len(records) == 0 {
			continue
		}
		if err := c.client.CommitRecords(ctx, records...); err != nil && ctx.Err() == nil {
			slog.Warn("Consumer: commit failed, the records will be delivered again", "error", err)
		}
	}
	return nil
}

// Handle applies one record, retrying until it succeeds or ctx is done. A
// message that cannot be read goes to the dead letter topic: retrying it
// would block its partition for good.
func (c *Consumer) Handle(ctx context.Context, r *kgo.Record) error {
	m, err := decode(r.Value)
	step := func(ctx context.Context) (string, error) {
		return c.apply(ctx, m)
	}
	if err != nil {
		reason := err
		step = func(ctx context.Context) (string, error) {
			return "dead_lettered", c.sendDeadLetter(ctx, r, reason)
		}
	}
	for {
		result, err := step(ctx)
		if err == nil {
			c.metrics.Consumed.WithLabelValues(result).Inc()
			return nil
		}
		c.metrics.ConsumeErrors.Inc()
		slog.Warn("Consumer: failed, retrying", "partition", r.Partition, "offset", r.Offset, "error", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(consumeBackoff):
		}
	}
}

func decode(value []byte) (Message, error) {
	var m Message
	if err := json.Unmarshal(value, &m); err != nil {
		return m, fmt.Errorf("invalid JSON: %w", err)
	}
	if m.EventID <= 0 || m.Type == "" {
		return m, errors.New("missing event_id or type")
	}
	return m, nil
}

// apply counts the event once: the event id and the count commit together.
func (c *Consumer) apply(ctx context.Context, m Message) (string, error) {
	tx, err := c.db.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	tag, err := tx.Exec(ctx, `INSERT INTO processed_events (event_id) VALUES ($1) ON CONFLICT DO NOTHING`, m.EventID)
	if err != nil {
		return "", err
	}
	result := "duplicate"
	if tag.RowsAffected() == 1 {
		result = "applied"
		_, err = tx.Exec(ctx, `
			INSERT INTO event_counts (type, total) VALUES ($1, 1)
			ON CONFLICT (type) DO UPDATE SET total = event_counts.total + 1`, m.Type)
		if err != nil {
			return "", err
		}
	}
	return result, tx.Commit(ctx)
}

func (c *Consumer) sendDeadLetter(ctx context.Context, r *kgo.Record, reason error) error {
	dead := &kgo.Record{
		Topic: c.deadLetter,
		Key:   r.Key,
		Value: r.Value,
		Headers: []kgo.RecordHeader{
			{Key: "error", Value: []byte(reason.Error())},
			{Key: "source-topic", Value: []byte(r.Topic)},
			{Key: "source-partition", Value: []byte(strconv.Itoa(int(r.Partition)))},
			{Key: "source-offset", Value: []byte(strconv.FormatInt(r.Offset, 10))},
		},
	}
	produceCtx, cancel := context.WithTimeout(ctx, produceTimeout)
	defer cancel()
	return c.client.ProduceSync(produceCtx, dead).FirstErr()
}
