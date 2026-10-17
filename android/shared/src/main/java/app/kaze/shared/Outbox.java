package app.kaze.shared;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.UUID;

public final class Outbox extends SQLiteOpenHelper {
    private final Context context;
    public Outbox(Context c) { super(c, "outbox.db", null, 1); context = c; }
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE queue(row_id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, payload TEXT NOT NULL)");
        db.execSQL("CREATE TABLE sequences(session TEXT, source TEXT, seq INTEGER, PRIMARY KEY(session,source))");
    }
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {}
    public synchronized void add(Config config, String source, JSONObject event) throws Exception {
        SQLiteDatabase db = getWritableDatabase(); db.beginTransaction();
        try {
            long seq = 0;
            try (Cursor c = db.rawQuery("SELECT seq FROM sequences WHERE session=? AND source=?", new String[]{config.id, source})) { if (c.moveToFirst()) seq = c.getLong(0); }
            db.execSQL("INSERT OR REPLACE INTO sequences VALUES(?,?,?)", new Object[]{config.id, source, seq + 1});
            event.put("id", UUID.randomUUID().toString()).put("seq", seq + 1).put("source", source);
            if (!event.has("at")) event.put("at", Transport.serverNow(context));
            db.execSQL("INSERT INTO queue(session,payload) VALUES(?,?)", new Object[]{config.id, event.toString()}); db.setTransactionSuccessful();
        } finally { db.endTransaction(); }
    }
    public synchronized int count(String session) { try (Cursor c = getReadableDatabase().rawQuery("SELECT count(*) FROM queue WHERE session=?", new String[]{session})) { c.moveToFirst(); return c.getInt(0); } }
    public JSONObject flush(Config config) throws Exception {
        JSONArray batch = new JSONArray(); long last = 0; int bytes = 0;
        try (Cursor c = getReadableDatabase().rawQuery("SELECT row_id,payload FROM queue WHERE session=? ORDER BY row_id LIMIT 40", new String[]{config.id})) {
            while (c.moveToNext()) {
                String payload = c.getString(1); int size = payload.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
                if (batch.length() > 0 && bytes + size > 300000) break;
                batch.put(new JSONObject(payload)); last = c.getLong(0); bytes += size;
            }
        }
        if (batch.length() == 0) return null;
        long start = System.currentTimeMillis();
        JSONObject result = Transport.send(context, config, "events", new JSONObject().put("events", batch));
        Transport.saveClock(context, result, start);
        getWritableDatabase().execSQL("DELETE FROM queue WHERE session=? AND row_id<=?", new Object[]{config.id, last});
        return result;
    }
    public void deleteSession(String id) { getWritableDatabase().execSQL("DELETE FROM queue WHERE session=?", new Object[]{id}); }
}
