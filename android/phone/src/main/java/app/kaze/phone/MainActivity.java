package app.kaze.phone;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.PowerManager;
import android.app.ActivityManager;
import android.app.NotificationManager;
import android.location.LocationManager;
import android.net.Uri;
import android.provider.Settings;
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
    private MethodChannel.Result arPermissionResult;
    private final java.util.concurrent.ExecutorService worker = Executors.newSingleThreadExecutor();
    @Override public void configureFlutterEngine(FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        engine.getPlatformViewsController().getRegistry().registerViewFactory("app.kaze/guardian-ar",
            new io.flutter.plugin.platform.PlatformViewFactory(io.flutter.plugin.common.StandardMessageCodec.INSTANCE) {
                @Override public io.flutter.plugin.platform.PlatformView create(android.content.Context context, int id, Object args) {
                    return new GuardianArView(MainActivity.this, id, engine.getDartExecutor().getBinaryMessenger());
                }
            });
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "app.kaze/session").setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "prepareGuardianAr": {
                    if (Config.prefs(this).getBoolean("active", false)) { result.success("End wearer recording before using a guardian camera."); break; }
                    if (arPermissionResult != null || permissionResult != null) { result.success("Permission request pending."); break; }
                    try {
                        if (!com.google.ar.core.ArCoreApk.getInstance().checkAvailability(this).isSupported()) { result.success("ARCore unsupported or still checking. Use the map."); break; }
                        if (com.google.ar.core.ArCoreApk.getInstance().requestInstall(this, true) != com.google.ar.core.ArCoreApk.InstallStatus.INSTALLED) {
                            result.success("ARCore install requested. Reopen AR after installation."); break;
                        }
                        ArrayList<String> needed = new ArrayList<>();
                        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.CAMERA);
                        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                            needed.add(Manifest.permission.ACCESS_FINE_LOCATION); needed.add(Manifest.permission.ACCESS_COARSE_LOCATION);
                        }
                        if (needed.isEmpty()) result.success("ready");
                        else { arPermissionResult = result; requestPermissions(needed.toArray(new String[0]), 8); }
                    } catch (Exception e) { result.success("ARCore unavailable. Use the map."); }
                    break;
                }
                case "permissions": requestRecordingPermissions(result); break;
                case "guardianPermissions": {
                    if (permissionResult != null || arPermissionResult != null) { result.error("pending", "Permission request already open", null); break; }
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        permissionResult = result; requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 9);
                    } else result.success(null);
                    break;
                }
                case "guardianStatus": result.success(GuardianService.status(this)); break;
                case "startGuardian": {
                    try { GuardianService.enable(this, (String)call.arguments); result.success(GuardianService.status(this)); }
                    catch (Exception e) { result.error("guardian", e.getMessage(), null); }
                    break;
                }
                case "stopGuardian": GuardianService.disable(this); result.success(null); break;
                case "setupStatus": {
                    var state = new HashMap<String,Object>();
                    state.put("locationAllowed", LocationRecorder.permitted(this));
                    state.put("preciseLocation", checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED);
                    state.put("locationServices", getSystemService(LocationManager.class).isLocationEnabled());
                    state.put("notificationsAllowed", getSystemService(NotificationManager.class).areNotificationsEnabled());
                    state.put("batteryExempt", getSystemService(PowerManager.class).isIgnoringBatteryOptimizations(getPackageName()));
                    state.put("backgroundRestricted", getSystemService(ActivityManager.class).isBackgroundRestricted());
                    state.put("manufacturer", Build.MANUFACTURER);
                    result.success(state); break;
                }
                case "batterySettings": {
                    if (getSystemService(PowerManager.class).isIgnoringBatteryOptimizations(getPackageName())) { result.success(null); break; }
                    openSetupSettings(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())), result); break;
                }
                case "locationSettings": openSetupSettings(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS), result); break;
                case "appSettings": openSetupSettings(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())), result); break;
                case "status": {
                    var p = Config.prefs(this); var state = new HashMap<String,Object>();
                    state.put("active", p.getBoolean("active", false)); state.put("status", p.getString("status", "Recorder not started"));
                    state.put("lastCheckInAt", p.getLong("lastCheckInAt", 0)); result.success(state); break;
                }
                case "start": {
                    if (Config.prefs(this).getBoolean("active", false)) { result.error("active", "End the current recording session first", null); break; }
                    if (GuardianService.enabled(this)) { result.error("guardian", "Stop guardian monitoring before starting wearer recording", null); break; }
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
    private void openSetupSettings(Intent intent, MethodChannel.Result result) {
        try { startActivity(intent); result.success(null); }
        catch (RuntimeException e) { result.error("settings", "Open this phone's Settings and select KAZE under Apps.", null); }
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
        if ((r == 7 || r == 9) && permissionResult != null) { permissionResult.success(null); permissionResult = null; }
        if (r == 8 && arPermissionResult != null) {
            arPermissionResult.success(checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ? "ready" : "Camera and precise location permission required. Use the map.");
            arPermissionResult = null;
        }
    }
    @Override public void onDestroy() { worker.shutdownNow(); if (permissionResult != null) { permissionResult.error("closed", "Screen closed during permissions", null); permissionResult = null; } if (arPermissionResult != null) { arPermissionResult.success("Screen closed during permissions."); arPermissionResult = null; } super.onDestroy(); }
}
