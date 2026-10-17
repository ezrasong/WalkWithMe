package app.kaze.watch;
import app.kaze.shared.MonitoringService;
public final class WatchService extends MonitoringService {
    protected boolean isWatch() { return true; }
    protected Class<?> activityClass() { return MainActivity.class; }
}
