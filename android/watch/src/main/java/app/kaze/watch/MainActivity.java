package app.kaze.watch;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.*;
import android.widget.*;
import app.kaze.shared.*;
import org.json.JSONObject;
import java.util.ArrayList;

public final class MainActivity extends Activity {
    private TextView status;
    private Button startButton;
    private boolean permissionsRequested, connecting;
    private long lastDiscovery;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final java.util.concurrent.ExecutorService worker = java.util.concurrent.Executors.newSingleThreadExecutor();
    private final Runnable refresh = new Runnable() { public void run() {
        var p = Config.prefs(MainActivity.this);
        boolean active = p.getBoolean("active", false);
        if (!active && !connecting && SystemClock.elapsedRealtime() - lastDiscovery >= 10000) discover();
        long secs = (p.getLong("dueAt",0) - Transport.serverNow(MainActivity.this)) / 1000;
        long accepted = p.getLong("lastCheckInAt", 0);
        status.setText((connecting ? "Connecting to your session…" : p.getString("status", "Looking for your phone…")) +
            (active ? "\n" + (secs > 0 ? secs + "s to check in" : "Response due") : "") +
            (accepted > 0 && active ? "\nLast accepted check-in " + android.text.format.DateFormat.format("HH:mm:ss", accepted) : ""));
        startButton.setEnabled(!active && !connecting && WatchPairing.ready(MainActivity.this));
        handler.postDelayed(this,1000);
    }};
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this); LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(24,24,24,32); scroll.addView(root); setContentView(scroll);
        TextView title = new TextView(this); title.setText("KAZE"); title.setTextSize(23); title.setGravity(17); root.addView(title);
        status = new TextView(this); status.setTextSize(14); status.setPadding(0,12,0,12); root.addView(status);
        startButton = button(root, "Start watch session", this::start);
        button(root, "Check in", () -> {
            if (Config.prefs(this).getBoolean("active",false)) {
                Config.prefs(this).edit().putString("status", "Waiting for server confirmation…").apply();
                startService(new Intent(this, WatchService.class).setAction(MonitoringService.RESPOND));
            }
        });
        TextView note = new TextView(this); note.setText("Connects automatically to your paired phone. Tap Start to consent to this session. Location may come from the phone. No emergency dispatch."); note.setTextSize(12); root.addView(note);
    }
    private Button button(LinearLayout root, String text, Runnable action) { Button b = new Button(this); b.setText(text); b.setAllCaps(false); b.setMinHeight(52); root.addView(b); b.setOnClickListener(v -> action.run()); return b; }
    private void discover() { lastDiscovery = SystemClock.elapsedRealtime(); WatchPairing.request(this); }
    private void start() {
        if (connecting) return;
        ArrayList<String> needed = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) { needed.add(Manifest.permission.ACCESS_FINE_LOCATION); needed.add(Manifest.permission.ACCESS_COARSE_LOCATION); }
        if (Build.VERSION.SDK_INT >=29 && checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.ACTIVITY_RECOGNITION);
        if (Build.VERSION.SDK_INT >=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!permissionsRequested && !needed.isEmpty()) { permissionsRequested = true; requestPermissions(needed.toArray(new String[0]), 7); return; }
        final Config config;
        try { config = WatchPairing.beginStart(this); }
        catch (Exception e) { discover(); return; }
        connecting = true; startButton.setEnabled(false);
        worker.execute(() -> {
            try {
                long at = System.currentTimeMillis(); JSONObject result = Transport.send(this,config,"",null);
                if ("resolved".equals(result.getString("phase"))) throw new IllegalStateException("Session ended. Start a new one on your phone.");
                if (!"device".equals(result.optString("sensorMode"))) throw new IllegalStateException("Use a device session on your phone.");
                Transport.saveClock(this,result,at);
                runOnUiThread(() -> {
                    connecting = false;
                    if (isDestroyed() || isFinishing()) { WatchPairing.finishStart(); return; }
                    try { startForegroundService(new Intent(this,WatchService.class)); }
                    catch (Exception e) { failedStart("Recording could not start. Reopen KAZE and retry."); }
                });
            } catch (Exception e) { runOnUiThread(() -> failedStart("Could not connect: " + e.getMessage())); }
        });
    }
    private void failedStart(String message) { connecting = false; WatchPairing.finishStart(); Config.prefs(this).edit().putString("status", message).apply(); }
    @Override public void onRequestPermissionsResult(int r,String[] p,int[] results) { super.onRequestPermissionsResult(r,p,results); if (r==7) start(); }
    @Override public void onResume() { super.onResume(); if (!Config.prefs(this).getBoolean("active", false)) discover(); handler.post(refresh); }
    @Override public void onPause() { handler.removeCallbacks(refresh); super.onPause(); }
    @Override public void onDestroy() { worker.shutdownNow(); if (!Config.prefs(this).getBoolean("active", false)) WatchPairing.finishStart(); super.onDestroy(); }
}
