-- Schema created at startup by lumen-api up to v1.6.0. IF NOT EXISTS so that
-- this migration adopts a database created by those versions.

-- +goose Up
CREATE TABLE IF NOT EXISTS items (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS events (
    id         BIGSERIAL PRIMARY KEY,
    type       TEXT NOT NULL,
    aggregate  TEXT NOT NULL,
    payload    JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS events_type_idx ON events (type);
CREATE INDEX IF NOT EXISTS events_created_at_idx ON events (created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS items;
