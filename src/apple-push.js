import { connect } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Apple credentials stay on the server. Neither private links nor location enter a push payload.
export function applePushFromEnv(env = process.env) {
  const names = ['KAZE_APNS_KEY_FILE', 'KAZE_APNS_KEY_ID', 'KAZE_APNS_TEAM_ID', 'KAZE_APNS_TOPIC', 'KAZE_APNS_ENVIRONMENT'];
  if (names.every(name => !env[name])) return null;
  if (names.some(name => !env[name])) throw new Error('Set all KAZE_APNS settings before enabling Apple push.');
  return new ApplePush({ key: readFileSync(env.KAZE_APNS_KEY_FILE), keyId: env.KAZE_APNS_KEY_ID,
    teamId: env.KAZE_APNS_TEAM_ID, topic: env.KAZE_APNS_TOPIC, environment: env.KAZE_APNS_ENVIRONMENT });
}

export class ApplePush {
  constructor({ key, keyId, teamId, topic, environment, now = Date.now, transport = connect }) {
    if (!['development', 'production'].includes(environment) || !/^[A-Z0-9]{10}$/.test(keyId) ||
        !/^[A-Z0-9]{10}$/.test(teamId) || !/^[A-Za-z0-9.-]{1,200}$/.test(topic)) throw new Error('Invalid Apple push configuration.');
    this.key = createPrivateKey(key);
    if (this.key.asymmetricKeyType !== 'ec' || this.key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('Apple push requires a P-256 signing key.');
    Object.assign(this, { keyId, teamId, topic, environment, now, transport });
  }
  authorization() {
    const seconds = Math.floor(this.now() / 1000);
    if (!this.jwt || seconds - this.issued >= 3000 || seconds < this.issued) {
      const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
      const unsigned = `${encode({ alg: 'ES256', kid: this.keyId })}.${encode({ iss: this.teamId, iat: seconds })}`;
      this.jwt = `${unsigned}.${sign('sha256', Buffer.from(unsigned), { key: this.key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
      this.issued = seconds;
    }
    return `bearer ${this.jwt}`;
  }
  async send(registration) {
    const host = this.environment === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    const authorization = this.authorization();
    return new Promise((resolve, reject) => {
      const client = this.transport(host);
      let settled = false;
      const finish = (error, value) => {
        if (settled) return; settled = true; clearTimeout(timeout); client.destroy();
        if (error) reject(new Error('Apple push connection unavailable')); else resolve(value);
      };
      const timeout = setTimeout(() => finish(true), 10000);
      client.on('error', () => finish(true));
      try {
        const request = client.request({ ':method': 'POST', ':path': `/3/device/${registration.token}`,
          authorization, 'apns-topic': this.topic, 'apns-push-type': 'alert', 'apns-priority': '10',
          // Do not queue an old safety request while a device is offline.
          'apns-expiration': '0', 'apns-collapse-id': registration.registrationId });
        let status, response = '';
        request.on('response', headers => { status = headers[':status']; });
        request.setEncoding('utf8');
        request.on('data', chunk => { if (response.length < 4096) response += chunk; });
        request.on('error', () => finish(true));
        request.on('end', () => {
          let reason; try { reason = JSON.parse(response).reason; } catch { /* Apple success has no body. */ }
          finish(null, { accepted: status === 200,
            invalid: status === 410 || (status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(reason)) });
        });
        request.end(JSON.stringify({ aps: { alert: { title: 'KAZE guardian — simulation',
          body: 'A check-in went unanswered. Open KAZE to review the current request.' }, sound: 'default' },
          kazeRegistration: registration.registrationId }));
      } catch { finish(true); }
    });
  }
}

// One worker owns delivery. Recheck access immediately before each send and after every await.
export class GuardianPushDelivery {
  constructor(store, provider, current, now) { Object.assign(this, { store, provider, current, now }); this.closed = false; }
  async flush() {
    if (!this.provider || this.busy || this.closed) return;
    this.busy = true;
    try {
      for (const registration of this.store.guardianPushes()) {
        if (this.closed) break;
        let session;
        try { session = this.current(registration.sessionId); } catch { session = null; }
        if (!session || session.guardianHash !== registration.guardianHash || session.guardianRevokedAt || ['resolved', 'expired'].includes(session.phase)) {
          this.store.removeGuardianPush(registration.sessionId, registration.registrationId); continue;
        }
        if (session.phase !== 'alert' || session.acknowledgedAt || registration.acceptedAt || registration.nextAttemptAt > this.now()) continue;
        let result;
        try { result = await this.provider.send(registration); } catch { result = { accepted: false }; }
        if (this.closed) break;
        const latest = this.store.guardianPush(registration.sessionId, registration.registrationId);
        if (!latest || latest.generation !== registration.generation || latest.guardianHash !== registration.guardianHash) continue;
        if (result.invalid) this.store.removeGuardianPush(registration.sessionId, registration.registrationId);
        else this.store.saveGuardianPush({ ...latest, acceptedAt: result.accepted ? this.now() : null,
          nextAttemptAt: this.now() + 30000 });
      }
    } finally { this.busy = false; }
  }
  close() { this.closed = true; }
}
