package app.kaze.shared;

import android.content.Context;
import android.net.*;
import android.os.SystemClock;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.ArrayDeque;
import java.util.UUID;
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
    private record Row(long stamp, String text) {}
    private final ArrayDeque<Row> rows = new ArrayDeque<>();
    private int rowBytes;
    private final String streamId = UUID.randomUUID().toString();
    private final long streamNs = SystemClock.elapsedRealtimeNanos();
    private final long streamUtc;
    private final long clockUncertainty;
    private long sequence;
    private long startNs, startUtc, samples, sentBytes;
    private boolean oversized;
    private volatile boolean closed;
    private volatile HttpURLConnection connection;

    MotionStream(Context context, Config config, JSONObject metadata, boolean cellular) throws Exception {
        this.context = context; this.config = config; this.cellular = cellular;
        template = new JSONObject(metadata.toString());
        streamUtc = Transport.serverNow(context);
        clockUncertainty = Transport.clockUncertainty(context);
        reset();
        Config.prefs(context).edit().putLong("motionSentBytes", 0).putString("motionResult", "")
            .putString("motionStreamStatus", cellular ? "Streaming enabled · compressed batches every 10 seconds." : "Streaming enabled · unmetered Wi-Fi only.").apply();
    }
    private void reset() {
        long cutoff = Math.max(streamNs, SystemClock.elapsedRealtimeNanos() - 1300000000L);
        while (!rows.isEmpty() && rows.peekFirst().stamp() < cutoff) rowBytes -= rows.removeFirst().text().length();
        samples = rows.size(); oversized = false;
        startNs = cutoff; startUtc = streamUtc + (cutoff - streamNs) / 1000000L;
    }
    synchronized void sample(long stamp, String sensor, float[] values) {
        if (closed || oversized || stamp < startNs) return;
        String row = MotionLog.row(stamp, sensor, values);
        if (rowBytes + row.length() > 990000) { oversized = true; rows.clear(); rowBytes = 0; return; }
        rows.addLast(new Row(stamp, row)); rowBytes += row.length(); samples++;
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
        long batchSequence = sequence++;
        try {
            Network approved = network();
            if (oversized) { status("Batch skipped: sensor data exceeded the size limit."); return; }
            if (approved == null) { status(cellular ? "No connection · batch skipped, no backlog." : "Waiting for unmetered Wi-Fi · batch skipped, no cellular used."); return; }
            if (!active()) return;
            if (samples < 600) { status("Batch skipped: fewer than 600 sensor observations."); return; }
            if (!busy.compareAndSet(false, true)) { status("Processor busy · batch skipped, no backlog."); return; }
            claimed = true;
            String capture = capture(batchSequence);
            worker.execute(() -> upload(capture, approved));
        } catch (Exception e) { if (claimed) busy.set(false); status("Motion batch unavailable · safety recording continues."); }
        finally { reset(); }
    }
    synchronized String capture(long batchSequence) throws Exception {
        JSONObject metadata = new JSONObject(template.toString()).put("startedNs", startNs).put("startedUtcMs", startUtc)
                .put("streamVersion", 2).put("streamId", streamId).put("batchSequence", batchSequence)
                .put("streamStartedNs", streamNs).put("streamStartedUtcMs", streamUtc).put("clockUncertaintyMs", clockUncertainty);
        StringBuilder batchRows = new StringBuilder(rowBytes);
        for (Row row : rows) batchRows.append(row.text());
        return "# " + metadata + "\nt_ns,sensor,x,y,z,w,bx,by,bz\n" + batchRows
                + "# " + new JSONObject().put("complete", true).put("reason", "user-stopped").put("samples", samples) + "\n";
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
            String summary = String.format(java.util.Locale.ROOT, "Latest overlapping batch: %.1f m relative motion · %d supported sections. Shared preview counts overlap once. Accuracy unverified.",
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
        closed = true; rows.clear(); rowBytes = 0;
        HttpURLConnection current = connection; if (current != null) current.disconnect();
        worker.shutdownNow();
        Config.prefs(context).edit().putString("motionStreamStatus", "Streaming stopped.").apply();
    }
}
