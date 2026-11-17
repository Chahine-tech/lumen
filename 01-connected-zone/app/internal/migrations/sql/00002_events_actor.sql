-- The caller that performed the action (issue #18): "<issuer>:<caller>", or
-- "anonymous" when authentication runs in report mode. Nullable: the rows
-- written before have none, and the previous version, which still runs
-- during the canary, inserts events without it (expand and contract,
-- docs/databases.md).

-- +goose Up
ALTER TABLE events ADD COLUMN actor TEXT;

-- +goose Down
ALTER TABLE events DROP COLUMN actor;
