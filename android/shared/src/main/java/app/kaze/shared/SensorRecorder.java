package app.kaze.shared;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.SystemClock;
import org.json.JSONArray;
import org.json.JSONObject;

public final class SensorRecorder implements SensorEventListener {
    public interface Sink { void emit(String source, JSONObject event); }
    private final SensorManager manager;
    private final Config config;
    private final Context context;
    private final Sink sink;
    private final String source;
    private final float[] accel = new float[3], magnetic = new float[3], rotation = new float[9], orientation = new float[3];
    private boolean hasAccel, hasMag, calibrated, above;
    private double referenceAzimuth, heading;
    private long lastStep, lastPressure;
    private boolean nativeStep, rotationRegistered;
    public SensorRecorder(Context c, Config config, Sink sink) { context = c; manager = (SensorManager)c.getSystemService(Context.SENSOR_SERVICE); this.config = config; this.sink = sink; source = config.watch ? "watch" : "phone"; heading = config.initialHeading; }
    public JSONArray start() {
        JSONArray available = new JSONArray();
        int[] types = { Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_MAGNETIC_FIELD, Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_PRESSURE, Sensor.TYPE_STEP_DETECTOR };
        for (int type : types) {
            Sensor sensor = manager.getDefaultSensor(type);
            if (sensor != null) {
                try { if (manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)) { available.put(sensor.getStringType()); if (type == Sensor.TYPE_STEP_DETECTOR) nativeStep = true; if (type == Sensor.TYPE_ROTATION_VECTOR) rotationRegistered = true; } }
                catch (SecurityException ignored) { /* Missing permission leaves the explicit fallback active. */ }
            }
        }
        return available;
    }
    public void stop() { manager.unregisterListener(this); }
    public double heading() { return heading; }
    private void azimuth(double az) {
        if (!calibrated) { referenceAzimuth = az; calibrated = true; }
        heading = ((az - referenceAzimuth) * 180 / Math.PI + config.initialHeading + 720) % 360;
    }
    private void step(long at) {
        if (at - lastStep < 260) return;
        lastStep = at;
        try { sink.emit(source, new JSONObject().put("type", "step").put("at", Transport.serverNow(context) - Math.max(0, SystemClock.elapsedRealtime() - at)).put("heading", heading).put("length", config.stride).put("headingBasis", "device-posture").put("stepMethod", nativeStep ? "android-step-detector" : "acceleration-threshold").put("clockUncertaintyMs", Transport.clockUncertainty(context))); } catch (Exception ignored) {}
    }
    @Override public void onSensorChanged(SensorEvent e) {
        long at = e.timestamp / 1000000L;
        switch (e.sensor.getType()) {
            case Sensor.TYPE_ACCELEROMETER:
                System.arraycopy(e.values, 0, accel, 0, 3); hasAccel = true;
                if (!nativeStep) {
                    double mag = Math.sqrt(accel[0]*accel[0] + accel[1]*accel[1] + accel[2]*accel[2]);
                    if (mag > 11.5 && !above) { step(at); above = true; } else if (mag < 10) above = false;
                }
                break;
            case Sensor.TYPE_MAGNETIC_FIELD: System.arraycopy(e.values, 0, magnetic, 0, 3); hasMag = true; break;
            case Sensor.TYPE_ROTATION_VECTOR:
                SensorManager.getRotationMatrixFromVector(rotation, e.values); SensorManager.getOrientation(rotation, orientation); azimuth(orientation[0]); break;
            case Sensor.TYPE_STEP_DETECTOR: step(at); break;
            case Sensor.TYPE_PRESSURE:
                if (at - lastPressure > 2000) {
                    lastPressure = at;
                    try { sink.emit(source, new JSONObject().put("type", "pressure").put("hpa", e.values[0])); } catch (Exception ignored) {}
                }
                break;
        }
        if (!rotationRegistered && hasAccel && hasMag && SensorManager.getRotationMatrix(rotation, null, accel, magnetic)) { SensorManager.getOrientation(rotation, orientation); azimuth(orientation[0]); }
    }
    @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}
}
