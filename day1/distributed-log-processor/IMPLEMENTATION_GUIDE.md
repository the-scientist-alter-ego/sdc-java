## Implementation Guide : Building Production-Ready Distributed Log Processing Infrastructure

This guide covers how to build, run, observe, and verify the Day 1 distributed log processing system (API gateway, log producer, log consumer, Kafka, Redis, PostgreSQL, Prometheus, Grafana). All commands assume you are in the project root directory (the folder containing `docker-compose.yml` and `pom.xml`).

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Java JDK | 11+ (17 fine) | Build / run Spring Boot modules |
| Maven | 3.6+ | Compile and run services |
| Docker | 24+ | Run Kafka, Postgres, Redis, Prometheus, Grafana |
| Docker Compose | v2+ | Orchestrate infrastructure |
| curl | any | Health checks, API calls, load tests |

**Stack in this repo:** Java 11 / Spring Boot **2.7.x** (follow the project `pom.xml`, not older article snippets that may show Java 17 / Boot 3.x).

Ensure these ports are free before starting: **8080**, **8081**, **8082**, **2181**, **3000**, **5433**, **6379**, **9090**, **9092**.

> PostgreSQL is published on host port **5433** (container 5432) so it does not clash with a local Postgres on 5432.

---

### Project layout

```
.
├── pom.xml                          # Parent Maven POM
├── docker-compose.yml               # Kafka, Zookeeper, Redis, Postgres, Prometheus, Grafana
├── cleanup.sh                       # Stop stack + prune Docker + remove target/
├── load-test.sh                     # Send 100 log events via API gateway
├── integration-tests/
│   └── system-integration-test.sh   # Health + e2e submit + metrics checks
├── api-gateway/                     # Spring Cloud Gateway (port 8080)
├── log-producer/                    # Ingest API → Kafka (port 8081)
├── log-consumer/                    # Kafka → PostgreSQL (port 8082)
└── monitoring/                      # Prometheus + Grafana provisioning
```

---

### Way 1 — Infrastructure with Docker Compose + apps with Maven (recommended)

```bash
chmod +x cleanup.sh load-test.sh integration-tests/system-integration-test.sh

# 1. Start infrastructure
docker compose up -d

# 2. Wait for Kafka, then create the log topic (once)
docker compose exec kafka kafka-topics --create \
  --topic log-events \
  --bootstrap-server localhost:9092 \
  --partitions 6 \
  --replication-factor 1 \
  --if-not-exists

# 3. Start the three Spring Boot apps (three terminals)
cd log-producer && mvn spring-boot:run
cd log-consumer && mvn spring-boot:run
cd api-gateway && mvn spring-boot:run
```

Startup order tip: consumer first (or any order is fine if Kafka is up), then producer, then gateway.

---

### Way 2 — Fully manual (same as Way 1, with explicit waits)

```bash
docker compose up -d

# Wait until Postgres answers (host port 5433)
until docker compose exec -T postgres pg_isready -U loguser; do sleep 2; done

# Wait until Kafka accepts admin commands
until docker compose exec -T kafka kafka-topics --bootstrap-server localhost:9092 --list >/dev/null 2>&1; do sleep 5; done

docker compose exec kafka kafka-topics --create \
  --topic log-events \
  --bootstrap-server localhost:9092 \
  --partitions 6 \
  --replication-factor 1 \
  --if-not-exists

mvn -pl log-producer,log-consumer,api-gateway -am package -DskipTests

# Then run each module with spring-boot:run as in Way 1
```

---

### Way 3 — Scripted verification and load

With all three apps healthy:

```bash
./integration-tests/system-integration-test.sh
./load-test.sh
```

`load-test.sh` posts 100 events to `http://localhost:8080/api/logs` and waits for the gateway health endpoint first.

---

### Way 4 — Unit / module tests only

```bash
mvn clean test
```

---

### Stopping and cleaning up

| Action | Command |
|--------|---------|
| Stop infrastructure (keep volumes) | `docker compose down` |
| Stop + remove volumes + prune dangling Docker + delete `target/` | `./cleanup.sh` |
| Aggressive unused Docker wipe | `./cleanup.sh --full` |

```bash
chmod +x cleanup.sh
./cleanup.sh
```

Also stop any local `mvn spring-boot:run` processes (Ctrl+C in those terminals) before or after cleanup.

---

### Viewing output

#### Service health

```bash
curl http://localhost:8080/actuator/health   # API gateway
curl http://localhost:8081/actuator/health   # Log producer
curl http://localhost:8082/actuator/health   # Log consumer (includes DB)
```

