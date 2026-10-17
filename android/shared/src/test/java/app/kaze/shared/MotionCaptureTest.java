package app.kaze.shared;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorManager;
import android.os.Handler;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.shadows.ShadowSensor;
import org.robolectric.util.ReflectionHelpers;
import java.io.File;
import java.time.Duration;
import static org.junit.Assert.*;
import static org.robolectric.Shadows.shadowOf;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk=28)
public class MotionCaptureTest {
    private Context context;
    private MotionCapture capture;
    private Config config;
    private Config config(String id) throws Exception {
        return new Config(new JSONObject().put("baseUrl","http://127.0.0.1:4173").put("id",id)
            .put("ownerToken","owner-0123456789012345678901234567890123456789").toString(), false);
    }
    @Before public void setup() throws Exception {
        context = RuntimeEnvironment.getApplication();
        Config.prefs(context).edit().clear().putBoolean("active",true)
            .putLong("expiresAt",System.currentTimeMillis()+3600000).putLong("dueAt",12345).commit();
        config = config("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"); config.save(context);
        SensorManager manager = context.getSystemService(SensorManager.class);
        for (int type : new int[]{Sensor.TYPE_ACCELEROMETER,Sensor.TYPE_GYROSCOPE,Sensor.TYPE_GAME_ROTATION_VECTOR})
            shadowOf(manager).addSensor(ShadowSensor.newInstance(type));
        capture = new MotionCapture(context);
    }
    @After public void cleanup() { capture.stop("service-stopped"); MotionCapture.delete(context); }
    @Test public void automaticSessionStreamingAllowsCellularAndSurvivesThreeMinutesWithoutDiskCapture() {
        capture.startAutomatic(config);
        assertEquals(true,MotionCapture.status(context).get("recording"));
        assertEquals(true,MotionCapture.status(context).get("automatic"));
        assertEquals(true,MotionCapture.status(context).get("cellular"));
        Handler handler = ReflectionHelpers.getField(capture,"handler");
        shadowOf(handler.getLooper()).idleFor(Duration.ofMinutes(4));
        assertEquals(true,MotionCapture.status(context).get("recording"));
        assertFalse(new File(MotionCapture.directory(context),"motion.csv.partial").exists());
        assertFalse(new File(MotionCapture.directory(context),"motion.csv").exists());
        assertEquals(12345,Config.prefs(context).getLong("dueAt",0));
    }
    @Test public void manualStopSurvivesRecorderRestartAndOnlyANewSessionEnablesAutomaticStreaming() throws Exception {
        capture.startAutomatic(config); capture.stopForSession(config);
        capture = new MotionCapture(context); capture.startAutomatic(config);
        assertEquals(false,MotionCapture.status(context).get("recording"));
        Config next = config("bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee");next.save(context);
        capture.startAutomatic(next);
        assertEquals(true,MotionCapture.status(context).get("recording"));
    }
    @Test public void expiryStopsStreamingEvenWithoutAnotherBackendResponse() {
        capture.startAutomatic(config);
        Handler handler = ReflectionHelpers.getField(capture,"handler");
        Config.prefs(context).edit().putLong("expiresAt",System.currentTimeMillis()-1).commit();
        try { shadowOf(handler.getLooper()).idleFor(Duration.ofSeconds(2)); }
        catch (IllegalStateException expected) { assertEquals("Looper is quitting", expected.getMessage()); }
        assertEquals(false,MotionCapture.status(context).get("recording"));
        assertFalse(shadowOf(context.getSystemService(SensorManager.class)).hasListener(capture));
    }
}
