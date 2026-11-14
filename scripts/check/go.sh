#!/bin/bash
# Go checks: go vet, golangci-lint, tests with -race and coverage against a
# real PostgreSQL and Redis (throwaway containers), coverage floor.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
APP=01-connected-zone/app
# Raise it as tests are added; never lower it to make a change pass
COVERAGE_MIN="${COVERAGE_MIN:-55}"

echo "== golangci-lint"
docker run --rm -v "$PWD/$APP:/src" -w /src "$GOLANGCI_IMAGE" golangci-lint run ./...

id=$$
pg="check-pg-$id" redis="check-redis-$id"
trap 'docker rm -f "$pg" "$redis" >/dev/null 2>&1 || true' EXIT
docker run -d --rm --name "$pg" -p 127.0.0.1::5432 -e POSTGRES_PASSWORD=test "$POSTGRES_IMAGE" >/dev/null
docker run -d --rm --name "$redis" -p 127.0.0.1::6379 "$REDIS_IMAGE" >/dev/null
pg_port=$(docker port "$pg" 5432/tcp | head -1 | cut -d: -f2)
redis_port=$(docker port "$redis" 6379/tcp | head -1 | cut -d: -f2)
for _ in $(seq 60); do docker exec "$pg" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done

echo "== go vet, go test -race with coverage"
# --network host: the containers above publish on the host loopback
docker run --rm --network host -v "$PWD/$APP:/src" -w /src -v lumen-gomodcache:/go/pkg/mod \
  -e LUMEN_TEST_PG_DSN="postgres://postgres:test@127.0.0.1:${pg_port}/postgres?sslmode=disable" \
  -e LUMEN_TEST_REDIS_ADDR="127.0.0.1:${redis_port}" \
  -e GITHUB_STEP_SUMMARY=/summary -v "${GITHUB_STEP_SUMMARY:-/dev/null}:/summary" \
  -v "$PWD/scripts/check:/check:ro" "$GO_IMAGE" sh -c "
    go vet ./... &&
    go test -race -count=1 -p 1 -coverpkg=./... -coverprofile=/tmp/cover.out ./... &&
    /check/coverage.sh /tmp/cover.out $COVERAGE_MIN"
