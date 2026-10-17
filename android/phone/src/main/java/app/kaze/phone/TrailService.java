package app.kaze.phone;
import app.kaze.shared.MonitoringService;
public final class TrailService extends MonitoringService {
    protected boolean isWatch() { return false; }
    protected Class<?> activityClass() { return MainActivity.class; }
}
