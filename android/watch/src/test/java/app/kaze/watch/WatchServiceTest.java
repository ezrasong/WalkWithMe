package app.kaze.watch;

import android.app.Notification;
import android.app.NotificationManager;
import android.content.Intent;
import androidx.wear.ongoing.OngoingActivity;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk = 28)
public class WatchServiceTest {
    @Test public void activeSessionPublishesRecoverableOngoingActivityWithSilentReturnToKaze() {
        var controller = Robolectric.buildService(WatchService.class).create();
        WatchService service = controller.get();
        Notification notification = service.recordingNotification();
        NotificationManager manager = service.getSystemService(NotificationManager.class);
        manager.notify(1, notification);
        OngoingActivity ongoing = OngoingActivity.recoverOngoingActivity(service);
        assertNotNull(ongoing);
        assertTrue((notification.flags & Notification.FLAG_ONGOING_EVENT) != 0);
        assertEquals(Notification.CATEGORY_LOCATION_SHARING, notification.category);
        Intent open = Shadows.shadowOf(ongoing.getTouchIntent()).getSavedIntent();
        assertEquals(MainActivity.class.getName(), open.getComponent().getClassName());
        assertTrue((open.getFlags() & Intent.FLAG_ACTIVITY_SINGLE_TOP) != 0);
        assertNull(notification.sound); assertNull(notification.vibrate);
        manager.cancel(1); controller.destroy();
    }
}
