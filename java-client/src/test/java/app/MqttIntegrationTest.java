package app;

import org.eclipse.paho.client.mqttv3.*;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

public class MqttIntegrationTest {
    @Test
    public void pubSubRoundTrip() throws Exception {
        String broker = System.getenv().getOrDefault("TEST_MQTT_BROKER", "");
        Assumptions.assumeTrue(!broker.isEmpty(), "TEST_MQTT_BROKER not set");
        String clientId = "java-int-" + UUID.randomUUID();
        String topic = "test/java-int/" + UUID.randomUUID();

        MqttAsyncClient cli = new MqttAsyncClient(broker, clientId);
        MqttConnectOptions opt = new MqttConnectOptions();
        opt.setMqttVersion(MqttConnectOptions.MQTT_VERSION_3_1);
        opt.setKeepAliveInterval(15);
        cli.connect(opt).waitForCompletion(10000);

        BlockingQueue<MqttMessage> q = new ArrayBlockingQueue<>(1);
        cli.setCallback(new MqttCallbackExtended() {
            @Override public void connectComplete(boolean reconnect, String serverURI) {}
            @Override public void connectionLost(Throwable cause) {}
            @Override public void messageArrived(String t, MqttMessage message) { q.offer(message); }
            @Override public void deliveryComplete(IMqttDeliveryToken token) {}
        });
        cli.subscribe(topic, 0).waitForCompletion(5000);
        cli.publish(topic, "hello".getBytes(), 0, false).waitForCompletion(5000);
        MqttMessage msg = q.poll(5, TimeUnit.SECONDS);
        assertNotNull(msg, "did not receive published message");
        cli.disconnect().waitForCompletion(2000);
        cli.close();
    }
}

