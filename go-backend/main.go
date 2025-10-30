package main

import (
    "context"
    "fmt"
    "log"
    "net"
    "net/http"
    _ "net/http/pprof"
    "net/url"
    "os"
    "os/signal"
    "strings"
    "sync/atomic"
    "syscall"
    "time"

    mqtt "github.com/eclipse/paho.mqtt.golang"
    "gopkg.in/yaml.v3"
)

// Config is loaded from YAML (battle-tested parser). Defaults are applied in code.

type Config struct {
    MQTT struct {
        Host            string `yaml:"host"`
        Port            int    `yaml:"port"`
        ClientID        string `yaml:"client_id"`
        KeepAliveSecs   int    `yaml:"keepalive_secs"`
        ProtocolVersion int    `yaml:"protocol_version"`
        CleanSession    *bool  `yaml:"clean_session"`
    } `yaml:"mqtt"`
    Retry struct {
        Enabled                *bool `yaml:"enabled"`
        ConnectTimeoutMs       int  `yaml:"connect_timeout_ms"`
        MaxReconnectIntervalMs int  `yaml:"max_reconnect_interval_ms"`
        PingTimeoutMs          int  `yaml:"ping_timeout_ms"`
        WriteTimeoutMs         int  `yaml:"write_timeout_ms"`
    } `yaml:"retry"`
    Publish struct {
        OfferEveryMs int `yaml:"offer_every_ms"`
        RideEveryMs  int `yaml:"ride_every_ms"`
    } `yaml:"publish"`
    QoS struct {
        Location *int `yaml:"location"`
        Offer    *int `yaml:"offer"`
        Ride     *int `yaml:"ride"`
    } `yaml:"qos"`
    PayloadBytes struct {
        Offer int `yaml:"offer"`
        Ride  int `yaml:"ride"`
    } `yaml:"payload_bytes"`
    Socket struct {
        TCPKeepAliveSecs int  `yaml:"tcp_keepalive_secs"`
        TCPNoDelay       bool `yaml:"tcp_nodelay"`
        ReadBuffer       int  `yaml:"read_buffer"`
        WriteBuffer      int  `yaml:"write_buffer"`
    } `yaml:"socket"`
    BufferInflight struct {
        MaxInflight   int  `yaml:"max_inflight"`
        BufferEnabled bool `yaml:"buffer_enabled"`
        BufferSize    int  `yaml:"buffer_size"`
        DropOldest    bool `yaml:"drop_oldest"`
        Persist       bool `yaml:"persist"`
    } `yaml:"buffer_inflight"`
    Log struct{ Debug bool `yaml:"debug"` } `yaml:"log"`
}
func loadConfig() (Config, error) {
    path := os.Getenv("BACKEND_CONFIG")
    if path == "" {
        path = "configs/backend.yaml"
    }
    data, err := os.ReadFile(path)
    if err != nil {
        return Config{}, err
    }
    var c Config
    if err := yaml.Unmarshal(data, &c); err != nil {
        return Config{}, err
    }
    // Apply defaults
    if c.MQTT.Host == "" {
        c.MQTT.Host = "mqtt-gateway"
    }
    if c.MQTT.Port == 0 {
        c.MQTT.Port = 1883
    }
    if c.MQTT.ClientID == "" {
        c.MQTT.ClientID = "backend-1"
    }
    if c.MQTT.KeepAliveSecs == 0 {
        c.MQTT.KeepAliveSecs = 15
    }
    if c.MQTT.ProtocolVersion == 0 {
        c.MQTT.ProtocolVersion = 3
    }
    if c.MQTT.CleanSession == nil {
        v := true
        c.MQTT.CleanSession = &v
    }
    if c.Retry.ConnectTimeoutMs == 0 {
        c.Retry.ConnectTimeoutMs = 5000
    }
    if c.Retry.MaxReconnectIntervalMs == 0 {
        c.Retry.MaxReconnectIntervalMs = 10000
    }
    if c.Retry.PingTimeoutMs == 0 {
        c.Retry.PingTimeoutMs = 5000
    }
    if c.Retry.WriteTimeoutMs == 0 {
        c.Retry.WriteTimeoutMs = 5000
    }
    // Auto reconnect by default (respect explicit false)
    if c.Retry.Enabled == nil {
        v := true
        c.Retry.Enabled = &v
    }
    if c.Publish.OfferEveryMs == 0 {
        c.Publish.OfferEveryMs = 1000
    }
    if c.Publish.RideEveryMs == 0 {
        c.Publish.RideEveryMs = 2000
    }
    // QoS defaults: only if not specified (0 is a valid QoS)
    if c.QoS.Location == nil {
        v := 1
        c.QoS.Location = &v
    }
    if c.QoS.Offer == nil {
        v := 1
        c.QoS.Offer = &v
    }
    if c.QoS.Ride == nil {
        v := 1
        c.QoS.Ride = &v
    }
    if c.PayloadBytes.Offer == 0 {
        c.PayloadBytes.Offer = 100
    }
    if c.PayloadBytes.Ride == 0 {
        c.PayloadBytes.Ride = 120
    }
    if c.Socket.TCPKeepAliveSecs == 0 {
        c.Socket.TCPKeepAliveSecs = 60
    }
    if c.Socket.ReadBuffer == 0 {
        c.Socket.ReadBuffer = 256 * 1024
    }
    if c.Socket.WriteBuffer == 0 {
        c.Socket.WriteBuffer = 256 * 1024
    }
    if c.BufferInflight.MaxInflight == 0 {
        c.BufferInflight.MaxInflight = 64
    }
    if c.BufferInflight.BufferSize == 0 {
        c.BufferInflight.BufferSize = 1000
    }
    return c, nil
}

