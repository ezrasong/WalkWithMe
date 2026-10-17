package app.kaze.shared;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public abstract class MonitoringService extends Service implements SensorRecorder.Sink {
    public static final String RESPOND = "app.kaze.RESPOND", END = "app.kaze.END", EVENT = "app.kaze.EVENT", REFRESH = "app.kaze.REFRESH";
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private SensorRecorder recorder;
    private LocationRecorder locations;
    private Outbox outbox;
    protected Config config;
    private PowerManager.WakeLock wake;
    private volatile boolean stopping;
    private long notifiedDeadline, lastHeartbeat;
    private final Handler reminderHandler = new Handler(Looper.getMainLooper());
    private final Runnable reminderTask = new Runnable() { public void run() { remind(); reminderHandler.postDelayed(this, 1000); } };
    private JSONArray available = new JSONArray();
    protected abstract boolean isWatch();
    protected abstract Class<?> activityClass();
    @Override public void onCreate() {
        super.onCreate();
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("recording", "Active safety session", NotificationManager.IMPORTANCE_LOW));
        manager.createNotificationChannel(new NotificationChannel("response", "Check-in response due", NotificationManager.IMPORTANCE_HIGH));
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (config == null) {
            if (intent != null && EVENT.equals(intent.getAction()) && !Config.prefs(this).getBoolean("active", false)) { stopSelf(); return START_NOT_STICKY; }
            config = Config.load(this, isWatch());
            if (config == null || (intent == null && !Config.prefs(this).getBoolean("active", false))) { stopSelf(); return START_NOT_STICKY; }
            Notification recording = notification("Safety session active · location when available", "recording", false);
            if (Build.VERSION.SDK_INT >= 29) {
                int type = Build.VERSION.SDK_INT >= 34 ? android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE : 0;
                if (LocationRecorder.permitted(this)) type |= android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION;
                startForeground(1, recording, type);
            } else startForeground(1, recording);
            Config.prefs(this).edit().putBoolean("active", true).apply();
            if (isWatch()) WatchPairing.finishStart();
            outbox = new Outbox(this); recorder = new SensorRecorder(this, config, this); available = recorder.start();
            locations = new LocationRecorder(this, config, this); locations.start();
            wake = ((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kaze:armed-trail"); wake.acquire(8 * 60 * 60 * 1000L);
            worker.scheduleWithFixedDelay(this::sync, 0, 5, TimeUnit.SECONDS);
            reminderHandler.post(reminderTask);
        }
        String action = intent == null ? "" : intent.getAction();
        if (REFRESH.equals(action)) worker.execute(this::sync);
        if (RESPOND.equals(action) || END.equals(action)) worker.execute(() -> {
            try {
                long started = System.currentTimeMillis();
                JSONObject result = Transport.send(this, config, END.equals(action) ? "resolve" : "check-in", new JSONObject().put("confirm", true));
                Transport.saveClock(this, result, started);
                if (END.equals(action)) stopConfirmed(); else { status("Check-in confirmed by server"); getSystemService(NotificationManager.class).cancel(2); }
            } catch (Exception e) { status("Not confirmed: " + e.getMessage() + ". Server countdown may still be active."); }
        });
        if (EVENT.equals(action)) {
            try { emit(intent.getStringExtra("source") == null ? "camera" : intent.getStringExtra("source"), new JSONObject(intent.getStringExtra("event"))); } catch (Exception e) { status("Evidence sample not saved"); }
        }
        return START_STICKY;
    }
    private void sync() {
        if (stopping) return;
        long expiry = Config.prefs(this).getLong("expiresAt", 0);
        if (expiry > 0 && Transport.serverNow(this) >= expiry) {
            status("Session expired. Local queued readings deleted."); stopConfirmed(); return;
        }
        try {
            // Session control must remain reachable even when an evidence batch is rejected.
            long started = System.currentTimeMillis();
            JSONObject result = Transport.send(this, config, "", null);
            Transport.saveClock(this, result, started);
            if ("resolved".equals(result.optString("phase"))) { status("Session ended. Recording stopped; queued readings deleted."); stopConfirmed(); return; }
            if (Transport.serverNow(this) - lastHeartbeat > 15000) {
                lastHeartbeat = Transport.serverNow(this);
                Intent battery = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
                int percent = battery == null ? 0 : battery.getIntExtra(BatteryManager.EXTRA_LEVEL, 0) * 100 / Math.max(1, battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100));
                emit(isWatch() ? "watch" : "phone", new JSONObject().put("type", "heartbeat").put("battery", percent).put("sensors", available));
            }
            outbox.flush(config);
            status(outbox.count(config.id) == 0 ? "Connected · readings uploaded" : "Connected · some readings are waiting to upload");
        } catch (Exception e) {
            if (e instanceof Transport.HttpError && (((Transport.HttpError)e).status == 401 || ((Transport.HttpError)e).status == 404)) {
                status("Access expired or revoked. Recording stopped; queued readings deleted."); stopConfirmed(); return;
            }
            status("Offline / access unavailable · readings saved locally. " + e.getMessage());
        }
    }
    private void remind() {
        if (stopping) return;
        var prefs = Config.prefs(this);
        long due = prefs.getLong("dueAt", 0);
        if (due > 0 && Transport.serverNow(this) >= due && notifiedDeadline != due) {
            notifiedDeadline = due;
            Vibrator vibrator = (Vibrator)getSystemService(VIBRATOR_SERVICE);
            if (vibrator != null && vibrator.hasVibrator()) vibrator.vibrate(VibrationEffect.createWaveform(new long[]{0, 350, 200, 350, 200, 600}, -1));
            try { getSystemService(NotificationManager.class).notify(2, notification("Response due · are you here?", "response", true)); } catch (SecurityException ignored) {}
        }
    }
    private Notification notification(String text, String channel, boolean response) {
        Intent open = new Intent(this, activityClass());
        Notification.Builder builder = new Notification.Builder(this, channel).setSmallIcon(android.R.drawable.ic_dialog_map)
            .setContentTitle("KAZE · team simulation").setContentText(text).setOngoing(!response)
            .setContentIntent(PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        if (response) builder.addAction(new Notification.Action.Builder(null, "I'm here", PendingIntent.getService(this, 1, new Intent(this, getClass()).setAction(RESPOND), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT)).build());
        if (!isWatch()) builder.addAction(new Notification.Action.Builder(null, "End session", PendingIntent.getService(this, 2, new Intent(this, getClass()).setAction(END), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT)).build());
        return builder.build();
    }
    private void status(String message) { Config.prefs(this).edit().putString("status", message).apply(); }
    private synchronized void stopConfirmed() {
        stopping = true;
        Config.prefs(this).edit().putBoolean("active", false).apply();
        if (outbox != null && config != null) outbox.deleteSession(config.id);
        getSystemService(NotificationManager.class).cancel(2); stopSelf();
    }
    @Override public synchronized void emit(String source, JSONObject event) {
        if (stopping) return;
        if (source.equals("phone") && event.optString("type").equals("step")) Config.prefs(this).edit().putFloat("routeHeading", (float)event.optDouble("heading", config.initialHeading)).apply();
        try { outbox.add(config, source, event); } catch (Exception e) { status("Local storage error: " + e.getMessage()); }
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onDestroy() {
        stopping = true;
        if (recorder != null) recorder.stop(); if (locations != null) locations.stop(); reminderHandler.removeCallbacks(reminderTask); worker.shutdownNow();
        if (wake != null && wake.isHeld()) wake.release();
        // SQLiteOpenHelper remains owned by the service's in-flight worker until it exits.
        super.onDestroy();
    }
}
