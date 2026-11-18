-- The events of lumen-api, published to Kafka (issue #44,
-- docs/runbooks/kafka.md).
--
-- outbox: the events to publish. A trigger fills it, so an event and its row
-- commit together, whichever version of lumen-api wrote the event: the
-- previous version still runs during the canary. The relay deletes a row
-- once Kafka has acknowledged the event.
--
-- processed_events, event_counts: what the consumer applied. A redelivered
-- event finds its id in processed_events and changes nothing.

-- +goose Up
CREATE TABLE outbox (
    id         BIGSERIAL PRIMARY KEY,
    event_id   BIGINT NOT NULL UNIQUE REFERENCES events (id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE processed_events (
    event_id     BIGINT PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE event_counts (
    type  TEXT PRIMARY KEY,
    total BIGINT NOT NULL
);

-- +goose StatementBegin
CREATE FUNCTION enqueue_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO outbox (event_id) VALUES (NEW.id);
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER events_outbox AFTER INSERT ON events
    FOR EACH ROW EXECUTE FUNCTION enqueue_event();

-- +goose Down
DROP TRIGGER events_outbox ON events;
DROP FUNCTION enqueue_event();
DROP TABLE event_counts;
DROP TABLE processed_events;
DROP TABLE outbox;