type counters struct {
    // totals
    published int64
    acked     int64
    received  int64
    // per-topic
    pubOffer int64
    ackOffer int64
    pubRide  int64
    ackRide  int64
    recvLocation int64
}

// ANSI colors for keywords
const (
    colReset = "\033[0m"
    colGreen = "\033[32m"
    colYellow = "\033[33m"
    colBlue = "\033[34m"
    colMagenta = "\033[35m"
    colCyan = "\033[36m"
    colRed = "\033[31m"
)

func tag(name, color string) string { return color + "[" + name + "]" + colReset }

// payload prefix: ts=<unix_ms>|seq=<n>| ...
func parseSeq(b []byte) int64 {
    s := string(b)
    // fast path: look for "seq=" then parse until '|'
    i := strings.Index(s, "seq=")
    if i < 0 { return -1 }
    i += 4
    j := strings.IndexByte(s[i:], '|')
    if j < 0 { return -1 }
    j += i
    var n int64
    for k := i; k < j; k++ {
        c := s[k]
        if c < '0' || c > '9' { return -1 }
        n = n*10 + int64(c-'0')
    }
    return n
}

func main() {
    cfg, err := loadConfig()
    if err != nil {
        log.Fatalf("config: %v", err)
    }
    // Local time zone mention
    _, off := time.Now().Zone()
    log.SetFlags(log.LstdFlags | log.Lmicroseconds)
    log.Printf("backend: timezone local offset=%ds", off)
    // Print loaded config as YAML for clarity
    if y, e := yaml.Marshal(cfg); e == nil {
        log.Printf("backend: starting with config:\n%s", string(y))
    } else {
        log.Printf("backend: starting with config: %+v", cfg)
    }

    // Enable Paho internal DEBUG logs (includes keepalive PINGREQ/PINGRESP traces)
    if cfg.Log.Debug {
        mqtt.ERROR = log.New(os.Stdout, "paho.ERROR ", log.LstdFlags)
        mqtt.WARN = log.New(os.Stdout, "paho.WARN ", log.LstdFlags)
        mqtt.CRITICAL = log.New(os.Stdout, "paho.CRIT ", log.LstdFlags)
        mqtt.DEBUG = log.New(os.Stdout, "paho.DEBUG ", log.LstdFlags)
    }

    // Start pprof
    go func() {
        srv := &http.Server{Addr: ":6060"}
        log.Printf("backend: pprof listening on :6060")
        _ = srv.ListenAndServe()
    }()

    // Context & signals
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    sigc := make(chan os.Signal, 2)
    signal.Notify(sigc, syscall.SIGINT, syscall.SIGTERM)

    // MQTT
    broker := fmt.Sprintf("tcp://%s:%d", cfg.MQTT.Host, cfg.MQTT.Port)
    opts := mqtt.NewClientOptions().AddBroker(broker)
    if cfg.MQTT.ClientID != "" {
        opts.SetClientID(cfg.MQTT.ClientID)
    }
    opts.SetProtocolVersion(uint(cfg.MQTT.ProtocolVersion))
    clean := true
    if cfg.MQTT.CleanSession != nil { clean = *cfg.MQTT.CleanSession }
    opts.SetCleanSession(clean)
    opts.SetAutoReconnect(*cfg.Retry.Enabled)
    opts.SetKeepAlive(time.Duration(cfg.MQTT.KeepAliveSecs) * time.Second)
    if cfg.Retry.PingTimeoutMs > 0 {
        opts.SetPingTimeout(time.Duration(cfg.Retry.PingTimeoutMs) * time.Millisecond)
    }
    if cfg.Retry.ConnectTimeoutMs > 0 {
        opts.SetConnectTimeout(time.Duration(cfg.Retry.ConnectTimeoutMs) * time.Millisecond)
    }
    if cfg.Retry.MaxReconnectIntervalMs > 0 {
        opts.SetMaxReconnectInterval(time.Duration(cfg.Retry.MaxReconnectIntervalMs) * time.Millisecond)
    }
    if cfg.Retry.WriteTimeoutMs > 0 {
        opts.SetWriteTimeout(time.Duration(cfg.Retry.WriteTimeoutMs) * time.Millisecond)
    }
    opts.SetResumeSubs(true)
    opts.SetOrderMatters(false)

    // Custom dialer for socket tuning
    opts.SetCustomOpenConnectionFn(func(uri *url.URL, _ mqtt.ClientOptions) (net.Conn, error) {
        d := net.Dialer{Timeout: time.Duration(cfg.Retry.ConnectTimeoutMs) * time.Millisecond, KeepAlive: time.Duration(cfg.Socket.TCPKeepAliveSecs) * time.Second}
        conn, err := d.DialContext(ctx, "tcp", uri.Host)
        if err != nil {
            return nil, err
        }
        if tcp, ok := conn.(*net.TCPConn); ok {
            _ = tcp.SetNoDelay(cfg.Socket.TCPNoDelay)
            if cfg.Socket.ReadBuffer > 0 {
                _ = tcp.SetReadBuffer(cfg.Socket.ReadBuffer)
            }
            if cfg.Socket.WriteBuffer > 0 {
                _ = tcp.SetWriteBuffer(cfg.Socket.WriteBuffer)
            }
        }
        return conn, nil
    })

    var cnt counters
    opts.SetOnConnectHandler(func(c mqtt.Client) {
        log.Printf("backend: %s connected to %s", tag("connect", colBlue), broker)
        // Subscriptions
        if t := c.Subscribe("/driver/location", byte(*cfg.QoS.Location), func(_ mqtt.Client, m mqtt.Message) {
            atomic.AddInt64(&cnt.received, 1)
            atomic.AddInt64(&cnt.recvLocation, 1)
            seq := parseSeq(m.Payload())
            log.Printf("backend: %s topic=%s seq=%d qos=%d bytes=%d", tag("recv", colGreen), m.Topic(), seq, m.Qos(), len(m.Payload()))
        }); !t.WaitTimeout(5*time.Second) || t.Error() != nil {
            log.Printf("backend: %s subscribe /driver/location err=%v", tag("error", colRed), t.Error())
        } else {
            log.Printf("backend: subscribed /driver/location")
        }
        // Using MQTT PINGREQ/PINGRESP keepalive. No app-level ping/pong.
    })
    opts.SetConnectionLostHandler(func(_ mqtt.Client, err error) { log.Printf("backend: %s err=%v", tag("disconnect", colYellow), err) })
    opts.SetReconnectingHandler(func(_ mqtt.Client, _ *mqtt.ClientOptions) { log.Printf("backend: %s", tag("reconnecting", colYellow)) })

    client := mqtt.NewClient(opts)
    if tok := client.Connect(); !tok.WaitTimeout(10*time.Second) || tok.Error() != nil {
        log.Fatalf("backend: connect error: %v", tok.Error())
    }

    // Publishers
    offerTicker := time.NewTicker(time.Duration(cfg.Publish.OfferEveryMs) * time.Millisecond)
    rideTicker := time.NewTicker(time.Duration(cfg.Publish.RideEveryMs) * time.Millisecond)
    var closed atomic.Bool

    publish := func(topic string, qos byte, size int, seq int64) {
        // payload starts with human-readable ts + seq
        ts := time.Now().UnixMilli()
        prefix := fmt.Sprintf("ts=%d|seq=%d|", ts, seq)
        pad := size - len(prefix)
        if pad < 0 { pad = 0 }
        payload := make([]byte, len(prefix)+pad)
        copy(payload, []byte(prefix))
        for i := 0; i < pad; i++ { payload[len(prefix)+i] = 'x' }
        log.Printf("backend: %s topic=%s seq=%d bytes=%d", tag("publish", colMagenta), topic, seq, len(payload))
        t := client.Publish(topic, qos, false, payload)
        go func(tok mqtt.Token, topic string) {
            if !tok.WaitTimeout(10 * time.Second) {
                log.Printf("backend: %s topic=%s", tag("pub_timeout", colRed), topic)
                return
            }
            if tok.Error() != nil {
                log.Printf("backend: %s topic=%s err=%v", tag("pub_error", colRed), topic, tok.Error())
                return
            }
            atomic.AddInt64(&cnt.acked, 1)
            switch topic {
            case "/driver/offer":
                atomic.AddInt64(&cnt.ackOffer, 1)
            case "/driver/ride":
                atomic.AddInt64(&cnt.ackRide, 1)
            }
        }(t, topic)
        atomic.AddInt64(&cnt.published, 1)
        switch topic {
        case "/driver/offer":
            atomic.AddInt64(&cnt.pubOffer, 1)
        case "/driver/ride":
            atomic.AddInt64(&cnt.pubRide, 1)
        }
    }

    // No disconnected buffer: Go Paho client does not offer a DisconnectedBufferOptions equivalent.

    // No app-level ping loop; rely on MQTT keepalive.

    // Stats log loop
    go func() {
        t := time.NewTicker(1 * time.Second)
        defer t.Stop()
        for !closed.Load() {
            <-t.C
            totalInFlight := atomic.LoadInt64(&cnt.published) - atomic.LoadInt64(&cnt.acked)
            offerIn := atomic.LoadInt64(&cnt.pubOffer) - atomic.LoadInt64(&cnt.ackOffer)
            rideIn := atomic.LoadInt64(&cnt.pubRide) - atomic.LoadInt64(&cnt.ackRide)
            log.Printf("backend: %s topic=/driver/offer pub=%d ack=%d inflight=%d | topic=/driver/ride pub=%d ack=%d inflight=%d | topic=/driver/location recv=%d | total_pub=%d total_ack=%d total_inflight=%d connected=%v",
                tag("stats", colCyan),
                atomic.LoadInt64(&cnt.pubOffer), atomic.LoadInt64(&cnt.ackOffer), offerIn,
                atomic.LoadInt64(&cnt.pubRide), atomic.LoadInt64(&cnt.ackRide), rideIn,
                atomic.LoadInt64(&cnt.recvLocation),
                atomic.LoadInt64(&cnt.published), atomic.LoadInt64(&cnt.acked), totalInFlight, client.IsConnectionOpen())
        }
    }()

    // Publish loops (with per-topic sequence numbers). Only publish when connected.
    var offerSeq atomic.Int64
    go func() {
        for {
            select {
            case <-offerTicker.C:
                if client.IsConnectionOpen() {
                    s := offerSeq.Add(1)
                    publish("/driver/offer", byte(*cfg.QoS.Offer), cfg.PayloadBytes.Offer, s)
                }
            case <-ctx.Done():
                return
            }
        }
    }()
    var rideSeq atomic.Int64
    go func() {
        for {
            select {
            case <-rideTicker.C:
                if client.IsConnectionOpen() {
                    s := rideSeq.Add(1)
                    publish("/driver/ride", byte(*cfg.QoS.Ride), cfg.PayloadBytes.Ride, s)
                }
            case <-ctx.Done():
                return
            }
        }
    }()

    // Connection liveness transition logs
    go func() {
        t := time.NewTicker(1 * time.Second)
        defer t.Stop()
        prev := client.IsConnectionOpen()
        for !closed.Load() {
            <-t.C
            cur := client.IsConnectionOpen()
            if prev && !cur {
                log.Printf("backend: connection dead (lost connectivity)")
            }
            if !prev && cur {
                log.Printf("backend: connection alive (reconnected)")
            }
            prev = cur
        }
    }()

    // Wait for signal
    sig := <-sigc
    log.Printf("backend: shutting down signal=%v", sig)
    closed.Store(true)
    offerTicker.Stop()
    rideTicker.Stop()

    // Flush disconnect
    if client.IsConnectionOpen() {
        client.Disconnect(250)
    }
}
