package app.kaze.shared;

import android.app.NotificationManager;
import android.app.NotificationChannel;
import android.content.Context;
import android.os.SystemClock;
import android.provider.Settings;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.*;
import org.robolectric.util.ReflectionHelpers;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk = 28)
public class GuardianServiceTest {
    private Context context;
    private ServerSocket server;
    private ExecutorService worker;
    private volatile String phase = "armed", role = "guardian";
    private volatile int status = 200;
    private volatile boolean acknowledged;
    private volatile CountDownLatch entered, release;
    private String raw;
    private static final String ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    @Before public void setup() throws Exception {
        context = RuntimeEnvironment.getApplication();
        GuardianService.prefs(context).edit().clear().commit(); Config.prefs(context).edit().clear().commit();
        server = new ServerSocket(0); worker = Executors.newSingleThreadExecutor();
        worker.submit(() -> {
            while (!server.isClosed()) {
                try (var client = server.accept()) {
                    client.setSoTimeout(5000);
                    StringBuilder headers = new StringBuilder(); int value;
                    while ((value = client.getInputStream().read()) != -1) {
                        headers.append((char)value); if (headers.toString().endsWith("\r\n\r\n")) break;
                    }
                    if (entered != null) { entered.countDown(); release.await(5, TimeUnit.SECONDS); }
                    boolean authorized = headers.toString().startsWith("GET /api/sessions/" + ID + "/guardian-status ") &&
                        headers.toString().contains("Bearer guardian-0123456789012345678901234567890");
                    long now = System.currentTimeMillis();
                    String response = new JSONObject().put("id", ID).put("role", role).put("phase", phase)
                        .put("serverNow", now).put("expiresAt", now + 60000)
                        .put("acknowledgedAt", acknowledged ? now : JSONObject.NULL).toString();
                    byte[] bytes = response.getBytes(StandardCharsets.UTF_8);
                    int code = authorized ? status : 401;
                    client.getOutputStream().write(("HTTP/1.1 " + code + " Response\r\nContent-Type: application/json\r\nContent-Length: " + bytes.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.UTF_8));
                    client.getOutputStream().write(bytes);
                } catch (Exception e) { if (!server.isClosed()) throw new RuntimeException(e); }
            }
        });
        raw = new JSONObject().put("baseUrl", "http://127.0.0.1:" + server.getLocalPort()).put("id", ID)
            .put("guardianToken", "guardian-0123456789012345678901234567890").toString();
    }
    @After public void cleanup() throws Exception {
        if (release != null) release.countDown();
        server.close(); worker.shutdownNow(); GuardianService.disable(context);
    }
    private GuardianService create() throws Exception {
        GuardianService.enable(context, raw);
        return Robolectric.buildService(GuardianService.class).create().get();
    }
    private void sync(GuardianService service) { ReflectionHelpers.callInstanceMethod(service, "sync"); }
    private android.app.Notification notification(int id) {
        return Shadows.shadowOf(context.getSystemService(NotificationManager.class)).getNotification(id);
    }
    @Test public void onlyConfirmedUnacknowledgedNonresponsePostsOnePrivateAlertAcrossRestarts() throws Exception {
        GuardianService service = create(); sync(service);
        assertNull(notification(GuardianService.ALERT_ID));
        phase = "challenge"; sync(service); assertNull(notification(GuardianService.ALERT_ID));
        phase = "alert"; sync(service);
        var alert = notification(GuardianService.ALERT_ID); assertNotNull(alert);
        assertEquals(android.app.Notification.VISIBILITY_PRIVATE, alert.visibility);
        assertFalse(alert.extras.toString().contains("guardian-"));
        context.getSystemService(NotificationManager.class).cancel(GuardianService.ALERT_ID);
        service.onDestroy();
        GuardianService restarted = Robolectric.buildService(GuardianService.class).create().get();
        sync(restarted); assertNull(notification(GuardianService.ALERT_ID));
        assertTrue(GuardianService.enabled(context)); restarted.onDestroy();
    }
    @Test public void offlineIsASeparateWarningAndRecoveryStillDeliversTheSafetyAlert() throws Exception {
        GuardianService service = create(); phase = "alert"; status = 503; sync(service);
        assertNull(notification(GuardianService.ALERT_ID)); assertNotNull(notification(GuardianService.OFFLINE_ID));
        status = 200; sync(service);
        assertNull(notification(GuardianService.OFFLINE_ID)); assertNotNull(notification(GuardianService.ALERT_ID));
        acknowledged = true; sync(service); assertNull(notification(GuardianService.ALERT_ID));
        service.onDestroy();
    }
    @Test public void invalidRoleCannotProduceASafetyAlert() throws Exception {
        GuardianService service = create(); phase = "alert"; role = "owner"; sync(service);
        assertNull(notification(GuardianService.ALERT_ID)); assertNotNull(notification(GuardianService.OFFLINE_ID));
        service.onDestroy();
    }
    @Test public void revokedDeletedResolvedAndExpiredSessionsRemovePrivateAccessAndNotifications() throws Exception {
        for (int code : new int[]{401, 404}) {
            GuardianService service = create(); status = code; sync(service);
            assertFalse(GuardianService.enabled(context)); assertFalse(GuardianService.prefs(context).contains("config"));
            assertNull(notification(GuardianService.ALERT_ID)); service.onDestroy();
        }
        status = 200; GuardianService service = create(); phase = "resolved"; sync(service);
        assertFalse(GuardianService.prefs(context).contains("config")); service.onDestroy();
        phase = "alert"; service = create(); status = 503;
        GuardianService.prefs(context).edit().putLong("expiresElapsed", SystemClock.elapsedRealtime() - 1).commit();
        sync(service); assertFalse(GuardianService.prefs(context).contains("config"));
        assertNull(notification(GuardianService.ALERT_ID)); service.onDestroy();
    }
    @Test public void aRemovedLinkCannotPostALateResponseOrRestoreMonitoring() throws Exception {
        GuardianService service = create(); phase = "alert";
        entered = new CountDownLatch(1); release = new CountDownLatch(1);
        ExecutorService request = Executors.newSingleThreadExecutor();
        try {
            Future<?> pending = request.submit(() -> sync(service));
            assertTrue(entered.await(5, TimeUnit.SECONDS)); GuardianService.disable(context);
            release.countDown(); pending.get(5, TimeUnit.SECONDS);
            assertNull(notification(GuardianService.ALERT_ID)); assertNull(notification(GuardianService.MONITOR_ID));
            assertFalse(GuardianService.enabled(context)); assertFalse(GuardianService.prefs(context).contains("config"));
        } finally { request.shutdownNow(); service.onDestroy(); }
    }
    @Test @org.robolectric.annotation.Config(sdk = 35)
    public void android15StartsAVisibleServiceWithoutGuardianSensorPermissions() throws Exception {
        GuardianService service = create();
        assertEquals(android.app.Service.START_STICKY, service.onStartCommand(new android.content.Intent(), 0, 1));
        assertNotNull(notification(GuardianService.MONITOR_ID));
        assertTrue((boolean)GuardianService.status(context).get("running"));
        assertFalse(Config.prefs(context).getBoolean("active", false));
        service.onDestroy();
    }
    @Test public void anUnconfiguredRestartCannotMonitorOrRetainCredentials() {
        GuardianService service = Robolectric.buildService(GuardianService.class).create().get();
        assertEquals(android.app.Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1));
        assertFalse(GuardianService.enabled(context)); assertFalse(GuardianService.prefs(context).contains("config"));
        service.onDestroy();
    }
    @Test public void blockedChannelsAndActiveWearerRecordingCannotEnableGuardianMonitoring() throws Exception {
        GuardianService.status(context);
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.deleteNotificationChannel(GuardianService.ALERT_CHANNEL);
        manager.createNotificationChannel(new NotificationChannel(GuardianService.ALERT_CHANNEL, "Blocked", NotificationManager.IMPORTANCE_NONE));
        assertThrows(IllegalStateException.class, () -> GuardianService.enable(context, raw));
        assertFalse(GuardianService.enabled(context));
        manager.deleteNotificationChannel(GuardianService.ALERT_CHANNEL);
        manager.createNotificationChannel(new NotificationChannel(GuardianService.ALERT_CHANNEL, "Allowed", NotificationManager.IMPORTANCE_HIGH));
        Config.prefs(context).edit().putBoolean("active", true).commit();
        assertThrows(IllegalStateException.class, () -> GuardianService.enable(context, raw));
        assertFalse(GuardianService.enabled(context));
    }
}
