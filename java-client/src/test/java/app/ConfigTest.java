package app;

import org.junit.jupiter.api.Test;

import java.io.File;
import java.io.FileWriter;
import java.nio.file.Files;

import static org.junit.jupiter.api.Assertions.*;

public class ConfigTest {
    private File writeTemp(String content) throws Exception {
        File f = Files.createTempFile("client-", ".yaml").toFile();
        try (FileWriter w = new FileWriter(f)) { w.write(content); }
        return f;
    }

    @Test
    public void loadsDefaults() throws Exception {
        File f = writeTemp("""
            mqtt:
              host: test
              port: 1883
              client_id: cid
            retry:
              enabled: true
            """);
        Config c = Config.load(f.getAbsolutePath());
        assertEquals(15, c.keepAlive, "default keepalive");
        assertEquals("cid", c.clientId);
        assertEquals(1883, c.port);
        assertFalse(c.separatePubSubConnections, "default separate_pubsub_connections");
    }

    @Test
    public void parsesValues() throws Exception {
        File f = writeTemp("""
            mqtt:
              host: h
              port: 1999
              client_id: x
              keepalive_secs: 20
              separate_pubsub_connections: true
            publish:
              location_every_ms: 250
            qos:
              location: 2
              offer: 1
              ride: 0
            payload_bytes:
              location: 64
            buffer_inflight:
              max_inflight: 10
            """);
        Config c = Config.load(f.getAbsolutePath());
        assertEquals(20, c.keepAlive);
        assertEquals(250, c.locationEveryMs);
        assertEquals(10, c.maxInflight);
        assertEquals(64, c.payloadLocation);
        assertTrue(c.separatePubSubConnections, "parses separate_pubsub_connections");
    }
}
