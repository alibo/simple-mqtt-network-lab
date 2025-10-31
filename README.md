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
 - Network troubleshooting helper: container `network-troubleshooting` shares toxiproxy's netns
   (tools: tcpdump, mtr, dig, curl, tc, etc.).

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
  clean_session: true    # default
retry:
  enabled: true
  connect_timeout_ms: 5000
  max_reconnect_interval_ms: 10000
  ping_timeout_ms: 5000
  write_timeout_ms: 5000
## App-level ping/pong removed. Built-in MQTT keepalive (PINGREQ/PINGRESP) is used.
publish:
  offer_every_ms: 1000
  ride_every_ms: 2000
qos:
  location: 0
  offer: 0
  ride: 0
payload_bytes:
  offer: 4096
  ride: 4096
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
  clean_session: true    # default
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
  location: 4096
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

## Toxiproxy Usage (Impairments)

The Java client connects to Toxiproxy (`localhost:18830`), which forwards to the gateway. The proxy is created at boot from `toxiproxy/config.json`.

Helper script (recommended):
- Control the proxy with `bash scripts/mqtt-proxy.sh`:
  - Down (hard drop): `bash scripts/mqtt-proxy.sh down`
  - Up (restore): `bash scripts/mqtt-proxy.sh up`
  - Timeout 5s: `bash scripts/mqtt-proxy.sh timeout 5000`
  - Half‑open (client view, block server→client): `bash scripts/mqtt-proxy.sh halfdown`
  - Half‑open (server view, block client→server): `bash scripts/mqtt-proxy.sh halfup`
  - Blackhole both ways (no FIN/RST): `bash scripts/mqtt-proxy.sh blackhole` (or `blackhole 600000` for 10m)
  - Latency and jitter: `bash scripts/mqtt-proxy.sh latency 120 40 [down|up|both]` (default jitter=0, both directions)
  - Clear latency: `bash scripts/mqtt-proxy.sh unlatency`
  - Bandwidth limit: `bash scripts/mqtt-proxy.sh bandwidth 256kbps [down|up|both]` (use `bps|kbps|mbps` or bytes/s)
  - Clear bandwidth: `bash scripts/mqtt-proxy.sh unbandwidth`
  - Approx packet loss: `bash scripts/mqtt-proxy.sh packetloss 20 [down|up|both]` (uses slicer; not real per‑packet drop)
  - Clear packet loss: `bash scripts/mqtt-proxy.sh unpacketloss`
  - Status: `bash scripts/mqtt-proxy.sh status`
  - Env: set `TOXIPROXY_URL` if not `http://localhost:8474` (default).

Direct API examples:

- Inspect proxies
```bash
curl -s http://localhost:8474/proxies | jq .
```

- Create the MQTT proxy (compose already does this via `toxiproxy/config.json`):
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

## MQTT Keepalive & Reconnect

### Keepalive Basics
- Purpose: Detect half‑open TCP connections without application pings.
- Mechanism: Client must send any MQTT control packet within the negotiated keepalive interval; if idle, it sends PINGREQ. The broker replies with PINGRESP.
- Broker side timeout: Most brokers (including EMQX) consider the connection dead after roughly 1.5 × keepalive with no incoming control packets.
- Client side timeout:
  - Java: handled internally by Paho; when PINGRESP is not received, `connectionLost()` fires and auto‑reconnect kicks in if enabled.
  - Go: configured via `retry.ping_timeout_ms` (default 5000 ms). If a PINGRESP is not received within this window, the client treats the connection as lost.

Both apps use MQTT keepalive only (no app‑level ping/pong). Enable debug logs to see PINGREQ/PINGRESP traces.

### Reconnect Backoff
- Java client (Paho MqttAsyncClient):
  - Auto‑reconnect enabled via `retry.automatic_reconnect: true`.
  - Exponential backoff doubles per attempt and caps at `maxReconnectDelay` (Paho default ≈ 128 s if not set).
  - Connect timeout controls how long each handshake may take (`retry.connect_timeout_ms`).
  - Note: Paho Java’s `setMaxReconnectDelay(..)` expects seconds. Our YAML key `retry.max_reconnect_delay_ms` is milliseconds; the example below uses seconds for readability.
- Go backend (paho.mqtt.golang):
  - Auto‑reconnect enabled via `retry.enabled: true`.
  - Exponential backoff with a cap at `retry.max_reconnect_interval_ms`.
  - `retry.connect_timeout_ms` limits each connect attempt’s handshake; `retry.ping_timeout_ms` bounds how long to wait for PINGRESP.

### Example: Paho Java Auto‑Reconnect Timeline

Config:

keepalive = 120 s → connection considered lost after ~180 s (1.5 × KA)

connect timeout = 30 s

maxReconnectDelay = default ≈ 128 s (2 min)

Backoff pattern: 1 → 2 → 4 → 8 → 16 → 32 → 64 → 128 → 128 …

⏱ Event Timeline (network down → up to 5 min)
```
t =   0 s  | Normal operation
t = 180 s  | No packets for 1.5×KeepAlive → connectionLost() triggered
            | Auto-reconnect loop starts
──────────────────────────────────────────────────────────────────────
Attempt #1  | delay=0 s   connect timeout=30 s   (180–210 s)
Attempt #2  | delay=1 s   connect timeout=30 s   (211–241 s)
Attempt #3  | delay=2 s   connect timeout=30 s   (243–273 s)
Attempt #4  | delay=4 s   connect timeout=30 s   (277–307 s)
Attempt #5  | delay=8 s   connect timeout=30 s   (315–345 s)
Attempt #6  | delay=16 s  connect timeout=30 s   (361–391 s)
Attempt #7  | delay=32 s  connect timeout=30 s   (423–453 s)
Attempt #8  | delay=64 s  connect timeout=30 s   (517–547 s)
Attempt #9+ | delay≈128 s (capped)               (beyond ~9 min if still offline)
──────────────────────────────────────────────────────────────────────
```

