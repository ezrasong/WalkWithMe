package app.kaze.shared;

import android.content.Context;
import android.hardware.*;
import android.os.*;
import org.json.JSONObject;
import java.io.File;
import java.util.HashMap;
import java.util.Map;

/** Session-long phone streaming by default; optional three-minute private capture. */
public final class MotionCapture implements SensorEventListener {
    private final Context context;
    private final SensorManager manager;
    private HandlerThread thread;
    private Handler handler;
    private MotionLog log;
    private MotionStream stream;
    private boolean automatic, automaticAttempted;
    private long samples;
    private static volatile boolean running;
    private final float[] quaternion = new float[4];

    public MotionCapture(Context c) { context = c; manager = c.getSystemService(SensorManager.class); }
    static File directory(Context c) { return new File(c.getFilesDir(), "motion-evaluation"); }
    private static void message(Context c, String value) { Config.prefs(c).edit().putString("motionStatus", value).apply(); }

    public static synchronized Map<String,Object> status(Context c) {
        long expiry = Config.prefs(c).getLong("expiresAt", 0);
        boolean active = Config.prefs(c).getBoolean("active", false) && expiry > Transport.serverNow(c);
        if (!active && !running) delete(c);
        // A process interruption leaves an incomplete file, never a usable capture.
        if (!running) new File(directory(c), "motion.csv.partial").delete();
        var result = new HashMap<String,Object>();
        result.put("recording", running);
        result.put("automatic", Config.prefs(c).getBoolean("motionAutomatic", false));
        result.put("streaming", Config.prefs(c).getBoolean("motionStreaming", false));
        result.put("cellular", Config.prefs(c).getBoolean("motionCellular", false));
        result.put("available", new File(directory(c), "motion.csv").isFile());
        result.put("status", Config.prefs(c).getString("motionStatus", "Ready for a local motion capture."));
        result.put("streamStatus", Config.prefs(c).getString("motionStreamStatus", ""));
        result.put("sentBytes", Config.prefs(c).getLong("motionSentBytes", 0));
        result.put("result", Config.prefs(c).getString("motionResult", ""));
        return result;
    }
    public static synchronized void delete(Context c) {
        if (running) throw new IllegalStateException("Stop the motion capture before deleting it");
        for (String name : new String[]{"motion.csv", "motion.csv.partial"}) {
            File file = new File(directory(c), name);
            if (file.exists() && !file.delete()) throw new IllegalStateException("Motion capture could not be deleted");
        }
        Config.prefs(c).edit().remove("motionStreamStatus").remove("motionResult").remove("motionSentBytes")
            .remove("motionAutomatic").remove("motionStreaming").remove("motionCellular").apply();
    }

