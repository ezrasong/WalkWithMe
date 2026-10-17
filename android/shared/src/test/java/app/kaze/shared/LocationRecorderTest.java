package app.kaze.shared;
import android.content.Context;
import android.location.Location;
import android.os.SystemClock;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import static org.junit.Assert.*;
@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk=28)
public class LocationRecorderTest {
 private Context c;
 @Before public void setup(){c=RuntimeEnvironment.getApplication();Config.prefs(c).edit().clear().commit();}
 private Config config(boolean watch)throws Exception{return new Config(new JSONObject().put("baseUrl","http://127.0.0.1:4173").put("id","aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").put("ownerToken","owner-0123456789012345678901234567890123456789").put("watchToken","watch-0123456789012345678901234567890123456789").toString(),watch);}
 @Test public void watchFusedFixUsesMonotonicAgeAndNeverClaimsIndependentGps()throws Exception{
  long clock=System.currentTimeMillis();Config.prefs(c).edit().putLong("clockOffset",10000).putLong("createdAt",clock-60000).commit();
  Location l=new Location("fused");l.setLatitude(43);l.setLongitude(-79);l.setAccuracy(12);l.setTime(1);l.setElapsedRealtimeNanos(SystemClock.elapsedRealtimeNanos());
  JSONObject e=LocationRecorder.evidence(c,config(true),l);
  assertEquals("possibly-phone-derived",e.getString("provenance"));assertTrue(e.getLong("fixAt")>=clock+9000);assertEquals("fused",e.getString("provider"));
 }
 @Test public void preSessionCachedFixIsNotQueued()throws Exception{
  Config.prefs(c).edit().putLong("createdAt",System.currentTimeMillis()+10000).commit();Location l=new Location("gps");l.setElapsedRealtimeNanos(SystemClock.elapsedRealtimeNanos());
  assertNull(LocationRecorder.evidence(c,config(false),l));
 }
 @Test public void deniedLocationAndStoppedCallbacksDoNotGenerateCoordinates()throws Exception{
  final int[] count={0};LocationRecorder r=new LocationRecorder(c,config(false),(source,event)->count[0]++);r.start();r.stop();Location l=new Location("gps");l.setAccuracy(5);r.onLocationChanged(l);assertEquals(0,count[0]);
 }
}
