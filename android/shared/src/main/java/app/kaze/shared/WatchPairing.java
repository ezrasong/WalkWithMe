package app.kaze.shared;

import android.content.Context;
import com.google.android.gms.wearable.Wearable;

/** The watch joins the phone's consented session when its foreground UI opens. */
public final class WatchPairing {
    public static final String REQUEST = "/kaze/request-pair", CONFIG = "/kaze/pair", STATUS = "/kaze/pair-status";
    // Process-local: a process restart must not strand a persisted 'connecting' lock.
    private static boolean starting, discovering;
    public static synchronized boolean locked(Context c) { return starting || Config.prefs(c).getBoolean("active", false); }
    public static synchronized boolean ready(Context c) { return !discovering && !locked(c) && Config.load(c, true) != null; }
    public static synchronized boolean accept(Context c, String raw) throws Exception {
        if (locked(c)) return false;
        Config config = new Config(raw, true);
        // Persist an allowlisted watch payload, even when an older sender adds other fields.
        new Config(config.forWatch(), true).save(c);
        discovering = false;
        Config.prefs(c).edit().putString("status", "Phone connected. Joining your safety session.").apply();
        return true;
    }
    public static synchronized void unavailable(Context c, String message) {
        if (locked(c)) return;
        discovering = false;
        Config.prefs(c).edit().remove("config").putString("status", message).apply();
    }
    public static synchronized Config beginStart(Context c) {
        if (locked(c) || discovering) throw new IllegalStateException("Waiting for the phone's current session");
        Config config = Config.load(c, true);
        if (config == null) throw new IllegalStateException("Waiting for the phone's active session");
        starting = true;
        return config;
    }
    public static synchronized void finishStart() { starting = false; }
    public static synchronized void request(Context c) {
        if (locked(c)) return;
        discovering = true;
        if (Config.load(c, true) == null) Config.prefs(c).edit().putString("status", "Looking for WalkWithMe on your paired phone…").apply();
        Wearable.getNodeClient(c).getConnectedNodes().addOnSuccessListener(nodes -> {
            if (nodes.isEmpty()) { unavailable(c, "Connect your watch to the phone in Galaxy Wearable."); return; }
            Wearable.getMessageClient(c).sendMessage(nodes.get(0).getId(), REQUEST, new byte[0])
                .addOnFailureListener(e -> unavailable(c, "Phone connection unavailable. Keep both devices connected."));
        }).addOnFailureListener(e -> unavailable(c, "Phone connection unavailable. Keep both devices connected."));
    }
}
