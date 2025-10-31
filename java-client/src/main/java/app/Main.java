package app;

import com.sun.net.httpserver.HttpServer;
import org.eclipse.paho.client.mqttv3.*;
import org.yaml.snakeyaml.Yaml;

import javax.net.SocketFactory;
import java.io.*;
import java.lang.management.ManagementFactory;
import java.lang.management.ThreadInfo;
import java.lang.management.ThreadMXBean;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import java.util.logging.ConsoleHandler;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.Logger;

// Custom YAML parser removed. Using SnakeYAML instead.

class Config {
    String host; int port; String clientId; int keepAlive; int protocolVersion; boolean cleanSession;
    boolean retryEnabled; boolean autoReconnect; int connectTimeoutMs; int maxReconnectDelayMs;
    int locationEveryMs;
    int qosLocation, qosOffer, qosRide; int payloadLocation;
    boolean tcpKeepAlive, tcpNoDelay; int rcvBuf, sndBuf;
    int maxInflight; boolean bufEnabled; int bufSize; boolean bufDropOldest; boolean bufPersist; boolean debug;

    @SuppressWarnings("unchecked") private static Map<String,Object> mapOf(Object o){ return (o instanceof Map)? (Map<String,Object>) o : new LinkedHashMap<>(); }
    private static String s(Map<String,Object> m, String k, String d){ Object v=m.get(k); return v instanceof String && !((String)v).isEmpty()? (String)v: d; }
    private static int i(Map<String,Object> m, String k, int d){ Object v=m.get(k); if (v instanceof Number) return ((Number)v).intValue(); if(v instanceof String) try{ return Integer.parseInt(((String)v).trim()); }catch(Exception ignored){} return d; }
    private static boolean b(Map<String,Object> m, String k, boolean d){ Object v=m.get(k); if (v instanceof Boolean) return (Boolean)v; if(v instanceof String){ String s=((String)v).trim().toLowerCase(); if (s.equals("true")||s.equals("1")||s.equals("yes")) return true; if(s.equals("false")||s.equals("0")||s.equals("no")) return false; } return d; }

    static Config load(String path) throws IOException {
        Yaml yaml = new Yaml();
        Map<String,Object> m;
        try (Reader r = new FileReader(path)) { m = yaml.load(r); }
        Map<String,Object> mq = mapOf(m.get("mqtt"));
        Map<String,Object> ry = mapOf(m.get("retry"));
        Map<String,Object> pb = mapOf(m.get("publish"));
        Map<String,Object> qos = mapOf(m.get("qos"));
        Map<String,Object> pl = mapOf(m.get("payload_bytes"));
        Map<String,Object> so = mapOf(m.get("socket"));
        Map<String,Object> bi = mapOf(m.get("buffer_inflight"));
        Map<String,Object> lg = mapOf(m.get("log"));
        Config c = new Config();
        c.host = s(mq, "host", "toxiproxy");
        c.port = i(mq, "port", 18830);
        c.clientId = s(mq, "client_id", "java-1");
        c.keepAlive = i(mq, "keepalive_secs", 15);
        c.protocolVersion = i(mq, "protocol_version", 3);
        c.retryEnabled = b(ry, "enabled", true);
        c.autoReconnect = b(ry, "automatic_reconnect", true);
        c.connectTimeoutMs = i(ry, "connect_timeout_ms", 5000);
        c.maxReconnectDelayMs = i(ry, "max_reconnect_delay_ms", 10000);
        c.cleanSession = b(mq, "clean_session", true);
        c.locationEveryMs = i(pb, "location_every_ms", 1000);
        c.qosLocation = i(qos, "location", 1);
        c.qosOffer = i(qos, "offer", 1);
        c.qosRide = i(qos, "ride", 1);
        c.payloadLocation = i(pl, "location", 80);
        c.tcpKeepAlive = b(so, "tcp_keepalive", true);
        c.tcpNoDelay = b(so, "tcp_nodelay", true);
        c.rcvBuf = i(so, "receive_buffer", 256*1024);
        c.sndBuf = i(so, "send_buffer", 256*1024);
        c.maxInflight = i(bi, "max_inflight", 64);
        c.bufEnabled = b(bi, "buffer_enabled", true);
        c.bufSize = i(bi, "buffer_size", 1000);
        c.bufDropOldest = b(bi, "drop_oldest", true);
        c.bufPersist = b(bi, "persist", false);
        c.debug = b(lg, "debug", true);
        return c;
    }
}

