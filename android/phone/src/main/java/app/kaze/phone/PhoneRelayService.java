package app.kaze.phone;
import app.kaze.shared.Config;
import app.kaze.shared.Transport;
import app.kaze.shared.WatchPairing;
import com.google.android.gms.wearable.MessageEvent;
import com.google.android.gms.wearable.Wearable;
import com.google.android.gms.wearable.WearableListenerService;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
public final class PhoneRelayService extends WearableListenerService {
    @Override public void onMessageReceived(MessageEvent event) {
        if (event.getPath().equals(WatchPairing.REQUEST)) {
            Config owner = Config.load(this, false);
            try {
                boolean active = owner != null && Config.prefs(this).getBoolean("active", false);
                Wearable.getMessageClient(this).sendMessage(event.getSourceNodeId(), active ? WatchPairing.CONFIG : WatchPairing.STATUS,
                    (active ? owner.forWatch() : "Start a safety session in KAZE on your phone first.").getBytes(StandardCharsets.UTF_8));
            } catch (Exception ignored) { /* The watch retries discovery while its screen is open. */ }
            return;
        }
        if (!event.getPath().equals("/kaze/request")) return;
        // WearableListenerService callbacks run on a background thread.
        JSONObject reply = new JSONObject();
        try {
            JSONObject message = new JSONObject(new String(event.getData(), StandardCharsets.UTF_8));
            reply.put("requestId", message.getString("requestId"));
            Config owner = Config.load(this, false);
            if (owner == null || !owner.id.equals(message.getString("sessionId"))) throw new IllegalStateException("Phone session does not match watch");
            String action = message.getString("action");
            if (!action.equals("") && !action.equals("events") && !action.equals("check-in")) throw new IllegalStateException("Relay action denied");
            // Use watch-scoped access, never the phone's owner credential.
            reply.put("result", Transport.request(new Config(owner.forWatch(), true), action, message.optJSONObject("body")));
        } catch (Exception e) { try { reply.put("relayError", e.getMessage()); if(e instanceof Transport.HttpError) reply.put("httpStatus", ((Transport.HttpError)e).status); } catch (Exception ignored) {} }
        Wearable.getMessageClient(this).sendMessage(event.getSourceNodeId(), "/kaze/response", reply.toString().getBytes(StandardCharsets.UTF_8));
    }
}
