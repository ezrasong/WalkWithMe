import { DatabaseSync } from 'node:sqlite';

export class Store {
  constructor(path) {
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, body TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events (session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        id TEXT NOT NULL, source TEXT NOT NULL, seq INTEGER NOT NULL, at REAL NOT NULL, body TEXT NOT NULL,
        PRIMARY KEY(session_id,id), UNIQUE(session_id,source,seq));
      CREATE TABLE IF NOT EXISTS activity(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        at REAL NOT NULL, action TEXT NOT NULL, role TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS guardian_push(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        registration_id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(session_id,registration_id));`);
  }
  get(id) { const row = this.db.prepare('SELECT body FROM sessions WHERE id=?').get(id); return row ? JSON.parse(row.body) : null; }
  save(s) { this.db.prepare('INSERT INTO sessions VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body').run(s.id, JSON.stringify(s)); }
  all() { return this.db.prepare('SELECT body FROM sessions').all().map(r => JSON.parse(r.body)); }
  events(id) { return this.db.prepare('SELECT body FROM events WHERE session_id=? ORDER BY at,source,seq').all(id).map(r => JSON.parse(r.body)); }
  count(id) { return this.db.prepare('SELECT count(*) AS total FROM events WHERE session_id=?').get(id).total; }
  transaction(fn) { this.db.exec('BEGIN IMMEDIATE'); try { const result = fn(); this.db.exec('COMMIT'); return result; } catch (e) { this.db.exec('ROLLBACK'); throw e; } }
  append(id, events) {
    const insert = this.db.prepare('INSERT OR IGNORE INTO events VALUES (?,?,?,?,?,?)');
    const existing = this.db.prepare('SELECT body FROM events WHERE session_id=? AND (id=? OR (source=? AND seq=?))');
    let added = 0;
    for (const e of events) {
      const old = existing.get(id, e.id, e.source, e.seq);
      if (old && old.body !== JSON.stringify(e)) throw Object.assign(new Error('Conflicting replay or device sequence'), { status: 409 });
      added += Number(insert.run(id, e.id, e.source, e.seq, e.at, JSON.stringify(e)).changes);
    }
    return added;
  }
  remove(id) { this.db.prepare('DELETE FROM sessions WHERE id=?').run(id); }
  recordActivity(id, action, at, role) { this.db.prepare('INSERT INTO activity VALUES(?,?,?,?)').run(id, at, action, role); }
  activity(id) { return this.db.prepare('SELECT at,action,role FROM activity WHERE session_id=? ORDER BY at,rowid').all(id); }
  clearEvents(id) { this.db.prepare('DELETE FROM events WHERE session_id=?').run(id); this.db.prepare('DELETE FROM activity WHERE session_id=?').run(id); }
  guardianPushes() { return this.db.prepare('SELECT body FROM guardian_push').all().map(r => JSON.parse(r.body)); }
  guardianPush(sessionId, registrationId) {
    const row = this.db.prepare('SELECT body FROM guardian_push WHERE session_id=? AND registration_id=?').get(sessionId, registrationId);
    return row ? JSON.parse(row.body) : null;
  }
  saveGuardianPush(p) { this.db.prepare('INSERT INTO guardian_push VALUES(?,?,?) ON CONFLICT(session_id,registration_id) DO UPDATE SET body=excluded.body').run(p.sessionId, p.registrationId, JSON.stringify(p)); }
  removeGuardianPush(sessionId, registrationId) {
    if (registrationId) this.db.prepare('DELETE FROM guardian_push WHERE session_id=? AND registration_id=?').run(sessionId, registrationId);
    else this.db.prepare('DELETE FROM guardian_push WHERE session_id=?').run(sessionId);
  }
  close() { this.db.close(); }
}
