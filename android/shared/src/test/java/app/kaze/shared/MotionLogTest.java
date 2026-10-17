package app.kaze.shared;

import android.content.Context;
import java.nio.file.Files;
import java.io.File;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;
import org.junit.*;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk=28)
public class MotionLogTest {
    @Rule public TemporaryFolder folder = new TemporaryFolder();
    private JSONObject metadata() throws Exception { return new JSONObject().put("version",1).put("source","phone"); }
    @Test public void capturePreservesBiasQuaternionAndTimestampWithoutAnUploadEvent() throws Exception {
        File dir=folder.newFolder(); MotionLog log=new MotionLog(dir,100,metadata());
        assertTrue(log.sample(90,"gyro",new float[]{9,9,9})); // pre-consent callback ignored
        assertTrue(log.sample(200,"gyro",new float[]{1,2,3,.1f,.2f,.3f}));
        assertTrue(log.sample(201,"rotation",new float[]{0,0,0,1}));
        assertEquals(2,log.samples());
        assertFalse(new File(dir,"motion.csv").exists());
        log.finish("user-stopped");
        String text=new String(Files.readAllBytes(new File(dir,"motion.csv").toPath()), StandardCharsets.UTF_8);
        assertTrue(text.contains("200,gyro,1.0,2.0,3.0,,0.1,0.2,0.3"));
        assertTrue(text.contains("201,rotation,0.0,0.0,0.0,1.0,,,"));
        assertTrue(text.contains("\"samples\":2")); assertFalse(text.contains("90,gyro"));
        assertFalse(new File(dir,"motion.csv.partial").exists());
        try { new MotionLog(dir,300,metadata()); fail("Previous capture must survive"); } catch(java.io.IOException expected) {}
    }
    @Test public void durationAndInvalidSensorDataCannotGrowAnUnboundedCapture() throws Exception {
        File dir=folder.newFolder(); MotionLog log=new MotionLog(dir,100,metadata());
        assertFalse(log.sample(101+MotionLog.MAX_NANOS,"accel",new float[]{0,0,9.81f}));
        try { log.sample(200,"accel",new float[]{Float.NaN,0,0}); fail(); } catch(java.io.IOException expected) {}
        try { log.sample(200,"rotation",new float[]{0,0,0}); fail(); } catch(java.io.IOException expected) {}
        assertEquals(0,log.samples()); log.close();
        assertFalse(new File(dir,"motion.csv").exists());
    }
    @Test public void expiredOrEndedSessionPurgesLocalEvaluationFiles() throws Exception {
        Context c=RuntimeEnvironment.getApplication();Config.prefs(c).edit().clear().commit();
        MotionCapture.delete(c);
        File dir=MotionCapture.directory(c);dir.mkdirs();
        Files.write(new File(dir,"motion.csv").toPath(),"private capture".getBytes(StandardCharsets.UTF_8));
        assertEquals(false,MotionCapture.status(c).get("available"));
        assertFalse(new File(dir,"motion.csv").exists());
    }
    @Test public void watchAndInactiveConfigCannotStartLocalMotionSensors() throws Exception {
        Context c=RuntimeEnvironment.getApplication();Config.prefs(c).edit().clear().commit();
        String raw=new JSONObject().put("baseUrl","http://127.0.0.1:4173").put("id","aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            .put("ownerToken","owner-0123456789012345678901234567890123456789")
            .put("watchToken","watch-0123456789012345678901234567890123456789").toString();
        MotionCapture capture=new MotionCapture(c);
        try { capture.start(new Config(raw,false),true,false);fail(); } catch(IllegalStateException expected) {}
        Config.prefs(c).edit().putBoolean("active",true).putLong("expiresAt",System.currentTimeMillis()+100000).commit();
        try { capture.start(new Config(raw,true),true,false);fail(); } catch(IllegalStateException expected) {}
        Config.prefs(c).edit().clear().commit();
    }
}
