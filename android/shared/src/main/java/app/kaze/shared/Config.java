package app.kaze.shared;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.net.URI;

public final class Config {
    public final String baseUrl, id, token, watchToken;
    public final double initialHeading, stride;
    public final boolean watch;
    private final JSONObject json;
    public Config(String raw, boolean isWatch) throws Exception {
        json = new JSONObject(raw); watch = isWatch;
        baseUrl = json.getString("baseUrl").replaceAll("/+$", "");
        URI uri = new URI(baseUrl);
        String host = uri.getHost();
        boolean local = host != null && (host.equals("localhost") || host.equals("127.0.0.1") || host.startsWith("192.168.") || host.startsWith("10.") || host.matches("172\\.(1[6-9]|2[0-9]|3[01])\\..*"));
        if (host == null || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null || (!"https".equals(uri.getScheme()) && !("http".equals(uri.getScheme()) && local))) throw new IllegalArgumentException("Use HTTPS, or a local/private HTTP address for debugging.");
        if (uri.getPath() != null && !uri.getPath().isEmpty()) throw new IllegalArgumentException("Server URL must not include a path.");
        id = json.getString("id"); if (!id.matches("[a-f0-9-]{36}")) throw new IllegalArgumentException("Invalid session id");
        token = json.getString(isWatch ? "watchToken" : "ownerToken");
        if (token.length() < 32 || token.length() > 128) throw new IllegalArgumentException("Invalid access token");
        watchToken = json.optString("watchToken", "");
        initialHeading = json.optDouble("initialHeading", 0); stride = json.optDouble("strideMeters", 0.72);
    }
    public String raw() { return json.toString(); }
    public String forWatch() throws Exception {
        return new JSONObject().put("baseUrl", baseUrl).put("id", id).put("watchToken", watchToken)
            .put("initialHeading", initialHeading).put("strideMeters", stride).toString();
    }
    public static SharedPreferences prefs(Context c) { return c.getSharedPreferences("kaze", Context.MODE_PRIVATE); }
    public static Config load(Context c, boolean watch) { try { return new Config(prefs(c).getString("config", ""), watch); } catch (Exception e) { return null; } }
    public void save(Context c) { prefs(c).edit().putString("config", raw()).apply(); }
}
