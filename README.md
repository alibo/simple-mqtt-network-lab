# Simple MQTT Lab (Minimal Setup)

This is a minimal, production‑minded lab to exercise an MQTT v3.1 mobile client under network impairments. It includes:

- EMQX 5.8 cluster (3 nodes) behind an HAProxy MQTT gateway.
- Toxiproxy between the Java client and the gateway (for impairments).
- A Go backend that consumes driver locations and publishes offers/rides.
- A Java client (Paho MqttAsyncClient) that publishes driver locations and consumes offers/rides.
- Rich, structured logs and basic profiling endpoints (pprof for Go, JFR/thread dump for Java).

All app images use Debian slim bases. No Prometheus, no Grafana, no Streamlit UI.

## Quickstart

```bash
cd simple-mqtt-network-lab
# Build and run
docker compose up --build
```

Services:
- HAProxy MQTT gateway: `mqtt-gateway:1883` (host: `localhost:1883`)
- EMQX dashboard: http://localhost:18083 (admin/public)
- Toxiproxy API: http://localhost:8474
  - Proxy preconfigured via `toxiproxy/config.json` (listen `0.0.0.0:18830` → upstream `mqtt-gateway:1883`).
- Go backend profiling: http://localhost:6060/debug/pprof
- Java client profiling: http://localhost:6061 (see endpoints below)

Logs are printed to stdout for each service. Stop with Ctrl+C; Compose triggers graceful shutdown for the apps.

## Architecture

```
java-client ──tcp──> toxiproxy:18830 ──tcp──> mqtt-gateway:1883 ──> emqx[1..3]
  | publish /driver/location (configurable)
  | subscribe /driver/offer, /driver/ride

backend    ───────────────tcp──────────────> mqtt-gateway:1883 ──> emqx[1..3]
  | subscribe /driver/location
  | publish   /driver/offer (every Y ms), /driver/ride (every Z ms)
```

## Topics
- `/driver/location` (Java → Backend)
- `/driver/offer` (Backend → Java)
- `/driver/ride` (Backend → Java)

## Configuration

Edit the YAML files under `configs/` (structured, human‑readable). Defaults are sensible and focus on reconnect robustness and observability.

- `configs/backend.yaml` controls the Go backend (publish rates, keepalive, retry, QoS, payload sizes, socket/buffer/inflight, debug).
- `configs/client.yaml` controls the Java client (publish rate, keepalive, retry, QoS, payload sizes, socket/buffer/inflight, debug).

Both apps hot‑reload only on restart (simple by design). Example snippets (full files provided):

```yaml
# backend.yaml
mqtt:
  host: mqtt-gateway
  port: 1883
  client_id: backend-1
  keepalive_secs: 30
  protocol_version: 3   # MQTT 3.1
retry:
  enabled: true
  connect_timeout_ms: 5000
  max_reconnect_interval_ms: 10000
## App-level ping/pong removed. Built-in MQTT keepalive (PINGREQ/PINGRESP) is used.
publish:
  offer_every_ms: 1000
  ride_every_ms: 2000
qos:
  location: 0
  offer: 0
  ride: 0
payload_bytes:
  offer: 100
  ride: 120
socket:
  tcp_keepalive_secs: 60
  tcp_nodelay: true
  read_buffer: 262144
  write_buffer: 262144
buffer_inflight:
  max_inflight: 64
  buffer_enabled: true
  buffer_size: 1000
  drop_oldest: true
  persist: false
log:
  debug: false
```

```yaml
# client.yaml
mqtt:
  host: toxiproxy
  port: 18830    # Toxiproxy → HAProxy:1883
  client_id: java-1
  keepalive_secs: 30
  protocol_version: 3   # MQTT 3.1
retry:
  enabled: true
  automatic_reconnect: true
  connect_timeout_ms: 5000
  max_reconnect_delay_ms: 10000
qos:
  location: 0
  offer: 0
  ride: 0
payload_bytes:
  location: 80
socket:
  tcp_keepalive: true
  tcp_nodelay: true
  receive_buffer: 262144
  send_buffer: 262144
buffer_inflight:
  max_inflight: 64
  buffer_enabled: true
  buffer_size: 1000
  drop_oldest: true
  persist: false
log:
  debug: false
publish:
  location_every_ms: 1000
```

## Toxiproxy Usage (Full Drop on Demand)

The Java client connects to Toxiproxy (`localhost:18830`), which forwards to the gateway. The proxy is created at boot from `toxiproxy/config.json`.

Helper script (recommended):
- Control the proxy with `bash scripts/mqtt-proxy.sh`:
  - Down (hard drop): `bash scripts/mqtt-proxy.sh down`
  - Up (restore): `bash scripts/mqtt-proxy.sh up`
  - Timeout 5s: `bash scripts/mqtt-proxy.sh timeout 5000`
  - Half‑open (client view, block server→client): `bash scripts/mqtt-proxy.sh halfdown`
  - Half‑open (server view, block client→server): `bash scripts/mqtt-proxy.sh halfup`
  - Blackhole both ways (no FIN/RST): `bash scripts/mqtt-proxy.sh blackhole` (or `blackhole 600000` for 10m)
  - Status: `bash scripts/mqtt-proxy.sh status`
  - Env: set `TOXIPROXY_URL` if not `http://localhost:8474` (default).

Direct API examples:

- Inspect proxies
```bash
curl -s http://localhost:8474/proxies | jq .
```

