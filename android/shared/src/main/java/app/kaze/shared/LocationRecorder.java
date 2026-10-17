package app.kaze.shared;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.location.*;
import android.os.*;
import org.json.JSONObject;

/** LocationManager owns positioning. Motion readings never create geographic fixes. */
public final class LocationRecorder implements LocationListener {
    private final Context context;
    private final LocationManager manager;
    private final Config config;
    private final SensorRecorder.Sink sink;
    private boolean running;
    public LocationRecorder(Context context, Config config, SensorRecorder.Sink sink) {
        this.context = context; this.config = config; this.sink = sink;
        manager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
    }
    public static boolean permitted(Context c) {
        return c.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            c.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }
    public void start() {
        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) return;
        if (manager == null) return;
        running = true;
        // Wear fused/network locations may originate on the paired phone. Record provider unchanged.
        for (String provider : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, "fused"}) {
            try { if (manager.getAllProviders().contains(provider)) manager.requestLocationUpdates(provider, 5000, 0, this, Looper.getMainLooper()); }
            catch (SecurityException | IllegalArgumentException ignored) { /* Permission/provider loss leaves check-ins running. */ }
        }
    }
    public void stop() { running = false; if (manager != null) manager.removeUpdates(this); }
    @Override public void onLocationChanged(Location location) {
        if (!running || !location.hasAccuracy()) return;
        try {
            JSONObject event = evidence(context, config, location);
            if (event != null) sink.emit(config.watch ? "watch" : "phone", event);
        } catch (Exception ignored) { /* A malformed fix must not interrupt session control. */ }
    }
    static JSONObject evidence(Context c, Config config, Location location) throws Exception {
        long age = Math.max(0, (SystemClock.elapsedRealtimeNanos() - location.getElapsedRealtimeNanos()) / 1000000);
        long fixAt = Transport.serverNow(c) - age;
        if (fixAt < Config.prefs(c).getLong("createdAt", 0) || age > 8 * 3600000L) return null;
        String provider = location.getProvider() == null ? "unknown" : location.getProvider();
        JSONObject event = new JSONObject().put("type", "gps").put("fixAt", fixAt)
            .put("latitude", location.getLatitude()).put("longitude", location.getLongitude()).put("accuracy", location.getAccuracy())
            .put("provider", provider).put("provenance", "gps".equals(provider) ? "device-gnss" : config.watch ? "possibly-phone-derived" : "unknown")
            .put("mock", location.isFromMockProvider());
        if (location.hasAltitude()) event.put("altitude", location.getAltitude());
        if (location.hasVerticalAccuracy()) event.put("verticalAccuracy", location.getVerticalAccuracyMeters());
        return event;
    }
    @Override public void onProviderDisabled(String provider) {}
    @Override public void onProviderEnabled(String provider) {}
    @Override public void onStatusChanged(String provider, int status, Bundle extras) {}
}
