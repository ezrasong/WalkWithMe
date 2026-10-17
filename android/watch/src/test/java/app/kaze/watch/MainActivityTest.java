package app.kaze.watch;

import android.app.Application;
import android.content.Intent;
import app.kaze.shared.Config;
import app.kaze.shared.MonitoringService;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk = 28)
public class MainActivityTest {
    @Test public void reopeningAnArmedSessionResumesItsServiceWithoutCheckingInOrReplacingAccess() throws Exception {
        Application app = RuntimeEnvironment.getApplication();
        String id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
        Config config = new Config(new JSONObject().put("baseUrl", "https://example.org").put("id", id)
            .put("watchToken", "watch-0123456789012345678901234567890123456789").toString(), true);
        Config.prefs(app).edit().clear().commit();
        config.save(app);
        long due = System.currentTimeMillis() + 60000;
        Config.prefs(app).edit().putBoolean("active", true).putLong("dueAt", due).commit();

        // This recreates the state after force-stop: persisted consent, no service.
        var activity = Robolectric.buildActivity(MainActivity.class).create().resume();
        Intent started = Shadows.shadowOf(app).getNextStartedService();
        assertNotNull(started);
        assertEquals(WatchService.class.getName(), started.getComponent().getClassName());
        assertEquals(MonitoringService.REFRESH, started.getAction());
        assertNull(Shadows.shadowOf(app).getNextStartedService());
        assertEquals(due, Config.prefs(app).getLong("dueAt", 0));
        assertEquals(config.raw(), Config.load(app, true).raw());
        activity.pause().stop().destroy();
    }
}
