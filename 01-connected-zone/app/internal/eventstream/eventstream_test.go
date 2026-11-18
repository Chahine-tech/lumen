package eventstream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Chahine-tech/lumen/internal/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
)

// Integration tests against a real PostgreSQL and an in-memory Kafka (kfake).
// Skipped unless LUMEN_TEST_PG_DSN points to a server where the test may
// create and drop the database lumen_test_eventstream.
func newTestDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("LUMEN_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("LUMEN_TEST_PG_DSN not set")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	const name = "lumen_test_eventstream"
	for _, q := range []string{"DROP DATABASE IF EXISTS " + name + " WITH (FORCE)", "CREATE DATABASE " + name} {
		if _, err := admin.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	i := strings.LastIndex(dsn, "/")
	dbDSN := dsn[:i+1] + name
	if j := strings.Index(dsn[i:], "?"); j >= 0 {
		dbDSN += dsn[i+j:]
	}
	if err := migrations.Up(ctx, dbDSN, migrations.Files(), ""); err != nil {
		t.Fatal(err)
	}
	db, err := pgxpool.New(ctx, dbDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	return db
}

func newTestKafka(t *testing.T) []string {
	t.Helper()
	cluster, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(3, "events", "dead"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cluster.Close)
	return cluster.ListenAddrs()
}

func newTestClient(t *testing.T, brokers []string, opts ...kgo.Opt) *kgo.Client {
	t.Helper()
	client, err := kgo.NewClient(append([]kgo.Opt{kgo.SeedBrokers(brokers...)}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

func insertEvent(t *testing.T, db *pgxpool.Pool, typ string, id int) int64 {
	t.Helper()
	var eventID int64
	err := db.QueryRow(context.Background(),
		`INSERT INTO events (type, aggregate, payload, actor) VALUES ($1, 'item', $2, 'test') RETURNING id`,
		typ, fmt.Sprintf(`{"id": %d}`, id)).Scan(&eventID)
	if err != nil {
		t.Fatal(err)
	}
	return eventID
}

func count(t *testing.T, db *pgxpool.Pool, query string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := db.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// readAll reads n records of topic from the beginning.
func readAll(t *testing.T, brokers []string, topic string, n int) []*kgo.Record {
	t.Helper()
	client := newTestClient(t, brokers, kgo.ConsumeTopics(topic), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var records []*kgo.Record
	for len(records) < n {
		fetches := client.PollFetches(ctx)
		if ctx.Err() != nil {
			t.Fatalf("read %d records of %s, want %d", len(records), topic, n)
		}
		records = append(records, fetches.Records()...)
	}
	return records
}

func testMetrics() *Metrics { return NewMetrics(prometheus.NewRegistry()) }

// The trigger ties the outbox row to the transaction of the event.
func TestOutboxFollowsTheTransaction(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	id := insertEvent(t, db, "ItemCreated", 1)
	if n := count(t, db, `SELECT count(*) FROM outbox WHERE event_id = $1`, id); n != 1 {
		t.Fatalf("outbox rows after commit = %d, want 1", n)
	}

	tx, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO events (type, aggregate, payload) VALUES ('ItemCreated', 'item', '{}')`); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if n := count(t, db, `SELECT count(*) FROM outbox`); n != 1 {
		t.Fatalf("outbox rows after rollback = %d, want 1", n)
	}
}

func TestRelayPublishesThenDeletes(t *testing.T) {
	db := newTestDB(t)
	brokers := newTestKafka(t)
	first := insertEvent(t, db, "ItemCreated", 7)
	insertEvent(t, db, "ItemDeleted", 7)

	metrics := testMetrics()
	relay := NewRelay(db, newTestClient(t, brokers), "events", metrics)
	n, err := relay.PublishBatch(context.Background())
	if err != nil || n != 2 {
		t.Fatalf("PublishBatch = %d, %v, want 2", n, err)
	}
	if left := count(t, db, `SELECT count(*) FROM outbox`); left != 0 {
		t.Fatalf("outbox rows = %d, want 0", left)
	}

	records := readAll(t, brokers, "events", 2)
	if records[0].Partition != records[1].Partition {
		t.Fatalf("events of one item in partitions %d and %d", records[0].Partition, records[1].Partition)
	}
	if string(records[0].Key) != "item:7" {
		t.Fatalf("key = %q, want item:7", records[0].Key)
	}
	var m Message
	if err := json.Unmarshal(records[0].Value, &m); err != nil {
		t.Fatal(err)
	}
	if m.EventID != first || m.Type != "ItemCreated" {
		t.Fatalf("first message = %+v, want event %d ItemCreated", m, first)
	}
	if got := testutil.ToFloat64(metrics.Published); got != 2 {
		t.Fatalf("published metric = %v, want 2", got)
	}
}

type failingProducer struct{ err error }

func (p failingProducer) ProduceSync(_ context.Context, rs ...*kgo.Record) kgo.ProduceResults {
	results := make(kgo.ProduceResults, 0, len(rs))
	for _, r := range rs {
		results = append(results, kgo.ProduceResult{Record: r, Err: p.err})
	}
	return results
}

// Kafka down: the event stays in the outbox, nothing is lost.
func TestRelayKeepsRowsWhenKafkaFails(t *testing.T) {
	db := newTestDB(t)
	insertEvent(t, db, "ItemCreated", 1)

	relay := NewRelay(db, failingProducer{err: errors.New("no broker")}, "events", testMetrics())
	if _, err := relay.PublishBatch(context.Background()); err == nil {
		t.Fatal("PublishBatch succeeded, want the producer's error")
	}
	if n := count(t, db, `SELECT count(*) FROM outbox`); n != 1 {
		t.Fatalf("outbox rows = %d, want 1", n)
	}
}

// A recreated topic has a new id: the relay stops, and the pod starts again
// with a new client. Any other error is retried.
func TestRelayStopsWhenTheTopicWasRecreated(t *testing.T) {
	db := newTestDB(t)
	insertEvent(t, db, "ItemCreated", 1)

	relay := NewRelay(db, failingProducer{err: kerr.UnknownTopicID}, "events", testMetrics())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := relay.Run(ctx); !errors.Is(err, kerr.UnknownTopicID) {
		t.Fatalf("Run = %v, want UNKNOWN_TOPIC_ID", err)
	}
	if n := count(t, db, `SELECT count(*) FROM outbox`); n != 1 {
		t.Fatalf("outbox rows = %d, want 1", n)
	}

	other := NewRelay(db, failingProducer{err: errors.New("no broker")}, "events", testMetrics())
	short, stop := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer stop()
	if err := other.Run(short); err != nil {
		t.Fatalf("Run = %v, want a retry until the context ends", err)
	}
}

// One replica publishes at a time.
func TestRelayStandbyPublishesNothing(t *testing.T) {
	db := newTestDB(t)
	brokers := newTestKafka(t)
	insertEvent(t, db, "ItemCreated", 1)
	ctx := context.Background()

	tx, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, relayLock); err != nil {
		t.Fatal(err)
	}

	metrics := testMetrics()
	relay := NewRelay(db, newTestClient(t, brokers), "events", metrics)
	if n, err := relay.PublishBatch(ctx); err != nil || n != 0 {
		t.Fatalf("standby PublishBatch = %d, %v, want 0", n, err)
	}
	if got := testutil.ToFloat64(metrics.RelayActive); got != 0 {
		t.Fatalf("active metric = %v, want 0", got)
	}

	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if n, err := relay.PublishBatch(ctx); err != nil || n != 1 {
		t.Fatalf("PublishBatch after the lock is free = %d, %v, want 1", n, err)
	}
}

func TestRebuildQueuesEveryEventOnce(t *testing.T) {
	db := newTestDB(t)
	brokers := newTestKafka(t)
	insertEvent(t, db, "ItemCreated", 1)
	relay := NewRelay(db, newTestClient(t, brokers), "events", testMetrics())
	if _, err := relay.PublishBatch(context.Background()); err != nil {
		t.Fatal(err)
	}
	insertEvent(t, db, "ItemCreated", 2) // still in the outbox

	n, err := Rebuild(context.Background(), db)
	if err != nil || n != 1 {
		t.Fatalf("Rebuild = %d, %v, want 1 (the published event)", n, err)
	}
	if left := count(t, db, `SELECT count(*) FROM outbox`); left != 2 {
		t.Fatalf("outbox rows = %d, want 2", left)
	}
}

// A pod that just started cannot connect yet: Rebuild retries, then gives up.
func TestRebuildGivesUpAfterItsTimeout(t *testing.T) {
	db := newTestDB(t)
	db.Close()
	previous := rebuildTimeout
	rebuildTimeout = 3 * time.Second
	t.Cleanup(func() { rebuildTimeout = previous })

	start := time.Now()
	if _, err := Rebuild(context.Background(), db); err == nil {
		t.Fatal("Rebuild succeeded on a closed pool")
	}
	if elapsed := time.Since(start); elapsed < rebuildTimeout {
		t.Fatalf("gave up after %s, want at least %s", elapsed, rebuildTimeout)
	}
}

func eventRecord(t *testing.T, id int64, typ string) *kgo.Record {
	t.Helper()
	value, err := json.Marshal(Message{EventID: id, Type: typ, Aggregate: "item", Payload: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	return &kgo.Record{Topic: "events", Value: value}
}

func TestConsumerAppliesARedeliveredEventOnce(t *testing.T) {
	db := newTestDB(t)
	metrics := testMetrics()
	consumer := NewConsumer(db, nil, "dead", metrics)
	ctx := context.Background()

	for range 3 {
		if err := consumer.Handle(ctx, eventRecord(t, 42, "ItemCreated")); err != nil {
			t.Fatal(err)
		}
	}
	if err := consumer.Handle(ctx, eventRecord(t, 43, "ItemCreated")); err != nil {
		t.Fatal(err)
	}
	if n := count(t, db, `SELECT total FROM event_counts WHERE type = 'ItemCreated'`); n != 2 {
		t.Fatalf("count = %d, want 2", n)
	}
	if got := testutil.ToFloat64(metrics.Consumed.WithLabelValues("duplicate")); got != 2 {
		t.Fatalf("duplicates = %v, want 2", got)
	}
}

func TestConsumerSendsUnreadableMessagesToTheDeadLetterTopic(t *testing.T) {
	db := newTestDB(t)
	brokers := newTestKafka(t)
	metrics := testMetrics()
	consumer := NewConsumer(db, newTestClient(t, brokers), "dead", metrics)

	for _, value := range []string{"not json", `{"type":"ItemCreated"}`} {
		r := &kgo.Record{Topic: "events", Partition: 2, Offset: 9, Value: []byte(value)}
		if err := consumer.Handle(context.Background(), r); err != nil {
			t.Fatal(err)
		}
	}
	dead := readAll(t, brokers, "dead", 2)
	headers := map[string]string{}
	for _, h := range dead[0].Headers {
		headers[h.Key] = string(h.Value)
	}
	if headers["source-topic"] != "events" || headers["source-partition"] != "2" || headers["source-offset"] != "9" || headers["error"] == "" {
		t.Fatalf("headers = %v", headers)
	}
	if n := count(t, db, `SELECT count(*) FROM processed_events`); n != 0 {
		t.Fatalf("processed events = %d, want 0", n)
	}
}

// A database failure is retried, not dead-lettered: the event is valid.
func TestConsumerRetriesUntilCancelledWhenTheDatabaseFails(t *testing.T) {
	db := newTestDB(t)
	db.Close()
	metrics := testMetrics()
	consumer := NewConsumer(db, nil, "dead", metrics)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	if err := consumer.Handle(ctx, eventRecord(t, 1, "ItemCreated")); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Handle = %v, want the context's error", err)
	}
	if got := testutil.ToFloat64(metrics.ConsumeErrors); got == 0 {
		t.Fatal("no error counted")
	}
}

// End to end through the group: the offsets are committed, and a new consumer
// of the same group has nothing left to apply.
func TestConsumerRunCommitsOffsets(t *testing.T) {
	db := newTestDB(t)
	brokers := newTestKafka(t)
	producer := newTestClient(t, brokers)
	ctx := context.Background()
	if err := producer.ProduceSync(ctx, eventRecord(t, 1, "ItemCreated"), eventRecord(t, 2, "ItemDeleted")).FirstErr(); err != nil {
		t.Fatal(err)
	}

	cfg := Config{Group: "group", Topic: "events"}
	run := func(metrics *Metrics, until func() bool) {
		t.Helper()
		client := newTestClient(t, brokers, ConsumerOptions(cfg)...)
		runCtx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() { done <- NewConsumer(db, client, "dead", metrics).Run(runCtx) }()
		deadline := time.Now().Add(10 * time.Second)
		for !until() && time.Now().Before(deadline) {
			time.Sleep(50 * time.Millisecond)
		}
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		client.Close()
	}

	first := testMetrics()
	run(first, func() bool { return count(t, db, `SELECT count(*) FROM processed_events`) == 2 })
	if n := count(t, db, `SELECT count(*) FROM processed_events`); n != 2 {
		t.Fatalf("processed = %d, want 2", n)
	}
	time.Sleep(200 * time.Millisecond)

	second := testMetrics()
	stop := time.Now().Add(2 * time.Second)
	run(second, func() bool { return time.Now().After(stop) })
	if got := testutil.ToFloat64(second.Consumed.WithLabelValues("duplicate")); got != 0 {
		t.Fatalf("records delivered again after the commit = %v, want 0", got)
	}
}

type recreatedTopicClient struct{ Client }

func (recreatedTopicClient) PollFetches(context.Context) kgo.Fetches {
	return kgo.Fetches{{Topics: []kgo.FetchTopic{{
		Topic:      "events",
		Partitions: []kgo.FetchPartition{{Partition: 0, Err: kerr.UnknownTopicID}},
	}}}}
}

// A recreated topic has a new id: the consumer stops, and the pod starts again
// with a new client.
func TestConsumerStopsWhenTheTopicWasRecreated(t *testing.T) {
	consumer := NewConsumer(nil, recreatedTopicClient{}, "dead", testMetrics())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := consumer.Run(ctx); !errors.Is(err, kerr.UnknownTopicID) {
		t.Fatalf("Run = %v, want UNKNOWN_TOPIC_ID", err)
	}
}

func TestConfigFromEnv(t *testing.T) {
	t.Setenv("PG_DSN", "")
	t.Setenv("KAFKA_BROKERS", "")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("no error without PG_DSN")
	}
	t.Setenv("PG_DSN", "postgres://x")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("no error without KAFKA_BROKERS")
	}
	t.Setenv("KAFKA_BROKERS", "a:9093,b:9093")
	cfg, err := ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Brokers) != 2 || cfg.Topic != "lumen.events" || cfg.AdminAddr != ":9090" {
		t.Fatalf("config = %+v", cfg)
	}
}

func TestTLSConfigRefusesMissingFiles(t *testing.T) {
	if _, err := (Config{CAFile: "/nonexistent"}).clientOptions(); err == nil {
		t.Fatal("no error for a missing CA file")
	}
	ca := t.TempDir() + "/ca.crt"
	if err := os.WriteFile(ca, []byte("not a certificate"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := (Config{CAFile: ca}).clientOptions(); err == nil {
		t.Fatal("no error for an invalid CA file")
	}
}

func TestRecordKey(t *testing.T) {
	for payload, want := range map[string]string{`{"id": 12}`: "item:12", `{}`: "item", `[]`: "item"} {
		if got := recordKey(Message{Aggregate: "item", Payload: json.RawMessage(payload)}); got != want {
			t.Errorf("recordKey(%s) = %q, want %q", payload, got, want)
		}
	}
}