Notes:
- With clean sessions enabled (default), subscriptions are re‑issued on reconnect (both apps already do this in their connect handlers).
- With persistent sessions (`clean_session: false`), the broker retains subscriptions and queued QoS 1/2 messages; both apps still safely resubscribe.
- Under full blackhole conditions (no FIN/RST), detection depends on keepalive; expect `~1×KA` to send PINGREQ and up to `~1.5×KA` for disconnect at the broker side. Client‑side may trigger earlier if `ping_timeout_ms` elapses (Go) or Paho Java detects missing PINGRESPs.

## Network Impairments (tc NetEm)

For true per‑packet loss/jitter/latency at the OS level, use the NetEm helper. It applies `tc netem` in the Toxiproxy network namespace so all proxied MQTT traffic is affected.

- Helper script: `bash scripts/netem.sh`
- Defaults: `TARGET=toxiproxy`, `IFACE=eth0`, and it will exec into the `network-troubleshooting` container if present; otherwise it starts a short‑lived helper.

Examples:
- Show current qdisc: `bash scripts/netem.sh status`
- 120ms delay with 40ms jitter: `bash scripts/netem.sh delay 120 40`
- 5% packet loss: `bash scripts/netem.sh loss 5`
- Combine delay+loss: `bash scripts/netem.sh shape 120 20 2 10`
- Clear NetEm: `bash scripts/netem.sh clear`

Notes:
- This is real packet impairment below TCP, unlike Toxiproxy's slicer toxic which only fragments streams.
- Requires NET_ADMIN capability; the `network-troubleshooting` container has it by default.

## Troubleshooting Container (netshoot)

A persistent `nicolaka/netshoot` container named `network-troubleshooting` shares the network namespace with Toxiproxy for deep inspection.

- Start automatically with compose: `docker compose up -d network-troubleshooting` (included in the default stack)
- Shell: `docker exec -it network-troubleshooting bash`
- Common tools available: tcpdump, tshark, dig, nslookup, curl, mtr, arping, tc, ss, iproute2.
- Capture MQTT proxy traffic to pcap: `docker exec -it network-troubleshooting tcpdump -i eth0 -n port 18830 -w /tmp/mqtt.pcap`

Helper script for capture: `bash scripts/capture.sh`
- Save MQTT proxy traffic 60s to /tmp/mqtt-proxy.pcap: `bash scripts/capture.sh port 60 mqtt-proxy.pcap`
- Save custom filter 30s: `bash scripts/capture.sh filter "host mqtt-gateway" 30 gw.pcap`
- Live sniff (Ctrl+C to stop): `bash scripts/capture.sh live "port 18830"`
- Live to Wireshark via named pipe: `bash scripts/capture.sh live-wireshark "port 18830 or (host mqtt-gateway and port 1883)"`
- List saved pcaps: `bash scripts/capture.sh list`
- Copy to host: `bash scripts/capture.sh copy mqtt-proxy.pcap ./captures`

Design choices: Toxiproxy toxics simulate stream conditions (latency, bandwidth, half‑open, fragmentation). For realistic packet loss/reordering/corruption, prefer NetEm.

### Live Capture with Wireshark (from host)

You can stream packets from the netshoot helper into Wireshark running on your host.

Option A — direct pipe (Linux):

```bash
docker exec network-troubleshooting \
  tcpdump -i eth0 -U -s 0 -w - \
  'port 18830 or (host mqtt-gateway and port 1883)' | \
  wireshark -k -i -
```

Option B — named pipe (Linux/macOS):

Terminal 1 (producer):

```bash
mkfifo /tmp/mqtt.pipe
docker exec network-troubleshooting \
  tcpdump -i eth0 -U -s 0 -w - \
  'port 18830 or (host mqtt-gateway and port 1883)' > /tmp/mqtt.pipe
```

Terminal 2 (Wireshark):

- Linux:
  ```bash
  wireshark -k -i /tmp/mqtt.pipe
  ```
- macOS:
  ```bash
  open -a Wireshark --args -k -i /tmp/mqtt.pipe
  ```

Tips:
- Use display filter `mqtt` or decode ports as MQTT: Analyze → Decode As… → select TCP port 18830/1883 → MQTT.
- `-U` (unbuffered) and `-s 0` ensure low-latency, full-packet capture.
- On Docker Desktop (macOS/Windows), capturing on host interfaces won’t see container traffic; the netshoot approach avoids that by sharing toxiproxy’s network namespace.

Shortcut: use the helper to set up the FIFO and launch Wireshark for you

```bash
bash scripts/capture.sh live-wireshark "port 18830 or (host mqtt-gateway and port 1883)"
```

Notes:
- The helper creates a FIFO at `/tmp/mqtt.pipe` (override with `FIFO=/path`), starts tcpdump inside `network-troubleshooting`, and launches Wireshark on the host.
- Close Wireshark to stop capture; the helper cleans up the background tcpdump and removes the FIFO.

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
