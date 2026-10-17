package app.kaze.shared;

import android.content.Context;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(sdk = 28)
public class OutboxTest {
    private Context context;
    @Before public void setup() { context=RuntimeEnvironment.getApplication();context.deleteDatabase("outbox.db"); }
    private Config config(String base,boolean watch) throws Exception {
        return new Config(new JSONObject().put("baseUrl",base).put("id","aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            .put("ownerToken","owner-0123456789012345678901234567890123456789").put("watchToken","watch-0123456789012345678901234567890123456789").toString(),watch);
    }
    @Test public void queueAndSequenceSurviveProcessReopen() throws Exception {
        Config c=config("http://127.0.0.1:1",false);
        Outbox first=new Outbox(context);first.add(c,"phone",new JSONObject().put("type","step").put("heading",0));first.close();
        Outbox second=new Outbox(context);assertEquals(1,second.count(c.id));second.add(c,"phone",new JSONObject().put("type","step").put("heading",90));
        try(var cursor=second.getReadableDatabase().rawQuery("SELECT payload FROM queue ORDER BY row_id",null)) { cursor.moveToFirst();JSONObject a=new JSONObject(cursor.getString(0));cursor.moveToNext();JSONObject b=new JSONObject(cursor.getString(0));assertEquals(1,a.getLong("seq"));assertEquals(2,b.getLong("seq"));assertNotEquals(a.getString("id"),b.getString("id")); }
        second.close();
    }
    @Test public void networkFailureNeverDeletesQueuedReadings() throws Exception {
        Config c=config("http://127.0.0.1:1",false);Outbox box=new Outbox(context);box.add(c,"phone",new JSONObject().put("type","step").put("heading",0));
        try {box.flush(c);fail("Expected connection failure");}catch(Exception expected) {}assertEquals(1,box.count(c.id));box.close();
    }
    @Test public void acknowledgedBatchOnlyIsDeletedAndImagesAreSplitToFitServerLimit() throws Exception {
        try(ServerSocket socket=new ServerSocket(0)) {
            var worker=Executors.newSingleThreadExecutor();
            var reply=worker.submit(()-> {
                try(var client=socket.accept()) {
                    var input=client.getInputStream();StringBuilder headers=new StringBuilder();int value;
                    while((value=input.read())!=-1) {headers.append((char)value);if(headers.toString().endsWith("\r\n\r\n"))break;}
                    int length=0;for(String line:headers.toString().split("\r\n"))if(line.toLowerCase().startsWith("content-length:"))length=Integer.parseInt(line.split(":",2)[1].trim());
                    byte[] bytes=new byte[length];int offset=0;while(offset<length){int n=input.read(bytes,offset,length-offset);if(n<0)break;offset+=n;}
                    JSONObject request=new JSONObject(new String(bytes,StandardCharsets.UTF_8));assertEquals(1,request.getJSONArray("events").length());
                    String response="{\"serverNow\":1000,\"phase\":\"armed\",\"dueAt\":5000}";
                    client.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+response.length()+"\r\nConnection: close\r\n\r\n"+response).getBytes(StandardCharsets.UTF_8));
                }return null;
            });
            Config c=config("http://127.0.0.1:"+socket.getLocalPort(),false);Outbox box=new Outbox(context);
            for(int i=0;i<2;i++) box.add(c,"camera",new JSONObject().put("type","checkpoint").put("imageData","x".repeat(190000)));
            box.flush(c);reply.get(10,java.util.concurrent.TimeUnit.SECONDS);assertEquals(1,box.count(c.id));box.close();worker.shutdownNow();
        }
    }
    @Test public void watchPairingNeverIncludesOwnerCredential() throws Exception { Config owner=config("https://example.org",false);assertFalse(new JSONObject(owner.forWatch()).has("ownerToken"));assertEquals(owner.watchToken,new Config(owner.forWatch(),true).token); }
    @Test public void insecurePublicServerAndEmbeddedCredentialsAreRejected() throws Exception {
        for(String base:new String[]{"http://example.org","https://user:pass@example.org","https://example.org/path"}) { try{config(base,false);fail("Expected rejection");}catch(IllegalArgumentException expected){} }
    }
}
