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
    @Test public void overlapRetainsOneFrameAndBoundedContextEvenWhenOffline() throws Exception {
        var context = org.robolectric.RuntimeEnvironment.getApplication();
        Config config = new Config(new org.json.JSONObject().put("baseUrl","http://127.0.0.1:4173")
            .put("id","aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").put("ownerToken","owner-0123456789012345678901234567890123456789").toString(),false);
        MotionStream stream = new MotionStream(context,config,new org.json.JSONObject(),true);
        try {
            for (int i=0;i<2000;i++) {
                org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofMillis(5));
                long stamp=android.os.SystemClock.elapsedRealtimeNanos();
                stream.sample(stamp,"accel",new float[]{0,0,9.81f});
                stream.sample(stamp,"gyro",new float[]{0,0,0});
                stream.sample(stamp,"rotation",new float[]{0,0,0,1});
            }
            String first=stream.capture(0);
            stream.flush();
            String overlap=stream.capture(1);
            var a=new org.json.JSONObject(first.split("\\n")[0].substring(2));
            var b=new org.json.JSONObject(overlap.split("\\n")[0].substring(2));
            assertEquals(a.getString("streamId"),b.getString("streamId"));
            assertEquals(a.getLong("streamStartedNs"),b.getLong("streamStartedNs"));
            assertEquals(a.getLong("streamStartedUtcMs"),b.getLong("streamStartedUtcMs"));
            assertEquals(1,b.getLong("batchSequence"));
            assertTrue(b.getLong("startedNs")>a.getLong("startedNs")+8000000000L);
            assertTrue(overlap.length()<first.length()/5);
            long firstRetained=Long.parseLong(overlap.split("\\n")[2].split(",")[0]);
            assertTrue(firstRetained>=b.getLong("startedNs"));
            assertTrue(firstRetained<=b.getLong("startedNs")+5000000L);
        } finally {stream.close();}
    }
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
