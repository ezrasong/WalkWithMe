package app.kaze.watch;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.widget.*;
import app.kaze.shared.*;
import org.json.JSONObject;
import java.util.ArrayList;

public final class MainActivity extends Activity {
    private TextView status, countdown, lastCheckIn;
    private Button checkInButton;
    private boolean permissionsRequested, permissionsPending, connecting, checkingIn;
    private long lastDiscovery, lastStartAttempt, checkInBaseline, responseStarted;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final java.util.concurrent.ExecutorService worker = java.util.concurrent.Executors.newSingleThreadExecutor();
    private final Runnable refresh = new Runnable() { public void run() {
        var p = Config.prefs(MainActivity.this);
        boolean active = p.getBoolean("active", false);
        if (!active && !connecting && !permissionsPending && WatchPairing.ready(MainActivity.this)
                && SystemClock.elapsedRealtime() - lastStartAttempt >= 10000) start();
        if (!active && !connecting && SystemClock.elapsedRealtime() - lastDiscovery >= 10000) discover();
        long secs = (p.getLong("dueAt",0) - Transport.serverNow(MainActivity.this)) / 1000;
        long accepted = p.getLong("lastCheckInAt", 0);
        String message = p.getString("status", "Looking for your phone.");
        String phase = p.getString("phase", "");
        if (checkingIn && (accepted > checkInBaseline || message.startsWith("Not confirmed") || SystemClock.elapsedRealtime() - responseStarted > 25000)) checkingIn = false;
        boolean alert = "alert".equals(phase), resolved = "resolved".equals(phase);
        status.setText(checkingIn ? "Confirming check-in…" : active ? alert ? "Assistance requested" : secs > 0 ? "Safety session active" : "Time to check in"
            : connecting ? "Connecting to phone…" : resolved ? "Session ended" : "Looking for phone…");
        countdown.setText(active ? alert ? "Use phone to end" : secs > 0 ? String.format(java.util.Locale.getDefault(), "%d:%02d", secs / 60, secs % 60) : "Response due" : "KAZE");
        countdown.setTextSize(alert ? 18 : 30);
        lastCheckIn.setText(checkingIn ? "Waiting for server confirmation" : message.startsWith("Not confirmed") ? "Check-in not confirmed. Retry."
            : message.startsWith("Offline") ? "Offline · readings saved"
            : active && accepted > 0 ? "Checked in " + android.text.format.DateFormat.format("HH:mm", accepted)
            : active ? "Through your paired phone" : resolved ? "Start a new session on phone" : "Start a session on your phone");
        checkInButton.setEnabled(active && !checkingIn && !resolved && !alert);
        checkInButton.setAlpha(checkInButton.isEnabled() ? 1f : .45f);
        handler.postDelayed(this,1000);
    }};
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setBackgroundColor(Color.BLACK);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setGravity(17); root.setPadding(dp(24),dp(28),dp(24),dp(28)); scroll.addView(root); setContentView(scroll);
        status = label(root, 14, 0xffc3c7cf); status.setPadding(0,0,0,dp(4));
        countdown = label(root, 30, Color.WHITE); countdown.setTypeface(Typeface.DEFAULT, Typeface.BOLD); countdown.setPadding(0,0,0,dp(10));
        checkInButton = button(root, "Check in", () -> {
            if (Config.prefs(this).getBoolean("active",false)) {
                if (checkingIn) return;
                checkingIn = true; checkInBaseline = Config.prefs(this).getLong("lastCheckInAt", 0); responseStarted = SystemClock.elapsedRealtime();
                checkInButton.setEnabled(false);
                Config.prefs(this).edit().putString("status", "Waiting for server confirmation…").apply();
                startService(new Intent(this, WatchService.class).setAction(MonitoringService.RESPOND));
            }
        });
        checkInButton.setEnabled(false);
        lastCheckIn = label(root, 13, 0xffc3c7cf); lastCheckIn.setPadding(0,dp(10),0,0);
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView label(LinearLayout root, int size, int color) { TextView t = new TextView(this); t.setTextSize(size); t.setTextColor(color); t.setGravity(17); root.addView(t); return t; }
    private Button button(LinearLayout root, String text, Runnable action) {
        Button b = new Button(this); b.setText(text); b.setTextSize(18); b.setTypeface(Typeface.DEFAULT, Typeface.BOLD); b.setTextColor(0xff102b25); b.setAllCaps(false); b.setMinHeight(dp(56));
        GradientDrawable background = new GradientDrawable(); background.setColor(0xffa6efda); background.setCornerRadius(dp(28)); b.setBackground(background);
        root.addView(b, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)); b.setOnClickListener(v -> action.run()); return b;
    }
    private void discover() { lastDiscovery = SystemClock.elapsedRealtime(); WatchPairing.request(this); }
    private void start() {
        if (connecting || permissionsPending || Config.prefs(this).getBoolean("active", false)) return;
        ArrayList<String> needed = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) { needed.add(Manifest.permission.ACCESS_FINE_LOCATION); needed.add(Manifest.permission.ACCESS_COARSE_LOCATION); }
        if (Build.VERSION.SDK_INT >=29 && checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.ACTIVITY_RECOGNITION);
        if (Build.VERSION.SDK_INT >=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!permissionsRequested && !needed.isEmpty()) { permissionsRequested = true; permissionsPending = true; requestPermissions(needed.toArray(new String[0]), 7); return; }
        final Config config;
        try { config = WatchPairing.beginStart(this); }
        catch (Exception e) { discover(); return; }
        connecting = true; lastStartAttempt = SystemClock.elapsedRealtime();
        getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        worker.execute(() -> {
            try {
                long at = System.currentTimeMillis(); JSONObject result = Transport.send(this,config,"",null);
                if ("resolved".equals(result.getString("phase"))) throw new IllegalStateException("Session ended. Start a new one on your phone.");
                if (!"device".equals(result.optString("sensorMode"))) throw new IllegalStateException("Use a device session on your phone.");
                Transport.saveClock(this,result,at);
                runOnUiThread(() -> {
                    connecting = false;
                    getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    if (isDestroyed() || isFinishing()) { WatchPairing.finishStart(); return; }
                    try { startForegroundService(new Intent(this,WatchService.class)); }
                    catch (Exception e) { failedStart("Recording could not start. Reopen KAZE and retry."); }
                });
            } catch (Exception e) { runOnUiThread(() -> failedStart("Could not connect: " + e.getMessage())); }
        });
    }
    private void failedStart(String message) { connecting = false; getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); WatchPairing.finishStart(); Config.prefs(this).edit().putString("status", message).apply(); }
    @Override public void onRequestPermissionsResult(int r,String[] p,int[] results) { super.onRequestPermissionsResult(r,p,results); if (r==7) { permissionsPending = false; start(); } }
    @Override public void onResume() { super.onResume(); if (!Config.prefs(this).getBoolean("active", false)) discover(); handler.post(refresh); }
    @Override public void onPause() { handler.removeCallbacks(refresh); super.onPause(); }
    @Override public void onDestroy() { worker.shutdownNow(); if (!Config.prefs(this).getBoolean("active", false)) WatchPairing.finishStart(); super.onDestroy(); }
}