- Create the MQTT proxy (compose does this automatically via `toxiproxy-init`):
```bash
curl -s -X POST http://localhost:8474/proxies \
  -H 'Content-Type: application/json' \
  -d '{"name":"mqtt","listen":"0.0.0.0:18830","upstream":"mqtt-gateway:1883"}'
```

- Simulate full drop (reset connections instantly)
```bash
curl -s -X POST http://localhost:8474/proxies/mqtt/toxics \
  -H 'Content-Type: application/json' \
  -d '{"name":"drop","type":"reset_peer","stream":"downstream","toxicity":1.0}'
```
- Remove the drop toxic
```bash
curl -s -X DELETE http://localhost:8474/proxies/mqtt/toxics/drop
```

- Pause traffic for 5s (timeout toxic)
```bash
curl -s -X POST http://localhost:8474/proxies/mqtt/toxics \
  -H 'Content-Type: application/json' \
  -d '{"name":"timeout5s","type":"timeout","stream":"downstream","attributes":{"timeout":5000}}'
```
- Remove the timeout toxic
```bash
curl -s -X DELETE http://localhost:8474/proxies/mqtt/toxics/timeout5s
```

Note: Toxiproxy 2.5 treats `enabled` as read-only via the REST API; use toxics (above) or delete/recreate the proxy instead.

### Half‑Open Simulation

- `halfdown` adds a downstream `limit_data` toxic with `bytes=0`, effectively blackholing server→client. The client keeps sending (e.g., PINGREQ, publishes) but never receives responses (PINGRESP, PUBACK). No FIN/RST is sent; the server still sees client traffic until keepalive/app timeouts.
- `halfup` adds an upstream `limit_data` toxic with `bytes=0`, blackholing client→server. The socket stays open but the server won’t see client packets.
- Use `up` to remove `halfdown`, `halfup`, `timeout`, and `down` toxics.

### Full Blackhole (Both Directions)

- `blackhole [ms]` adds a downstream `timeout_down` and upstream `timeout_up` toxic. With a large timeout (default ~1 year), both directions are blocked without FIN/RST so both ends think the connection is alive until their keepalive or app timeouts fire.
- Use `up` to remove `timeout_down`/`timeout_up`.

## Profiling

- Go backend
  - Endpoint: `http://localhost:6060/debug/pprof`
  - CPU profile 30s: `go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30`
  - Heap: `curl -s http://localhost:6060/debug/pprof/heap > heap.pb.gz`

- Java client
  - Base URL: `http://localhost:6061`
  - Health: `GET /healthz`
  - Thread dump: `GET /profiling/threads` (text/plain)
  - Start JFR (60s): `POST /profiling/jfr/start?name=run1&durationSec=60`
  - Stop JFR: `POST /profiling/jfr/stop?name=run1` (returns path inside container)

Note: JFR requires a JDK (we run on OpenJDK 17 slim). Retrieve the recorded JFR with `docker cp` if needed.

## MQTT Gateway & EMQX

- HAProxy runs with TCP logging enabled and acts as a front door to EMQX cluster via round‑robin.
- EMQX 5.8 cluster (3 nodes) is formed with static seeds. Dashboard is exposed on http://localhost:18083 (admin/public).

## Operational Notes

- Robustness: Both apps use auto‑reconnect, keepalive, inflight/buffers, and structured logs. They log connect/reconnect/disconnect with reasons, subscribe acks, publish results, buffer and inflight counts (every 1s), errors, and shutdown.
- Graceful shutdown: SIGINT/SIGTERM stops publishers, flushes pending publishes, and disconnects cleanly.
- Socket tuning: TCP keepalive and buffer sizes are configurable; Java uses a custom SocketFactory; Go uses a custom Dialer and adjusts TCP options.

- Debug keepalive visibility: When debug is enabled in YAML (`log.debug: true`), both apps surface Paho client debug logs. This includes MQTT keepalive traces (PINGREQ/PINGRESP) where supported by the client libraries.

- Liveness logging: Both apps log explicit transitions: `connection dead (lost connectivity)` and `connection alive (recovered)`.

## Message Payload Format

- Human‑readable prefixes include timestamp and sequence number for ordering. Payloads are padded with `x` to reach configured sizes when applicable.

  - Java `/driver/location` example prefix: `ts=<unix_ms>|seq=<n>|xxxx...`
  - Go publishes `/driver/offer` and `/driver/ride` with: `ts=<unix_ms>|seq=<n>|xxxx...`

## Make It Your Own

- Tweak `configs/*.yaml` and rebuild: `docker compose up --build`.
- Change QoS, payload sizes, or the publish timers to stress buffering/inflight behavior.
- Use Toxiproxy toxics to simulate handovers/drops and observe logs for backoff, reconnects, and queue dynamics.

## Tests

- Go unit tests: `cd go-backend && go test -cover ./...`
- Go integration test: set `TEST_MQTT_BROKER=tcp://localhost:1883` then run `go test -run Integration ./...`
  - Use Docker to bring a broker up: `docker compose up -d mqtt-gateway emqx1` (or full stack)
- Java unit tests: `cd java-client && ./gradlew test`
- Java integration test: set `TEST_MQTT_BROKER=tcp://localhost:1883` then run `./gradlew test`
  - The integration test is automatically skipped if `TEST_MQTT_BROKER` is not set

Notes:
- Go toolchain is set to `go1.25` and the Dockerfile uses `golang:1.25-bookworm`.
- YAML parsing uses battle‑tested libraries: `gopkg.in/yaml.v3` (Go) and SnakeYAML (Java).
- Application‑level ping/pong topics were removed; MQTT keepalive interval defaults to 15s and is configurable via YAML.
