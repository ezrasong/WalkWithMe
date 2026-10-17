package app.kaze.shared;
import android.content.Context;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import static org.junit.Assert.*;
@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk=28)
public class WatchPairingTest {
 private Context c;
 private String payload(String id)throws Exception { return new JSONObject().put("baseUrl","https://example.org").put("id",id)
  .put("watchToken","watch-0123456789012345678901234567890123456789")
  .put("ownerToken","owner-0123456789012345678901234567890123456789").put("guardianToken","guardian-secret-must-not-transfer").toString(); }
 private static final String FIRST="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", SECOND="bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee";
 @Before public void setup(){c=RuntimeEnvironment.getApplication();WatchPairing.finishStart();Config.prefs(c).edit().clear().commit();}
 @After public void cleanup(){WatchPairing.finishStart();}
 @Test public void discoveredConfigContainsOnlyWatchAccessAndNeverArmsRecording()throws Exception{
  assertTrue(WatchPairing.accept(c,payload(FIRST)));JSONObject stored=new JSONObject(Config.load(c,true).raw());
  assertFalse(stored.has("ownerToken"));assertFalse(stored.has("guardianToken"));assertFalse(Config.prefs(c).getBoolean("active",false));
 }
 @Test public void aSessionBeingStartedCannotBeReplacedByALateDiscoveryResponse()throws Exception{
  WatchPairing.accept(c,payload(FIRST));assertEquals(FIRST,WatchPairing.beginStart(c).id);
  assertFalse(WatchPairing.accept(c,payload(SECOND)));WatchPairing.unavailable(c,"unavailable");assertEquals(FIRST,Config.load(c,true).id);
  WatchPairing.finishStart();assertTrue(WatchPairing.accept(c,payload(SECOND)));
 }
 @Test public void activeSessionIsNeverSilentlySwitchedOrCleared()throws Exception{
  WatchPairing.accept(c,payload(FIRST));Config.prefs(c).edit().putBoolean("active",true).commit();
  assertFalse(WatchPairing.accept(c,payload(SECOND)));WatchPairing.unavailable(c,"no session");assertEquals(FIRST,Config.load(c,true).id);
 }
 @Test public void absentPhoneSessionClearsIdleStaleConfig()throws Exception{
  WatchPairing.accept(c,payload(FIRST));WatchPairing.unavailable(c,"Start on phone first");assertNull(Config.load(c,true));
 }
}
