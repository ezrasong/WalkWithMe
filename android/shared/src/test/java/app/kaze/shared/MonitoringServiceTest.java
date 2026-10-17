package app.kaze.shared;

import android.app.Activity;
import android.content.Context;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.util.ReflectionHelpers;
import java.net.ServerSocket;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.CopyOnWriteArrayList;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk = 28)
public class MonitoringServiceTest {
    public static class TestService extends MonitoringService {
        protected boolean isWatch() { return false; }
        protected Class<?> activityClass() { return Activity.class; }
    }
    private Context context;
    private ServerSocket server;
    private ExecutorService serverWorker;
    private final List<String> requests = new CopyOnWriteArrayList<>();
    private volatile boolean resolved;
    private Config config;
    @Before public void setup() throws Exception {
        context = RuntimeEnvironment.getApplication(); context.deleteDatabase("outbox.db");
        Config.prefs(context).edit().clear().putBoolean("active", true).commit();
        server = new ServerSocket(0); serverWorker = Executors.newSingleThreadExecutor();
        serverWorker.submit(() -> {
            while (!server.isClosed()) {
                try (var client = server.accept()) {
                    var input = client.getInputStream(); StringBuilder headers = new StringBuilder(); int value;
                    while ((value = input.read()) != -1) { headers.append((char)value); if (headers.toString().endsWith("\r\n\r\n")) break; }
                    String method = headers.toString().split(" ")[0]; requests.add(method);
                    int length = 0; for (String line : headers.toString().split("\r\n")) if (line.toLowerCase().startsWith("content-length:")) length = Integer.parseInt(line.split(":",2)[1].trim());
                    for (int i = 0; i < length; i++) if (input.read() == -1) break;
                    String response = method.equals("GET") ? "{\"serverNow\":" + System.currentTimeMillis() + ",\"dueAt\":9999999999999,\"phase\":\"" + (resolved ? "resolved" : "armed") + "\"}" : "{\"error\":\"Rejected camera evidence\"}";
                    byte[] bytes = response.getBytes(StandardCharsets.UTF_8);
                    client.getOutputStream().write(("HTTP/1.1 " + (method.equals("GET") ? "200 OK" : "400 Bad Request") + "\r\nContent-Type: application/json\r\nContent-Length: " + bytes.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.UTF_8));
                    client.getOutputStream().write(bytes);
                } catch (java.io.IOException e) { if (!server.isClosed()) throw new RuntimeException(e); }
            }
        });
        config = new Config(new JSONObject().put("baseUrl", "http://127.0.0.1:" + server.getLocalPort()).put("id", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            .put("ownerToken", "owner-0123456789012345678901234567890123456789").put("watchToken", "watch-0123456789012345678901234567890123456789").toString(), false);
    }
    @After public void cleanup() throws Exception { server.close(); serverWorker.shutdownNow(); }
    @Test public void endedSessionIsCheckedBeforeQueuedEvidenceAndLateSensorCallbacksAreIgnored() throws Exception {
        resolved = true;
        var controller = Robolectric.buildService(TestService.class).create(); TestService service = controller.get();
        Outbox box = new Outbox(context); box.add(config, "camera", new JSONObject().put("type", "checkpoint"));
        service.config = config; ReflectionHelpers.setField(service, "outbox", box);
        ReflectionHelpers.callInstanceMethod(service, "sync");
        assertEquals(List.of("GET"), requests); assertFalse(Config.prefs(context).getBoolean("active", true)); assertEquals(0, box.count(config.id));
        service.emit("phone", new JSONObject().put("type", "step").put("heading", 0));
        assertEquals(0, box.count(config.id)); controller.destroy(); box.close();
    }
    @Test public void rejectedCameraBatchCannotPreventNextSessionControlCheck() throws Exception {
        var controller = Robolectric.buildService(TestService.class).create(); TestService service = controller.get();
        Outbox box = new Outbox(context); box.add(config, "camera", new JSONObject().put("type", "checkpoint"));
        service.config = config; ReflectionHelpers.setField(service, "outbox", box);
        ReflectionHelpers.callInstanceMethod(service, "sync");
        assertEquals(List.of("GET", "POST"), requests); assertTrue(Config.prefs(context).getBoolean("active", false)); assertTrue(box.count(config.id) > 0);
        resolved = true; ReflectionHelpers.callInstanceMethod(service, "sync");
        assertEquals(List.of("GET", "POST", "GET"), requests); assertFalse(Config.prefs(context).getBoolean("active", true)); assertEquals(0, box.count(config.id));
        controller.destroy(); box.close();
    }
}
