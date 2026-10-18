package app.kaze.watch;
import android.app.Notification;
import android.app.PendingIntent;
import android.content.Intent;
import androidx.core.app.NotificationCompat;
import androidx.wear.ongoing.OngoingActivity;
import app.kaze.shared.MonitoringService;
public final class WatchService extends MonitoringService {
    protected boolean isWatch() { return true; }
    protected Class<?> activityClass() { return MainActivity.class; }
    @Override protected Notification recordingNotification() {
        Intent open = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent touch = PendingIntent.getActivity(this, 0, open,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, "recording")
            .setSmallIcon(android.R.drawable.ic_dialog_map).setContentTitle("WalkWithMe")
            .setContentText("Safety session active").setOngoing(true).setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_LOCATION_SHARING).setContentIntent(touch);
        new OngoingActivity.Builder(this, 1, builder).setStaticIcon(android.R.drawable.ic_dialog_map)
            .setTouchIntent(touch).build().apply(this);
        return builder.build();
    }
}