class TuningSocketFactory extends SocketFactory {
    private final boolean keepAlive; private final boolean noDelay; private final int rcv; private final int snd;
    private final SocketFactory delegate;
    TuningSocketFactory(boolean keepAlive, boolean noDelay, int rcv, int snd) {
        this.keepAlive=keepAlive; this.noDelay=noDelay; this.rcv=rcv; this.snd=snd; this.delegate=SocketFactory.getDefault();
    }
    private Socket tune(Socket s) throws IOException {
        s.setKeepAlive(keepAlive); s.setTcpNoDelay(noDelay);
        if (rcv>0) s.setReceiveBufferSize(rcv); if (snd>0) s.setSendBufferSize(snd);
        return s;
    }
    @Override public Socket createSocket() throws IOException { return tune(delegate.createSocket()); }
    @Override public Socket createSocket(String host, int port) throws IOException { return tune(delegate.createSocket(host, port)); }
    @Override public Socket createSocket(String host, int port, java.net.InetAddress local, int localPort) throws IOException { return tune(delegate.createSocket(host, port, local, localPort)); }
    @Override public Socket createSocket(java.net.InetAddress host, int port) throws IOException { return tune(delegate.createSocket(host, port)); }
    @Override public Socket createSocket(java.net.InetAddress address, int port, java.net.InetAddress local, int localPort) throws IOException { return tune(delegate.createSocket(address, port, local, localPort)); }
}

public class Main {
    private static final String COL_RESET = "\u001B[0m";
    private static final String COL_GREEN = "\u001B[32m";
    private static final String COL_YELLOW = "\u001B[33m";
    private static final String COL_BLUE = "\u001B[34m";
    private static final String COL_MAGENTA = "\u001B[35m";
    private static final String COL_CYAN = "\u001B[36m";
    private static final String COL_RED = "\u001B[31m";
    private static String tag(String name, String color){ return color+"["+name+"]"+COL_RESET; }
    private static String ts(){ return OffsetDateTime.now().toString(); }
    private static void logf(String fmt, Object... a){ System.out.println("java-client: "+ts()+" "+String.format(fmt, a)); }

