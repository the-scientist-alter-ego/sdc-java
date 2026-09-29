#!/usr/bin/env bash
set -euo pipefail

echo "Checking service health..."
for port in 8080 8081 8082; do
  curl --fail --silent "http://localhost:${port}/actuator/health" > /dev/null
  echo "Port ${port}: healthy"
done

test_log_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "Submitting event ${test_log_id} through the gateway..."

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

http_code=$(curl --silent --show-error \
  --output "$response_file" \
  --write-out '%{http_code}' \
  -X POST http://localhost:8080/api/logs \
  -H 'Content-Type: application/json' \
  -d "{
    \"id\": \"${test_log_id}\",
    \"organizationId\": \"test-org\",
    \"level\": \"INFO\",
    \"message\": \"Integration test message\",
    \"source\": \"integration-test\"
  }")

if [[ "$http_code" != "200" ]] ||
   ! grep -Fq "\"id\":\"${test_log_id}\"" "$response_file" ||
   ! grep -Fq '"status":"success"' "$response_file"; then
  echo "POST failed (HTTP ${http_code}):"
  cat "$response_file"
  exit 1
fi

echo "Kafka acknowledged the event. Waiting for its PostgreSQL row..."

for attempt in {1..20}; do
  row_count=$(docker compose exec -T postgres \
    psql -U loguser -d logprocessor -t -A \
    -c "SELECT COUNT(*) FROM log_events WHERE id = '${test_log_id}';" |
    tr -d '[:space:]')

  if [[ "$row_count" == "1" ]]; then
    echo "PASS: event ${test_log_id} reached PostgreSQL."
    exit 0
  fi

  sleep 1
done

echo "FAIL: event ${test_log_id} was acknowledged by Kafka but no PostgreSQL row appeared within 20 seconds."
echo "Check the log-consumer terminal for deserialization, retry, or database errors."
exit 1
