package app.kaze.shared;

import android.net.NetworkCapabilities;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import static org.junit.Assert.*;
import static org.robolectric.Shadows.shadowOf;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk=28)
public class MotionStreamTest {
    @Test public void defaultPolicyRejectsCellularMeteredWifiAndUnvalidatedNetworks() {
        NetworkCapabilities wifi = new NetworkCapabilities();
        shadowOf(wifi).addTransportType(NetworkCapabilities.TRANSPORT_WIFI);
        shadowOf(wifi).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        shadowOf(wifi).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
        assertTrue(MotionStream.allowed(wifi, false));
        shadowOf(wifi).removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
        assertFalse(MotionStream.allowed(wifi, false));
        assertTrue(MotionStream.allowed(wifi, true));
        shadowOf(wifi).removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        assertFalse(MotionStream.allowed(wifi, true));
        NetworkCapabilities cellular = new NetworkCapabilities();
        shadowOf(cellular).addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR);
        shadowOf(cellular).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        shadowOf(cellular).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
        assertFalse(MotionStream.allowed(cellular, false));
        assertTrue(MotionStream.allowed(cellular, true));
        assertFalse(MotionStream.allowed(null, true));
    }
}
