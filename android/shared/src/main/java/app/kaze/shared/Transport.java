package app.kaze.shared;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import android.net.Network;
import java.util.function.Consumer;

public final class Transport {
    public static final class HttpError extends Exception {
        public final int status;
        public HttpError(int status, String message) { super(message); this.status = status; }
    }
    public static JSONObject send(Context c, Config config, String action, JSONObject body) throws Exception {
        if (!config.watch) return request(config, action, body);
        // Paired-phone transport works over Bluetooth without watch Wi-Fi.
        try { return Relay.request(c, config, action, body); }
        catch (Exception relayFailure) {
            if (relayFailure instanceof HttpError) throw relayFailure;
            try { return request(config, action, body); }
            catch (Exception directFailure) {
                if (directFailure instanceof HttpError) throw directFailure;
                throw new IllegalStateException("Phone relay unavailable: " + relayFailure.getMessage() + ". Direct connection unavailable: " + directFailure.getMessage(), relayFailure);
            }
        }
    }
    public static JSONObject request(Config config, String action, JSONObject body) throws Exception {
        return request(config, action, body == null ? null : body.toString().getBytes(StandardCharsets.UTF_8), "application/json", null, connection -> {});
    }
    // Motion uploads bind to the approved network, so Wi-Fi loss cannot silently
    // move a raw-data request onto cellular. The caller can cancel its own request.
    public static JSONObject motion(Config config, byte[] gzip, Network network, Consumer<HttpURLConnection> opened) throws Exception {
        return request(config, "motion", gzip, "application/gzip", network, opened);
    }
    private static JSONObject request(Config config, String action, byte[] payload, String contentType, Network network, Consumer<HttpURLConnection> opened) throws Exception {
        URL url = new URL(config.baseUrl + "/api/sessions/" + config.id + (action.isEmpty() ? "" : "/" + action));
        HttpURLConnection connection = (HttpURLConnection)(network == null ? url.openConnection() : network.openConnection(url));
        connection.setConnectTimeout(5000); connection.setReadTimeout(5000); connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Authorization", "Bearer " + config.token);
        try {
            opened.accept(connection);
            if (payload != null) {
                connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setRequestProperty("Content-Type", contentType);
                connection.setFixedLengthStreamingMode(payload.length);
                if (action.equals("motion")) connection.setRequestProperty("X-Kaze-Motion-Consent", "1");
                try (var output = connection.getOutputStream()) { output.write(payload); }
            }
            int status = connection.getResponseCode();
            InputStream input = status >= 200 && status < 300 ? connection.getInputStream() : connection.getErrorStream();
            String raw;
            if (input == null) throw new IllegalStateException("HTTP " + status);
            try (input) { ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] chunk = new byte[8192]; int count; while ((count = input.read(chunk)) != -1) bytes.write(chunk, 0, count); raw = bytes.toString(StandardCharsets.UTF_8.name()); }
            JSONObject result = new JSONObject(raw);
            if (status < 200 || status >= 300) throw new HttpError(status, result.optString("error", "HTTP " + status));
            return result;
        } finally { connection.disconnect(); }
    }
    // UTC offset is measured against the server. Device wall clocks need not match.
    public static void saveClock(Context c, JSONObject result, long requestStart) {
        long received = System.currentTimeMillis();
        long offset = result.optLong("serverNow", received) - (requestStart + (received - requestStart) / 2);
        var edit = Config.prefs(c).edit().putLong("clockRoundTrip", Math.max(0, received - requestStart)).putLong("clockOffset", offset).putLong("dueAt", result.optLong("dueAt"))
            .putLong("graceSeconds", result.optLong("graceSeconds", 30)).putString("phase", result.optString("phase", "armed")).putLong("lastSync", received);
        if (result.has("expiresAt")) edit.putLong("expiresAt", result.optLong("expiresAt"));
        if (result.has("createdAt")) edit.putLong("createdAt", result.optLong("createdAt"));
        if (result.has("lastCheckInAt")) edit.putLong("lastCheckInAt", result.optLong("lastCheckInAt"));
        edit.apply();
    }
    public static long clockUncertainty(Context c) {
        var prefs = Config.prefs(c);
        long age = Math.abs(System.currentTimeMillis() - prefs.getLong("lastSync", 0));
        return Math.min(5000, 10 + prefs.getLong("clockRoundTrip", 10000) / 2 + age / 10000);
    }
    public static long serverNow(Context c) { return System.currentTimeMillis() + Config.prefs(c).getLong("clockOffset", 0); }
}
