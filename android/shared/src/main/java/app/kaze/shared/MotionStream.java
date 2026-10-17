package app.kaze.shared;

import android.content.Context;
import android.net.*;
import android.os.SystemClock;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.GZIPOutputStream;

/** Ten-second compressed batches. No disk queue, retry loop or safety-worker dependency. */
final class MotionStream {
    private final Context context;
    private final Config config;
    private final boolean cellular;
    private final JSONObject template;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final AtomicBoolean busy = new AtomicBoolean();
    private StringBuilder rows = new StringBuilder();
    private long startNs, startUtc, samples, sentBytes;
    private boolean oversized;
    private volatile boolean closed;
    private volatile HttpURLConnection connection;

    MotionStream(Context context, Config config, JSONObject metadata, boolean cellular) throws Exception {
        this.context = context; this.config = config; this.cellular = cellular;
        template = new JSONObject(metadata.toString());
        reset();
        Config.prefs(context).edit().putLong("motionSentBytes", 0).putString("motionResult", "")
            .putString("motionStreamStatus", cellular ? "Streaming enabled · compressed batches every 10 seconds." : "Streaming enabled · unmetered Wi-Fi only.").apply();
    }
    private void reset() {
        rows = new StringBuilder(); samples = 0; oversized = false;
        startNs = SystemClock.elapsedRealtimeNanos(); startUtc = Transport.serverNow(context);
    }
    synchronized void sample(long stamp, String sensor, float[] values) {
        if (closed || oversized || stamp < startNs) return;
        String row = MotionLog.row(stamp, sensor, values);
        if (rows.length() + row.length() > 990000) { oversized = true; rows.setLength(0); return; }
        rows.append(row); samples++;
    }
    private Network network() {
        ConnectivityManager manager = context.getSystemService(ConnectivityManager.class);
        Network network = manager == null ? null : manager.getActiveNetwork();
        NetworkCapabilities caps = network == null ? null : manager.getNetworkCapabilities(network);
        return allowed(caps, cellular) ? network : null;
    }
    static boolean allowed(NetworkCapabilities caps, boolean cellular) {
        if (caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return false;
        if (!cellular && (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            || caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            || !(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)))) return false;
        return true;
    }
    private boolean active() {
        return !closed && Config.prefs(context).getBoolean("active", false)
            && config.raw().equals(Config.prefs(context).getString("config", ""))
            && Transport.serverNow(context) < Config.prefs(context).getLong("expiresAt", 0);
    }
    private synchronized void status(String value) { if (!closed) Config.prefs(context).edit().putString("motionStreamStatus", value).apply(); }

    synchronized void flush() {
        if (closed) return;
        boolean claimed = false;
        try {
            Network approved = network();
            if (oversized) { status("Batch skipped: sensor data exceeded the size limit."); return; }
            if (approved == null) { status(cellular ? "No connection · batch skipped, no backlog." : "Waiting for unmetered Wi-Fi · batch skipped, no cellular used."); return; }
            if (samples < 600 || !active()) return;
            if (!busy.compareAndSet(false, true)) { status("Processor busy · batch skipped, no backlog."); return; }
            claimed = true;
            JSONObject metadata = new JSONObject(template.toString()).put("startedNs", startNs).put("startedUtcMs", startUtc);
            String capture = "# " + metadata + "\nt_ns,sensor,x,y,z,w,bx,by,bz\n" + rows
                + "# " + new JSONObject().put("complete", true).put("reason", "user-stopped").put("samples", samples) + "\n";
            worker.execute(() -> upload(capture, approved));
        } catch (Exception e) { if (claimed) busy.set(false); status("Motion batch unavailable · safety recording continues."); }
        finally { reset(); }
    }
    private void upload(String capture, Network approved) {
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (GZIPOutputStream gzip = new GZIPOutputStream(bytes)) { gzip.write(capture.getBytes(StandardCharsets.UTF_8)); }
            if (bytes.size() > 180000) { status("Compressed batch too large · skipped to limit data use."); return; }
            if (!active()) return;
            // Count attempted request payload bytes, including failed uploads; never auto-retry.
            synchronized (this) {
                if (!active()) return;
                sentBytes += bytes.size();
                Config.prefs(context).edit().putLong("motionSentBytes", sentBytes).apply();
            }
            JSONObject response = Transport.motion(config, bytes.toByteArray(), approved, opened -> {
                connection = opened;
                if (!active()) { opened.disconnect(); throw new IllegalStateException("Motion stream stopped"); }
            });
            if (!active()) return;
            JSONObject result = response.getJSONObject("result");
            String summary = String.format(java.util.Locale.ROOT, "Latest batch: %.1f m of estimated relative motion · %d independent segments. Accuracy unverified.",
                result.getDouble("estimatedDistanceMeters"), result.getJSONArray("segments").length());
            synchronized (this) {
                if (!active()) return;
                Config.prefs(context).edit().putString("motionResult", summary).apply();
                status("Backend processed the latest batch · raw uploads are not retained.");
            }
        } catch (Exception e) {
            status(e instanceof Transport.HttpError && ((Transport.HttpError)e).status == 422
                ? "Batch rejected: insufficient or interrupted sensor sampling."
                : "Upload unavailable · batch skipped, no retry or backlog.");
        } finally { connection = null; busy.set(false); }
    }
    synchronized void close() {
        closed = true; rows.setLength(0);
        HttpURLConnection current = connection; if (current != null) current.disconnect();
        worker.shutdownNow();
        Config.prefs(context).edit().putString("motionStreamStatus", "Streaming stopped.").apply();
    }
}