Expect JSON with `"status":"UP"`. Consumer health should show a healthy `db` component when Postgres is reachable.

#### Submit a log event

```bash
curl -s -X POST http://localhost:8080/api/logs \
  -H "Content-Type: application/json" \
  -d '{
    "organizationId": "my-org",
    "level": "INFO",
    "message": "Application started successfully",
    "source": "my-service"
  }'
```

Expected response shape:

```json
{
  "status": "success",
  "id": "uuid-generated-id",
  "message": "Log event queued for processing"
}
```

#### Confirm persistence in PostgreSQL

```bash
docker compose exec -T postgres \
  psql -U loguser -d logprocessor \
  -c 'SELECT id, level, message, source FROM log_events ORDER BY timestamp DESC LIMIT 5;'
```

(Table/column names may vary slightly with Hibernate naming; use `\dt` inside `psql` if needed.)

#### Prometheus metrics

```bash
curl -s http://localhost:8081/actuator/prometheus | grep -E 'log_events_'
curl -s http://localhost:8082/actuator/prometheus | grep -E 'log_events_'
```

Useful names: `log_events_received_total`, `log_events_processed_total`, `log_events_errors_total`.

Open Prometheus UI: http://localhost:9090

#### Grafana

| Item | Value |
|------|-------|
| URL | http://localhost:3000 |
| Login | `admin` / `admin` (local demo credentials) |

After `./load-test.sh`, refresh dashboards under the provisioned log-processing folder.

#### Application logs

Watch each Maven terminal, or:

```bash
docker compose logs -f kafka
docker compose logs -f postgres
docker compose logs -f redis
```

---

### Success criteria

Use this checklist to confirm the system is working correctly.

#### Startup

- [ ] `docker compose ps` shows kafka, zookeeper, redis, postgres, prometheus, grafana as running
- [ ] `curl http://localhost:8080/actuator/health` → `"status":"UP"`
- [ ] `curl http://localhost:8081/actuator/health` → `"status":"UP"`
- [ ] `curl http://localhost:8082/actuator/health` → `"status":"UP"` with DB up
- [ ] Kafka topic `log-events` exists (`docker compose exec kafka kafka-topics --bootstrap-server localhost:9092 --list`)

#### End-to-end processing

- [ ] POST `/api/logs` returns `"status":"success"` and an `id`
- [ ] Row for that event appears in PostgreSQL within a few seconds
- [ ] `./integration-tests/system-integration-test.sh` reports healthy services and a successful submit
- [ ] `./load-test.sh` completes and prints that 100 events were sent

#### Observability

- [ ] Prometheus scrapes / UI at http://localhost:9090 is reachable
- [ ] Grafana at http://localhost:3000 accepts `admin` / `admin`
- [ ] Producer/consumer Prometheus endpoints expose `log_events_*` counters after traffic

#### Architecture expectations (after load)

| Metric / check | Target |
|----------------|--------|
| Successful POST rate under `./load-test.sh` | ~100 accepted events |
| Consumer DB rows | Increases after load (not stuck at zero) |
| Gateway / producer / consumer health | Stay `UP` during load |
| Auth / secrets | Only demo DB password (`logpassword`); no real API keys in repo |

---

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `password authentication failed for user "loguser"` | Another Postgres on host **5432** stealing connections | This project uses **5433**; confirm `application.yml` URL and `docker compose ps` port mapping |
| Producer compile: `CircuitBreaker` package missing | Missing Resilience4j deps | Ensure `log-producer/pom.xml` has `resilience4j-spring-boot2` **1.7.0** and `spring-boot-starter-aop` |
| Producer fails with Resilience4j `NoSuchMethodError` | Version mismatch (e.g. 1.7.1 vs Spring Cloud 1.7.0) | Pin `resilience4j-spring-boot2` to **1.7.0** |
| Port already in use | Previous stack or local Java still running | Stop Maven apps; run `./cleanup.sh` |
| Kafka topic missing | Topic never created | Re-run the `kafka-topics --create ... log-events` command |
| Consumer cannot reach DB | Postgres still starting | Wait for `pg_isready`; re-run consumer |

---

### Quick reference

```bash
docker compose up -d
# create topic log-events (see Way 1)
cd log-producer && mvn spring-boot:run
cd log-consumer && mvn spring-boot:run
cd api-gateway && mvn spring-boot:run
./integration-tests/system-integration-test.sh
./load-test.sh
# Grafana http://localhost:3000  |  Prometheus http://localhost:9090
./cleanup.sh
```
