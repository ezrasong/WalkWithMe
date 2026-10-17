package app.kaze.shared;

import android.app.Activity;
import android.content.Context;
import android.app.NotificationManager;
import android.app.NotificationChannel;
import android.os.SystemClock;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.util.ReflectionHelpers;
import org.robolectric.Shadows;
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
    public static class TestWatchService extends TestService {
        protected boolean isWatch() { return true; }
    }
    private Context context;
    private ServerSocket server;
    private ExecutorService serverWorker;
    private final List<String> requests = new CopyOnWriteArrayList<>();
    private volatile boolean resolved;
    private Config config;
    @Before public void setup() throws Exception {
        context = RuntimeEnvironment.getApplication(); context.deleteDatabase("outbox.db");
        MonitoringService.noteWatchContact("");
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
    private void responseDue(MonitoringService service) {
        service.config = config;
        Config.prefs(context).edit().putLong("dueAt", System.currentTimeMillis() - 1000).commit();
        ReflectionHelpers.callInstanceMethod(service, "remind");
    }
    @Test public void withoutAnActiveWatchThePhonePostsAVibrationAndSoundEnabledReminder() {
        var controller = Robolectric.buildService(TestService.class).create();
        responseDue(controller.get());
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        assertNotNull(Shadows.shadowOf(manager).getNotification(2));
        NotificationChannel channel = manager.getNotificationChannel(MonitoringService.RESPONSE_CHANNEL);
        assertNotNull(channel.getSound());
        assertTrue(channel.shouldVibrate());
        assertArrayEquals(new long[]{0, 350, 200, 350, 200, 600}, channel.getVibrationPattern());
        // Wear OS's local notification collector reads these compatibility
        // fields even when the Android framework resolves the channel itself.
        var posted = Shadows.shadowOf(manager).getNotification(2);
        assertArrayEquals(channel.getVibrationPattern(), posted.vibrate);
        assertEquals(channel.getSound(), posted.sound);
        assertTrue(MonitoringService.remindersAvailable(context));
        controller.destroy();
    }
    @Test public void activeWatchSuppressesPhoneUntilContactIsStaleButDoesNotSuppressItself() {
        var phone = Robolectric.buildService(TestService.class).create();
        MonitoringService.noteWatchContact(config.id);
        responseDue(phone.get());
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        assertNull(Shadows.shadowOf(manager).getNotification(2));
        ReflectionHelpers.setStaticField(MonitoringService.class, "watchSeenAt", SystemClock.elapsedRealtime() - 20000);
        responseDue(phone.get());
        assertNotNull(Shadows.shadowOf(manager).getNotification(2));
        phone.destroy(); manager.cancel(2);
        var watch = Robolectric.buildService(TestWatchService.class).create();
        MonitoringService.noteWatchContact(config.id);
        responseDue(watch.get());
        assertNotNull(Shadows.shadowOf(manager).getNotification(2));
        watch.destroy();
    }
    @Test public void anotherSessionWatchCannotSuppressThisPhonesReminder() {
        var phone = Robolectric.buildService(TestService.class).create();
        MonitoringService.noteWatchContact("bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee");
        responseDue(phone.get());
        assertNotNull(Shadows.shadowOf(context.getSystemService(NotificationManager.class)).getNotification(2));
        phone.destroy();
    }
    @Test public void aBlockedReminderChannelDoesNotPostAnAlert() {
        var phone = Robolectric.buildService(TestService.class).create();
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.deleteNotificationChannel(MonitoringService.RESPONSE_CHANNEL);
        manager.createNotificationChannel(new NotificationChannel(MonitoringService.RESPONSE_CHANNEL, "Check-in response due", NotificationManager.IMPORTANCE_NONE));
        responseDue(phone.get());
        assertFalse(MonitoringService.remindersAvailable(context));
        assertNull(Shadows.shadowOf(manager).getNotification(2));
        phone.destroy();
    }
    @Test public void reminderChannelMigrationPreservesBlockedImportanceAndMutedSound() {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel previous = new NotificationChannel("response", "Old check-in reminders", NotificationManager.IMPORTANCE_NONE);
        previous.setSound(null, null);
        manager.createNotificationChannel(previous);
        var phone = Robolectric.buildService(TestService.class).create();
        NotificationChannel channel = manager.getNotificationChannel(MonitoringService.RESPONSE_CHANNEL);
        assertEquals(NotificationManager.IMPORTANCE_NONE, channel.getImportance());
        assertNull(channel.getSound());
        assertFalse(MonitoringService.remindersAvailable(context));
        phone.destroy();
    }
    @Test public void compatibilityFieldsCannotUnmuteAnExistingQuietChannel() {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel quiet = new NotificationChannel(MonitoringService.RESPONSE_CHANNEL, "Check-in response due", NotificationManager.IMPORTANCE_HIGH);
        quiet.setSound(null, null); quiet.enableVibration(false);
        manager.createNotificationChannel(quiet);
        var phone = Robolectric.buildService(TestService.class).create();
        responseDue(phone.get());
        var posted = Shadows.shadowOf(manager).getNotification(2);
        assertNotNull(posted); assertNull(posted.sound); assertNull(posted.vibrate);
        phone.destroy();
    }
}