    public synchronized void startAutomatic(Config config) {
        if (config.watch || automaticAttempted || running || thread != null
            || config.id.equals(Config.prefs(context).getString("motionStoppedSession", ""))) return;
        automaticAttempted = true;
        try { start(config, true, true, false); }
        catch (Exception e) { message(context, "Motion streaming unavailable. Safety recording continues."); }
    }
    public synchronized void stopForSession(Config config) {
        Config.prefs(context).edit().putString("motionStoppedSession", config.id).apply();
        stop("user-stopped");
    }
    public synchronized void start(Config config, boolean streaming, boolean cellular) throws Exception {
        start(config, streaming, cellular, true);
    }
    private void start(Config config, boolean streaming, boolean cellular, boolean localCapture) throws Exception {
        if (running || thread != null) throw new IllegalStateException("Motion capture already running");
        long expiry = Config.prefs(context).getLong("expiresAt", 0);
        if (config.watch || !Config.prefs(context).getBoolean("active", false) || expiry <= Transport.serverNow(context))
            throw new IllegalStateException("An active wearer phone session is required");
        if (manager == null) throw new IllegalStateException("Motion sensors unavailable");
        status(context);
        Sensor accel = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER_UNCALIBRATED);
        if (accel == null) accel = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        Sensor gyro = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE_UNCALIBRATED);
        if (gyro == null) gyro = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        Sensor rotation = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR);
        if (accel == null || gyro == null || rotation == null) throw new IllegalStateException("Acceleration, gyroscope and game rotation sensors are required");
        long start = SystemClock.elapsedRealtimeNanos();
        JSONObject metadata = new JSONObject().put("version", 1).put("source", "phone")
            .put("clock", "elapsedRealtimeNanos").put("startedNs", start).put("startedUtcMs", System.currentTimeMillis())
            .put("requestedHz", 200).put("frame", "Android-game-rotation-z-up-yaw-unknown")
            .put("accelSensor", accel.getType()).put("gyroSensor", gyro.getType())
            .put("rotationSensor", rotation.getType()).put("accelerationUnits", "m/s^2-including-gravity").put("angularRateUnits", "rad/s");
        log = localCapture ? new MotionLog(directory(context), start, metadata) : null;
        automatic = !localCapture; samples = 0;
        Config.prefs(context).edit().putBoolean("motionAutomatic", automatic).putBoolean("motionStreaming", streaming)
            .putBoolean("motionCellular", streaming && cellular).apply();
        thread = new HandlerThread("kaze-motion-capture"); thread.start(); handler = new Handler(thread.getLooper());
        running = true;
        try {
            if (streaming) {
                stream = new MotionStream(context, config, metadata, cellular);
                handler.postDelayed(new Runnable() { @Override public void run() {
                    synchronized (MotionCapture.this) {
                        if (!running || stream == null) return;
                        stream.flush(); handler.postDelayed(this, 10000);
                    }
                } }, 10000);
            }
            for (Sensor sensor : new Sensor[]{accel,gyro,rotation}) {
                if (!manager.registerListener(this, sensor, 5000, 0, handler)) throw new IllegalStateException("Motion sensor could not start");
            }
            if (localCapture) handler.postDelayed(() -> stop("duration-limit"), 180000);
            handler.postDelayed(new Runnable() { @Override public void run() {
                synchronized (MotionCapture.this) {
                    if (!running) return;
                    if (!Config.prefs(context).getBoolean("active", false)
                        || Transport.serverNow(context) >= Config.prefs(context).getLong("expiresAt", 0)) { stop("session-ended"); return; }
                    try {
                        if (log != null) log.flush();
                        message(context, automatic ? "Automatic motion streaming active · Wi-Fi or cellular. No raw capture saved."
                            : "Capturing local motion: " + samples + " samples. Stops after 3 minutes.");
                    }
                    catch (Exception e) { stop("storage-error"); return; }
                    handler.postDelayed(this, 1000);
                }
            } }, 1000);
            message(context, automatic ? "Automatic motion streaming active · Wi-Fi or cellular. No raw capture saved."
                : "Capturing local motion. Stops after 3 minutes.");
        } catch (Exception e) { stop("sensor-start-failed"); if (localCapture) delete(context); throw e; }
    }

    public synchronized void stop(String reason) {
        if (thread == null) return;
        if (stream != null) { stream.close(); stream = null; }
        try { manager.unregisterListener(this); } catch (RuntimeException ignored) {}
        if (handler != null) handler.removeCallbacksAndMessages(null);
        try {
            if (log != null) log.finish(reason);
            message(context, automatic ? "Automatic motion streaming stopped."
                : reason.equals("user-stopped") || reason.equals("duration-limit") || reason.equals("service-stopped")
                ? "Local motion capture ready for private export."
                : "Motion capture ended with an error. Delete it and try again.");
        }
        catch (Exception e) { message(context, "Motion capture incomplete. Delete it and try again."); }
        finally {
            running = false;
            try { if (log != null) log.close(); } catch (Exception ignored) {}
            log = null; thread.quitSafely(); thread = null; handler = null;
        }
    }
    @Override public synchronized void onSensorChanged(SensorEvent e) {
        if (!running || thread == null) return;
        try {
            String kind;
            float[] values = e.values;
            switch (e.sensor.getType()) {
                case Sensor.TYPE_ACCELEROMETER: case Sensor.TYPE_ACCELEROMETER_UNCALIBRATED: kind="accel"; break;
                case Sensor.TYPE_GYROSCOPE: case Sensor.TYPE_GYROSCOPE_UNCALIBRATED: kind="gyro"; break;
                case Sensor.TYPE_GAME_ROTATION_VECTOR:
                    kind="rotation"; SensorManager.getQuaternionFromVector(quaternion, values);
                    values = new float[]{quaternion[1],quaternion[2],quaternion[3],quaternion[0]}; break;
                default: return;
            }
            MotionLog.validate(kind, values);
            if (log != null && !log.sample(e.timestamp, kind, values)) { stop("duration-limit"); return; }
            samples++;
            if (stream != null) stream.sample(e.timestamp, kind, values);
        } catch (Exception e2) { stop("storage-or-sensor-error"); }
    }
    @Override public void onAccuracyChanged(Sensor sensor,int accuracy) {}
}
