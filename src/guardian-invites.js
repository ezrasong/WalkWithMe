import { randomBytes } from 'node:crypto';
import { hash, matches, Problem } from './domain.js';

const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const invalid = () => new Problem(404, 'Pairing code is invalid, expired or already used. Ask for a new code.');

// Invitations are deliberately ephemeral: a server restart requires a new code.
// Only the current owner can supply the existing guardian credential. It stays
// in memory for at most five minutes; persistent session credentials stay hashed.
export class GuardianInvites {
  entries = new Map();
  attempts = new Map();
  global = { at: 0, count: 0 };
  constructor(now) { this.now = now; }

  prune() {
    const now = this.now();
    for (const [key, entry] of this.entries) if (entry.expiresAt <= now) this.entries.delete(key);
    for (const [key, limit] of this.attempts) if (now < limit.at || now - limit.at >= 60000) this.attempts.delete(key);
  }

  invalidate(sessionId) {
    for (const [key, entry] of this.entries) if (entry.id === sessionId) this.entries.delete(key);
  }

  issue(session, guardianToken) {
    this.prune();
    if (session.guardianRevokedAt || ['resolved', 'expired'].includes(session.phase))
      throw new Problem(409, 'Guardian pairing is unavailable for this session.');
    if (!matches(guardianToken, session.guardianHash)) throw new Problem(400, 'Current guardian credential required.');
    this.invalidate(session.id);
    if (this.entries.size >= 1000) throw new Problem(429, 'Too many active invitations. Try again shortly.');
    let code;
    do { code = [...randomBytes(10)].map(n => alphabet[n & 31]).join(''); } while (this.entries.has(hash(code)));
    const expiresAt = Math.min(this.now() + 300000, session.expiresAt);
    this.entries.set(hash(code), { id: session.id, guardianToken, expiresAt });
    return { code: `${code.slice(0, 5)}-${code.slice(5)}`, expiresAt, serverNow: this.now() };
  }

  allowAttempt(address) {
    this.prune();
    const now = this.now();
    if (now < this.global.at || now - this.global.at >= 60000) this.global = { at: now, count: 0 };
    // Do not trust forwarded headers: a tunnel may share a limit across phones.
    const limit = this.attempts.get(address) ?? { at: now, count: 0 };
    if (++this.global.count > 120 || ++limit.count > 10)
      throw new Problem(429, 'Too many pairing attempts. Wait a minute before trying again.');
    this.attempts.set(address, limit);
  }

  consume(value) {
    this.prune();
    if (typeof value !== 'string' || value.length > 32) throw invalid();
    const code = value.toUpperCase().replace(/[\s-]/g, '');
    if (!/^[2-9A-HJ-NP-Z]{10}$/.test(code)) throw invalid();
    const key = hash(code), entry = this.entries.get(key);
    if (!entry) throw invalid();
    this.entries.delete(key);
    return entry;
  }
}