    public static void main(String[] args) throws Exception {
        String cfgPath = System.getenv().getOrDefault("CLIENT_CONFIG", "configs/client.yaml");
        Config cfg = Config.load(cfgPath);
        logf("timezone local id=%s", ZoneId.systemDefault());
        logf("starting with config file: %s", cfgPath);
        logf("starting with config: host=%s port=%d clientId=%s keepAlive=%ds proto=%d cleanSession=%s qos{loc=%d,offer=%d,ride=%d} payload{loc=%d} inflightMax=%d buf{enabled=%s,size=%d,dropOldest=%s,persist=%s} debug=%s",
                cfg.host, cfg.port, cfg.clientId, cfg.keepAlive, cfg.protocolVersion, String.valueOf(cfg.cleanSession), cfg.qosLocation, cfg.qosOffer, cfg.qosRide, cfg.payloadLocation, cfg.maxInflight, String.valueOf(cfg.bufEnabled), cfg.bufSize, String.valueOf(cfg.bufDropOldest), String.valueOf(cfg.bufPersist), String.valueOf(cfg.debug));

        // Profiling HTTP (threads + JFR)
        startProfilingServer();

        // Enable fine-grained Paho logs (includes keepalive PINGREQ/PINGRESP traces when available)
        if (cfg.debug) {
            try {
                Logger paho = Logger.getLogger("org.eclipse.paho.client.mqttv3");
                paho.setLevel(Level.FINEST);
                ConsoleHandler ch = new ConsoleHandler();
                ch.setLevel(Level.FINEST);
                paho.addHandler(ch);
                Logger root = Logger.getLogger("");
                for (Handler h : root.getHandlers()) { h.setLevel(Level.FINEST); }
                logf("paho fine logging enabled");
            } catch (Throwable t) {
                logf("paho logging setup failed: %s", t);
            }
        }

        // MQTT
        String uri = String.format("tcp://%s:%d", cfg.host, cfg.port);
        MqttAsyncClient cli = new MqttAsyncClient(uri, cfg.clientId);
        MqttConnectOptions opt = new MqttConnectOptions();
        opt.setMqttVersion(MqttConnectOptions.MQTT_VERSION_3_1);
        opt.setCleanSession(cfg.cleanSession);
        opt.setKeepAliveInterval(cfg.keepAlive);
        opt.setConnectionTimeout(cfg.connectTimeoutMs/1000);
        opt.setAutomaticReconnect(cfg.autoReconnect);
        try { opt.setMaxReconnectDelay(cfg.maxReconnectDelayMs); } catch (Throwable ignored) {}
        try { opt.setMaxInflight(cfg.maxInflight); } catch (Throwable ignored) {}
        opt.setSocketFactory(new TuningSocketFactory(cfg.tcpKeepAlive, cfg.tcpNoDelay, cfg.rcvBuf, cfg.sndBuf));
        DisconnectedBufferOptions dbo = new DisconnectedBufferOptions();
        dbo.setBufferEnabled(cfg.bufEnabled);
        dbo.setBufferSize(cfg.bufSize);
        dbo.setDeleteOldestMessages(cfg.bufDropOldest);
        dbo.setPersistBuffer(cfg.bufPersist);
        cli.setBufferOpts(dbo);
        cli.setManualAcks(false);

        // Counters shared with callback and stats
        final AtomicLong recvOffer = new AtomicLong();
        final AtomicLong recvRide = new AtomicLong();

        cli.setCallback(new MqttCallbackExtended() {
            @Override public void connectComplete(boolean reconnect, String serverURI) {
                logf("%s server=%s reconnect=%s", tag("connect", COL_BLUE), serverURI, reconnect);
                // Ensure subscriptions on initial connect and reconnects
                try { cli.subscribe("/driver/offer", cfg.qosOffer).waitForCompletion(5000); } catch (MqttException e) { logf("subscribe error: %s", e); }
                try { cli.subscribe("/driver/ride", cfg.qosRide).waitForCompletion(5000); } catch (MqttException e) { logf("subscribe error: %s", e); }
            }
            @Override public void connectionLost(Throwable cause) { logf("%s cause=%s", tag("disconnect", COL_YELLOW), String.valueOf(cause)); }
            @Override public void messageArrived(String topic, MqttMessage message) {
                long seq = parseSeq(message.getPayload());
                long pubTs = parseTs(message.getPayload());
                long recvTs = System.currentTimeMillis();
                long lat = (pubTs > 0 && recvTs >= pubTs) ? (recvTs - pubTs) : -1;
                if ("/driver/offer".equals(topic)) recvOffer.incrementAndGet();
                else if ("/driver/ride".equals(topic)) recvRide.incrementAndGet();
                logf("%s topic=%s seq=%d qos=%d bytes=%d latency_ms=%d pub_ts_ms=%d recv_ts_ms=%d", tag("recv", COL_GREEN), topic, seq, message.getQos(), message.getPayload().length, lat, pubTs, recvTs);
            }
            @Override public void deliveryComplete(IMqttDeliveryToken token) { /* acked logged via stats */ }
        });

        // Connect with retry to handle startup race with toxiproxy
        int attempts = 0;
        while (true) {
            try {
                cli.connect(opt).waitForCompletion(10000);
                break;
            } catch (MqttException e) {
                attempts++;
                logf("connect attempt %d failed: %s", attempts, e.toString());
                Thread.sleep(2000);
            }
        }

        // Callback will subscribe on connectComplete; messageArrived already logs consumption.

        // Publisher: location (seq + ts in payload)
        ScheduledExecutorService ses = Executors.newSingleThreadScheduledExecutor();
        final long[] published = {0};
        final long[] acked = {0};
        final AtomicLong seq = new AtomicLong();
        ses.scheduleAtFixedRate(() -> {
            try {
                long s = seq.incrementAndGet();
                String prefix = String.format("ts=%d|seq=%d|", System.currentTimeMillis(), s);
                int size = Math.max(0, cfg.payloadLocation - prefix.length());
                String body = prefix + "x".repeat(size);
                byte[] payload = body.getBytes(StandardCharsets.UTF_8);
                logf("%s topic=/driver/location seq=%d bytes=%d pub_ts_ms=%d", tag("publish", COL_MAGENTA), s, payload.length, System.currentTimeMillis());
                cli.publish("/driver/location", payload, cfg.qosLocation, false, null, new IMqttActionListener() {
                    @Override public void onSuccess(IMqttToken asyncActionToken) { acked[0]++; }
                    @Override public void onFailure(IMqttToken asyncActionToken, Throwable exception) { logf("publish error: %s", exception); }
                });
                published[0]++;
            } catch (Exception e) { logf("publish exception: %s", e); }
        }, 0, Math.max(10, cfg.locationEveryMs), TimeUnit.MILLISECONDS);

        // Periodic stats logs (buffer + inflight)
        ScheduledExecutorService stats = Executors.newSingleThreadScheduledExecutor();
        final boolean[] prevConn = { false };
        stats.scheduleAtFixedRate(() -> {
            try {
                int inflight = 0; int queued = 0;
                try { inflight = cli.getInFlightMessageCount(); } catch (Exception ignored) {}
                try { queued = cli.getBufferedMessageCount(); } catch (Exception ignored) {}
                boolean connected = cli.isConnected();
                logf("%s topic=/driver/location pub=%d ack=%d inflight=%d buffered=%d | topic=/driver/offer recv=%d | topic=/driver/ride recv=%d | connected=%s",
                        tag("stats", COL_CYAN), published[0], acked[0], inflight, queued, recvOffer.get(), recvRide.get(), String.valueOf(connected));
                if (prevConn[0] && !connected) logf("connection dead (lost connectivity)");
                if (!prevConn[0] && connected) logf("connection alive (recovered)");
                prevConn[0] = connected;
            } catch (Exception e) { logf("stats error: %s", e); }
        }, 1, 1, TimeUnit.SECONDS);

        // Shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            logf("shutting down...");
            try { ses.shutdownNow(); stats.shutdownNow(); } catch (Exception ignored) {}
            try { if (cli.isConnected()) cli.disconnect(); } catch (Exception ignored) {}
            try { cli.close(); } catch (Exception ignored) {}
            logf("shutdown complete");
        }));

        // Block forever (compose manages lifecycle)
        Thread.currentThread().join();
    }

    private static long parseSeq(byte[] payload){
        try {
            String s = new String(payload, StandardCharsets.UTF_8);
            int i = s.indexOf("seq="); if (i < 0) return -1;
            i += 4; int j = s.indexOf('|', i); if (j < 0) return -1;
            return Long.parseLong(s.substring(i, j));
        } catch (Exception ignored) { return -1; }
    }

    private static long parseTs(byte[] payload){
        try {
            String s = new String(payload, StandardCharsets.UTF_8);
            int i = s.indexOf("ts="); if (i < 0) return -1;
            i += 3; int j = s.indexOf('|', i); if (j < 0) return -1;
            return Long.parseLong(s.substring(i, j));
        } catch (Exception ignored) { return -1; }
    }

    private static void startProfilingServer() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(6061), 0);
        server.createContext("/healthz", h -> {
            byte[] b = "ok".getBytes(StandardCharsets.UTF_8);
            h.sendResponseHeaders(200, b.length); h.getResponseBody().write(b); h.close();
        });
        server.createContext("/profiling/threads", h -> {
            ThreadMXBean mx = ManagementFactory.getThreadMXBean();
            ThreadInfo[] infos = mx.dumpAllThreads(true, true);
            StringBuilder sb = new StringBuilder();
            for (ThreadInfo ti : infos) sb.append(ti.toString()).append("\n");
            byte[] b = sb.toString().getBytes(StandardCharsets.UTF_8);
            h.getResponseHeaders().add("Content-Type","text/plain");
            h.sendResponseHeaders(200, b.length); h.getResponseBody().write(b); h.close();
        });
        // JFR start/stop endpoints (best-effort)
        server.createContext("/profiling/jfr/start", h -> {
            try {
                String q = Optional.ofNullable(h.getRequestURI().getQuery()).orElse("");
                Map<String,String> p = parseQuery(q);
                String name = p.getOrDefault("name", "run");
                int dur = Integer.parseInt(p.getOrDefault("durationSec", "60"));
                JFR.start(name, dur);
                byte[] b = ("JFR started: "+name+" durationSec="+dur).getBytes(StandardCharsets.UTF_8);
                h.sendResponseHeaders(200, b.length); h.getResponseBody().write(b);
            } catch (Throwable t) {
                byte[] b = ("JFR start error: "+t).getBytes(StandardCharsets.UTF_8);
                h.sendResponseHeaders(500, b.length); h.getResponseBody().write(b);
            } finally { h.close(); }
        });
        server.createContext("/profiling/jfr/stop", h -> {
            try {
                String q = Optional.ofNullable(h.getRequestURI().getQuery()).orElse("");
                Map<String,String> p = parseQuery(q);
                String name = p.getOrDefault("name", "run");
                String path = JFR.stop(name);
                byte[] b = ("JFR stopped: "+name+" path="+path).getBytes(StandardCharsets.UTF_8);
                h.sendResponseHeaders(200, b.length); h.getResponseBody().write(b);
            } catch (Throwable t) {
                byte[] b = ("JFR stop error: "+t).getBytes(StandardCharsets.UTF_8);
                h.sendResponseHeaders(500, b.length); h.getResponseBody().write(b);
            } finally { h.close(); }
        });
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        logf("profiling server listening on :6061");
    }

    private static Map<String,String> parseQuery(String q) {
        Map<String,String> m = new HashMap<>();
        for (String s: q.split("&")){
            if (s.isEmpty()) continue; int i=s.indexOf('=');
            if (i<0) m.put(s, ""); else m.put(s.substring(0,i), s.substring(i+1));
        }
        return m;
    }
}

// Minimal JFR control (Java 11+). If unavailable, calls will throw and be handled.
class JFR {
    private static final Map<String, Object> recs = new ConcurrentHashMap<>();
    public static void start(String name, int durationSec) throws Exception {
        Class<?> C = Class.forName("jdk.jfr.Recording");
        Object r = C.getConstructor().newInstance();
        C.getMethod("setName", String.class).invoke(r, name);
        C.getMethod("start").invoke(r);
        recs.put(name, r);
        if (durationSec > 0) Executors.newSingleThreadScheduledExecutor().schedule(() -> {
            try { stop(name); } catch (Exception ignored) {}
        }, durationSec, TimeUnit.SECONDS);
    }
    public static String stop(String name) throws Exception {
        Object r = recs.remove(name); if (r == null) throw new IllegalStateException("no such JFR: "+name);
        File f = File.createTempFile("jfr-"+name+"-", ".jfr");
        Class<?> C = Class.forName("jdk.jfr.Recording");
        C.getMethod("dump", java.nio.file.Path.class).invoke(r, f.toPath());
        C.getMethod("close").invoke(r);
        return f.getAbsolutePath();
    }
}
