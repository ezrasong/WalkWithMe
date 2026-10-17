package app.kaze.phone;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import app.kaze.shared.*;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.concurrent.Executors;

// Flutter owns phone UI; the native service owns durable recording and reminders.
public final class MainActivity extends FlutterActivity {
    private MethodChannel.Result permissionResult;
    private final java.util.concurrent.ExecutorService worker = Executors.newSingleThreadExecutor();
    @Override public void configureFlutterEngine(FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "app.kaze/session").setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "permissions": requestRecordingPermissions(result); break;
                case "status": {
                    var p = Config.prefs(this); var state = new HashMap<String,Object>();
                    state.put("active", p.getBoolean("active", false)); state.put("status", p.getString("status", "Recorder not started"));
                    state.put("lastCheckInAt", p.getLong("lastCheckInAt", 0)); result.success(state); break;
                }
                case "start": {
                    if (Config.prefs(this).getBoolean("active", false)) { result.error("active", "End the current recording session first", null); break; }
                    try {
                        Config next = new Config((String)call.arguments, false);
                        worker.execute(() -> {
                            try {
                                long started = System.currentTimeMillis(); JSONObject snapshot = Transport.send(this, next, "", null);
                                if ("resolved".equals(snapshot.optString("phase")) || !"device".equals(snapshot.optString("sensorMode"))) throw new IllegalStateException("Use an active device session");
                                next.save(this); Transport.saveClock(this, snapshot, started);
                                runOnUiThread(() -> { try { startForegroundService(new Intent(this, TrailService.class)); result.success(null); } catch (Exception e) { result.error("start", "Recorder could not start", null); } });
                            } catch (Exception e) { runOnUiThread(() -> result.error("connect", "Server refused recorder connection", null)); }
                        });
                    } catch (Exception e) { result.error("config", "Invalid private recording configuration", null); }
                    break;
                }
                case "refresh": {
                    if (Config.prefs(this).getBoolean("active", false)) startService(new Intent(this, TrailService.class).setAction(MonitoringService.REFRESH));
                    result.success(null); break;
                }
                default: result.notImplemented();
            }
        });
    }
    private void requestRecordingPermissions(MethodChannel.Result result) {
        if (permissionResult != null) { result.error("pending", "Permission request already open", null); return; }
        ArrayList<String> needed = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) { needed.add(Manifest.permission.ACCESS_FINE_LOCATION); needed.add(Manifest.permission.ACCESS_COARSE_LOCATION); }
        if (Build.VERSION.SDK_INT >= 29 && checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.ACTIVITY_RECOGNITION);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS);
        if (needed.isEmpty()) { result.success(null); return; }
        permissionResult = result; requestPermissions(needed.toArray(new String[0]), 7);
    }
    @Override public void onRequestPermissionsResult(int r, String[] p, int[] grants) {
        super.onRequestPermissionsResult(r, p, grants);
        if (r == 7 && permissionResult != null) { permissionResult.success(null); permissionResult = null; }
    }
    @Override public void onDestroy() { worker.shutdownNow(); if (permissionResult != null) { permissionResult.error("closed", "Screen closed during permissions", null); permissionResult = null; } super.onDestroy(); }
}
