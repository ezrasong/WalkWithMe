package app.kaze.watch;
import app.kaze.shared.Config;
import app.kaze.shared.Relay;
import app.kaze.shared.WatchPairing;
import com.google.android.gms.wearable.MessageEvent;
import com.google.android.gms.wearable.WearableListenerService;
import java.nio.charset.StandardCharsets;
public final class PairingListener extends WearableListenerService {
    @Override public void onMessageReceived(MessageEvent event) {
        if (event.getPath().equals("/kaze/response")) Relay.receive(event.getData());
        if (event.getPath().equals(WatchPairing.STATUS)) WatchPairing.unavailable(this, "Start a safety session in KAZE on your phone first.");
        if (event.getPath().equals(WatchPairing.CONFIG)) {
            try {
                WatchPairing.accept(this, new String(event.getData(), StandardCharsets.UTF_8));
            } catch (Exception ignored) {}
        }
    }
}
