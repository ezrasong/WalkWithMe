package app.kaze.shared;

import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Bounded, app-private local evaluation data, separate from the upload outbox. */
final class MotionLog implements Closeable {
    static final long MAX_NANOS = 180_000_000_000L;
    static final long MAX_BYTES = 32 * 1024 * 1024;
    private final File partial, complete;
    private final BufferedWriter writer;
    private final long start;
    private long bytes, samples;
    private boolean closed;

    MotionLog(File directory, long start, JSONObject metadata) throws Exception {
        this.start = start;
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("Motion directory unavailable");
        partial = new File(directory, "motion.csv.partial"); complete = new File(directory, "motion.csv");
        if (complete.exists() || partial.exists()) throw new IOException("Export or delete the previous capture first");
        writer = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(partial), StandardCharsets.UTF_8));
        write("# " + metadata.toString() + "\n");
        write("t_ns,sensor,x,y,z,w,bx,by,bz\n");
    }

    private void write(String row) throws IOException {
        byte[] encoded = row.getBytes(StandardCharsets.UTF_8);
        if (bytes + encoded.length > MAX_BYTES - 1024) throw new IOException("Motion storage limit reached");
        writer.write(row); bytes += encoded.length;
    }
    synchronized boolean sample(long t, String sensor, float[] values) throws Exception {
        if (closed) return false;
        if (t < start) return true; // Ignore a cached sensor callback from before consent.
        if (t - start > MAX_NANOS) return false;
        validate(sensor, values);
        write(row(t, sensor, values)); samples++; return true;
    }
    static void validate(String sensor, float[] values) throws IOException {
        int needed = sensor.equals("rotation") ? 4 : 3;
        if (values.length < needed) throw new IOException("Incomplete motion observation");
        for (float v : values) if (!Float.isFinite(v)) throw new IOException("Invalid motion observation");
    }
    static String row(long t, String sensor, float[] values) {
        StringBuilder row = new StringBuilder().append(t).append(',').append(sensor);
        // Rotation values are x,y,z,w; uncalibrated inertial values carry three
        // bias estimates after x,y,z. Calibrated Android sensors leave them blank.
        for (int i=0;i<7;i++) {
            row.append(',');
            if (sensor.equals("rotation")) { if (i<4) row.append(values[i]); }
            else if (i<3) row.append(values[i]);
            else if (i>=4 && values.length>=6) row.append(values[i-1]);
        }
        return row.append('\n').toString();
    }
    synchronized void flush() throws IOException { if (!closed) writer.flush(); }
    synchronized long samples() { return samples; }
    synchronized void finish(String reason) throws Exception {
        if (closed) return;
        try {
            // Leave space under MAX_BYTES for the completion footer.
            writer.write("# " + new JSONObject().put("complete", true).put("reason", reason).put("samples", samples) + "\n");
            writer.close();
        } finally { closed = true; }
        if (!partial.renameTo(complete)) throw new IOException("Motion capture could not be finalized");
    }
    @Override public synchronized void close() throws IOException {
        if (!closed) { closed = true; writer.close(); }
    }
}
