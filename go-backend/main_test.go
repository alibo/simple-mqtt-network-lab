package main

import (
    "os"
    "path/filepath"
    "testing"
    "time"

    mqtt "github.com/eclipse/paho.mqtt.golang"
)

func writeTempConfig(t *testing.T, content string) string {
    t.Helper()
    dir := t.TempDir()
    p := filepath.Join(dir, "backend.yaml")
    if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
        t.Fatalf("write temp config: %v", err)
    }
    return p
}

func TestLoadConfig_Defaults(t *testing.T) {
    // keepalive omitted -> default 15
    cfgPath := writeTempConfig(t, `mqtt:
  host: test-broker
  port: 1883
  client_id: backend-test
retry:
  enabled: true
`)
    t.Setenv("BACKEND_CONFIG", cfgPath)
    cfg, err := loadConfig()
    if err != nil {
        t.Fatalf("loadConfig error: %v", err)
    }
    if cfg.MQTT.KeepAliveSecs != 15 {
        t.Fatalf("expected default keepalive 15, got %d", cfg.MQTT.KeepAliveSecs)
    }
    if cfg.MQTT.Host != "test-broker" || cfg.MQTT.Port != 1883 {
        t.Fatalf("unexpected mqtt host/port: %+v", cfg.MQTT)
    }
}

func TestLoadConfig_ParseAll(t *testing.T) {
    cfgPath := writeTempConfig(t, `mqtt:
  host: a
  port: 1111
  client_id: id
  keepalive_secs: 17
  protocol_version: 3
retry:
  enabled: true
  connect_timeout_ms: 4000
  max_reconnect_interval_ms: 9000
  ping_timeout_ms: 3000
  write_timeout_ms: 2000
publish:
  offer_every_ms: 123
  ride_every_ms: 456
qos:
  location: 2
  offer: 1
  ride: 0
payload_bytes:
  offer: 10
  ride: 20
socket:
  tcp_keepalive_secs: 30
  tcp_nodelay: true
  read_buffer: 1024
  write_buffer: 2048
buffer_inflight:
  max_inflight: 10
  buffer_enabled: true
  buffer_size: 99
  drop_oldest: true
  persist: false
log:
  debug: true
`)
    t.Setenv("BACKEND_CONFIG", cfgPath)
    cfg, err := loadConfig()
    if err != nil {
        t.Fatalf("loadConfig error: %v", err)
    }
    if cfg.MQTT.KeepAliveSecs != 17 || cfg.Publish.OfferEveryMs != 123 || cfg.BufferInflight.MaxInflight != 10 {
        t.Fatalf("unexpected parsed values: %+v", cfg)
    }
}

// Integration test: requires TEST_MQTT_BROKER (e.g., tcp://localhost:1883)
func TestMQTTIntegration(t *testing.T) {
    broker := os.Getenv("TEST_MQTT_BROKER")
    if broker == "" {
        t.Skip("TEST_MQTT_BROKER not set; skipping integration test")
    }
    topic := "test/go-int/" + time.Now().Format("150405.000000")
    received := make(chan struct{}, 1)
    opts := mqtt.NewClientOptions().AddBroker(broker).SetClientID("go-int-test").SetKeepAlive(15 * time.Second)
    cli := mqtt.NewClient(opts)
    if tok := cli.Connect(); !tok.WaitTimeout(10*time.Second) || tok.Error() != nil {
        t.Fatalf("connect: %v", tok.Error())
    }
    defer cli.Disconnect(250)
    if tok := cli.Subscribe(topic, 0, func(_ mqtt.Client, _ mqtt.Message) { received <- struct{}{} }); !tok.WaitTimeout(5*time.Second) || tok.Error() != nil {
        t.Fatalf("subscribe: %v", tok.Error())
    }
    if tok := cli.Publish(topic, 0, false, []byte("hello")); !tok.WaitTimeout(5*time.Second) || tok.Error() != nil {
        t.Fatalf("publish: %v", tok.Error())
    }
    select {
    case <-received:
    case <-time.After(5 * time.Second):
        t.Fatal("did not receive published message")
    }
}

