package app.kaze.shared;

import android.content.Context;
import com.google.android.gms.tasks.Tasks;
import com.google.android.gms.wearable.Wearable;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

public final class Relay {
    private static final ConcurrentHashMap<String, CompletableFuture<JSONObject>> pending = new ConcurrentHashMap<>();
    public static JSONObject request(Context context, Config config, String action, JSONObject body) throws Exception {
        String id = UUID.randomUUID().toString();
        CompletableFuture<JSONObject> result = new CompletableFuture<>(); pending.put(id, result);
        try {
            JSONObject message = new JSONObject().put("requestId", id).put("sessionId", config.id).put("action", action);
            message.put("watchRemindersReady", Config.prefs(context).getBoolean("active", false) && MonitoringService.vibrationRemindersAvailable(context));
            if (body != null) message.put("body", body);
            var nodes = Tasks.await(Wearable.getNodeClient(context).getConnectedNodes(), 3, TimeUnit.SECONDS);
            if (nodes.isEmpty()) throw new IllegalStateException("No connected phone relay");
            Tasks.await(Wearable.getMessageClient(context).sendMessage(nodes.get(0).getId(), "/kaze/request", message.toString().getBytes(StandardCharsets.UTF_8)), 3, TimeUnit.SECONDS);
            JSONObject response = result.get(8, TimeUnit.SECONDS);
            if (response.has("relayError")) {
                if (response.has("httpStatus")) throw new Transport.HttpError(response.getInt("httpStatus"), response.getString("relayError"));
                throw new IllegalStateException(response.getString("relayError"));
            }
            return response.getJSONObject("result");
        } finally { pending.remove(id); }
    }
    public static void receive(byte[] data) {
        try { JSONObject message = new JSONObject(new String(data, StandardCharsets.UTF_8)); var future = pending.get(message.getString("requestId")); if (future != null) future.complete(message); } catch (Exception ignored) {}
    }
}
