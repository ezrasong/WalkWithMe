package app.kaze.shared;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.os.*;
import android.provider.Settings;
import org.json.JSONObject;
import java.util.HashMap;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** Opt-in Android guardian polling. Never records sensors or acknowledges an alert. */
public final class GuardianService extends Service {
    static final String MONITOR_CHANNEL = "guardian-monitoring", ALERT_CHANNEL = "guardian-alerts";
    static final int MONITOR_ID = 40, ALERT_ID = 41, OFFLINE_ID = 42;
    private static final String STOP = "app.kaze.STOP_GUARDIAN";
    private static final Object LOCK = new Object();
    private static volatile boolean running;
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private volatile boolean stopping;
    private boolean scheduled;
    private PowerManager.WakeLock wake;

    static SharedPreferences prefs(Context c) { return c.getSharedPreferences("kaze-guardian", MODE_PRIVATE); }
    private static int boot(Context c) { return Settings.Global.getInt(c.getContentResolver(), Settings.Global.BOOT_COUNT, -1); }
    private static void channels(Context c) {
        NotificationManager manager = c.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(MONITOR_CHANNEL, "Guardian monitoring status", NotificationManager.IMPORTANCE_LOW));
        NotificationChannel alerts = new NotificationChannel(ALERT_CHANNEL, "Guardian safety alerts", NotificationManager.IMPORTANCE_HIGH);
        alerts.enableVibration(true);
        manager.createNotificationChannel(alerts);
    }
    public static boolean enabled(Context c) { return prefs(c).getBoolean("enabled", false); }
    private static boolean alertsAvailable(Context c) {
        NotificationManager manager = c.getSystemService(NotificationManager.class);
        NotificationChannel channel = manager.getNotificationChannel(ALERT_CHANNEL);
        return manager.areNotificationsEnabled() && channel != null && channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
    }
    public static void enable(Context c, String raw) throws Exception {
        Config.guardian(raw); // A guardian credential is required; no owner/watch alias.
        channels(c);
        if (!alertsAvailable(c)) throw new IllegalStateException("Allow WalkWithMe guardian notifications in Android Settings first.");
        synchronized (LOCK) {
            if (Config.prefs(c).getBoolean("active", false)) throw new IllegalStateException("End wearer recording before enabling guardian alerts.");
            // Launch first: Android may reject a foreground-service start. Do not
            // persist an enabled setting when the platform refuses to start it.
            c.startForegroundService(new Intent(c, GuardianService.class));
            if (!enabled(c) || !raw.equals(prefs(c).getString("config", ""))) {
                prefs(c).edit().clear().putString("config", raw).putString("generation", UUID.randomUUID().toString())
                    .putBoolean("enabled", true).putInt("boot", boot(c))
                    .putLong("expiresElapsed", SystemClock.elapsedRealtime() + 8 * 3600000L)
                    .putString("status", "Connecting. Background monitoring is not yet confirmed.").commit();
                c.getSystemService(NotificationManager.class).cancel(ALERT_ID);
                c.getSystemService(NotificationManager.class).cancel(OFFLINE_ID);
            }
        }
    }
    public static void disable(Context c) { disable(c, "Background guardian alerts off. Keep WalkWithMe open for updates."); }
    private static void disable(Context c, String reason) {
        synchronized (LOCK) {
            prefs(c).edit().clear().putString("status", reason).commit();
            NotificationManager manager = c.getSystemService(NotificationManager.class);
            manager.cancel(MONITOR_ID); manager.cancel(ALERT_ID); manager.cancel(OFFLINE_ID);
            c.stopService(new Intent(c, GuardianService.class));
        }
    }
    public static HashMap<String, Object> status(Context c) {
        channels(c);
        synchronized (LOCK) {
            var p = prefs(c); var result = new HashMap<String, Object>();
            result.put("enabled", enabled(c)); result.put("running", running);
            result.put("notificationsAllowed", alertsAvailable(c));
            result.put("lastSync", p.getLong("lastSync", 0));
            result.put("status", p.getString("status", "Background guardian alerts off. Keep WalkWithMe open for updates."));
            try { result.put("sessionId", Config.guardian(p.getString("config", "")).id); } catch (Exception ignored) {}
            return result;
        }
    }
    @Override public void onCreate() { super.onCreate(); channels(this); running = true; }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) { disable(this); return START_NOT_STICKY; }
        synchronized (LOCK) {
            if (!enabled(this) || prefs(this).getInt("boot", -1) != boot(this)) {
                disable(this, "Reopen WalkWithMe and enable guardian alerts to confirm access."); stopSelf(); return START_NOT_STICKY;
            }
            Notification note = notification("Guardian monitoring starting", MONITOR_CHANNEL, true);
            if (Build.VERSION.SDK_INT >= 29) startForeground(MONITOR_ID, note,
                Build.VERSION.SDK_INT >= 34 ? ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE : 0);
            else startForeground(MONITOR_ID, note);
            if (!scheduled) {
                scheduled = true;
                wake = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kaze:guardian-monitoring");
                wake.acquire(8 * 3600000L);
                worker.scheduleWithFixedDelay(this::sync, 0, 5, TimeUnit.SECONDS);
            }
        }
        return START_STICKY;
    }
    private boolean current(String generation) {
        return !stopping && enabled(this) && generation.equals(prefs(this).getString("generation", ""));
    }
    private void sync() {
        final String generation;
        final Config config;
        synchronized (LOCK) {
            if (stopping || !enabled(this)) return;
            if (SystemClock.elapsedRealtime() >= prefs(this).getLong("expiresElapsed", 0) ||
                prefs(this).getInt("boot", -1) != boot(this)) {
                disable(this, "Guardian session expired. Monitoring stopped and saved access removed."); return;
            }
            generation = prefs(this).getString("generation", "");
            try { config = Config.guardian(prefs(this).getString("config", "")); }
            catch (Exception e) { disable(this, "Guardian access unavailable. Rejoin using a current invitation."); return; }
        }
        try {
            long started = SystemClock.elapsedRealtime();
            JSONObject data = Transport.request(config, "guardian-status", null);
            synchronized (LOCK) {
                if (!current(generation)) return; // A removed/replaced link cannot post a late notification.
                if (!config.id.equals(data.getString("id")) || !"guardian".equals(data.getString("role")))
                    throw new IllegalStateException("Invalid guardian response");
                String phase = data.getString("phase");
                if (!java.util.List.of("armed", "challenge", "alert", "resolved").contains(phase))
                    throw new IllegalStateException("Invalid guardian phase");
                long remaining = data.getLong("expiresAt") - data.getLong("serverNow") - (SystemClock.elapsedRealtime() - started);
                if (remaining <= 0 || "resolved".equals(phase)) {
                    disable(this, "Guardian session ended or expired. Monitoring stopped and saved access removed."); return;
                }
                if (remaining > 24 * 3600000L) throw new IllegalStateException("Invalid session lifetime");
                var p = prefs(this);
                p.edit().putLong("expiresElapsed", Math.min(p.getLong("expiresElapsed", 0), SystemClock.elapsedRealtime() + remaining))
                    .putLong("lastSync", System.currentTimeMillis()).putBoolean("offlineNotified", false).apply();
                NotificationManager manager = getSystemService(NotificationManager.class);
                manager.cancel(OFFLINE_ID);
                boolean acknowledged = !data.isNull("acknowledgedAt");
                if (acknowledged) { manager.cancel(ALERT_ID); p.edit().putBoolean("alertNotified", true).apply(); }
                if ("alert".equals(phase) && !acknowledged && !p.getBoolean("alertNotified", false) && alertsAvailable(this)) {
                    manager.notify(ALERT_ID, notification("A check-in went unanswered. Open WalkWithMe to review the request.", ALERT_CHANNEL, false));
                    p.edit().putBoolean("alertNotified", true).commit();
                }
                String message = !alertsAvailable(this) ? "Guardian notifications blocked. Open Android notification settings." :
                    "alert".equals(phase) ? "Unanswered check-in. Open WalkWithMe to review." : "Monitoring guardian session in the background";
                p.edit().putString("status", message).apply();
                manager.notify(MONITOR_ID, notification(message, MONITOR_CHANNEL, true));
            }
        } catch (Exception e) {
            synchronized (LOCK) {
                if (!current(generation)) return;
                if (e instanceof Transport.HttpError && (((Transport.HttpError)e).status == 401 || ((Transport.HttpError)e).status == 404)) {
                    disable(this, "Guardian access expired, deleted or revoked. Monitoring stopped and saved access removed."); return;
                }
                String message = "Guardian connection unavailable. Alert delivery is not confirmed.";
                prefs(this).edit().putString("status", message).apply();
                NotificationManager manager = getSystemService(NotificationManager.class);
                manager.notify(MONITOR_ID, notification(message, MONITOR_CHANNEL, true));
                if (!prefs(this).getBoolean("offlineNotified", false) && alertsAvailable(this)) {
                    manager.notify(OFFLINE_ID, notification(message, ALERT_CHANNEL, false));
                    prefs(this).edit().putBoolean("offlineNotified", true).apply();
                }
            }
        }
    }
    private Notification notification(String text, String channel, boolean ongoing) {
        Notification.Builder builder = new Notification.Builder(this, channel)
            .setSmallIcon(android.R.drawable.ic_dialog_alert).setContentTitle("WalkWithMe guardian - simulation")
            .setContentText(text).setStyle(new Notification.BigTextStyle().bigText(text))
            .setVisibility(Notification.VISIBILITY_PRIVATE).setOnlyAlertOnce(true).setOngoing(ongoing).setAutoCancel(!ongoing);
        Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (open != null) builder.setContentIntent(PendingIntent.getActivity(this, 40, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        if (ongoing) builder.addAction(new Notification.Action.Builder(null, "Stop monitoring",
            PendingIntent.getService(this, 40, new Intent(this, GuardianService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT)).build());
        return builder.build();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onDestroy() {
        synchronized (LOCK) { stopping = true; running = false; }
        worker.shutdownNow();
        if (wake != null && wake.isHeld()) wake.release();
        super.onDestroy();
    }
}
