package app.kaze.shared;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class Transport {
    public static final class HttpError extends Exception {
        public final int status;
        public HttpError(int status, String message) { super(message); this.status = status; }
    }
    public static JSONObject send(Context c, Config config, String action, JSONObject body) throws Exception {
        try { return request(config, action, body); }
        catch (Exception directFailure) {
            if (directFailure instanceof HttpError) throw directFailure;
            if (!config.watch) throw directFailure;
            return Relay.request(c, config, action, body);
        }
    }
    public static JSONObject request(Config config, String action, JSONObject body) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(config.baseUrl + "/api/sessions/" + config.id + (action.isEmpty() ? "" : "/" + action)).openConnection();
        connection.setConnectTimeout(5000); connection.setReadTimeout(5000); connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Authorization", "Bearer " + config.token);
        try {
            if (body != null) {
                connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setRequestProperty("Content-Type", "application/json");
                try (var output = connection.getOutputStream()) { output.write(body.toString().getBytes(StandardCharsets.UTF_8)); }
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
        var edit = Config.prefs(c).edit().putLong("clockOffset", offset).putLong("dueAt", result.optLong("dueAt"))
            .putLong("graceSeconds", result.optLong("graceSeconds", 30)).putString("phase", result.optString("phase", "armed")).putLong("lastSync", received);
        if (result.has("expiresAt")) edit.putLong("expiresAt", result.optLong("expiresAt"));
        if (result.has("createdAt")) edit.putLong("createdAt", result.optLong("createdAt"));
        if (result.has("lastCheckInAt")) edit.putLong("lastCheckInAt", result.optLong("lastCheckInAt"));
        edit.apply();
    }
    public static long serverNow(Context c) { return System.currentTimeMillis() + Config.prefs(c).getLong("clockOffset", 0); }
}
