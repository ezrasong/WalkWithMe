import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { gzipSync } from 'node:zlib';
import { MotionEvaluator } from '../src/motion.js';

const cache = path.join(homedir(), '.cache/kaze-motion');
const python = path.join(cache, 'venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
test('backend loads actual weights once, refuses concurrent work and survives malformed sensor batches', {
  skip: !existsSync(python) || !existsSync(path.join(cache, 'ronin_resnet.zip')), timeout: 30000,
}, async t => {
  const evaluator = new MotionEvaluator(python); t.after(() => evaluator.close());
  const origin = 1000000000;
  const metadata = { version:1, source:'phone', clock:'elapsedRealtimeNanos', startedNs:origin, startedUtcMs:Date.now(),
    frame:'Android-game-rotation-z-up-yaw-unknown', accelSensor:1, gyroSensor:4, rotationSensor:15,
    accelerationUnits:'m/s^2-including-gravity', angularRateUnits:'rad/s' };
  const rows = [];
  for (let i = 0; i <= 500; i++) {
    const ns = origin + i * 5000000;
    rows.push(`${ns},accel,0,0,9.81,,,,`, `${ns},gyro,0,0,0,,,,`, `${ns},rotation,0,0,0,1,,,`);
  }
  const capture = `# ${JSON.stringify(metadata)}\nt_ns,sensor,x,y,z,w,bx,by,bz\n${rows.join('\n')}\n# ${JSON.stringify({ complete:true, reason:'user-stopped', samples:rows.length })}\n`;
  const payload = gzipSync(capture).toString('base64');
  const pending = evaluator.evaluate(payload);
  await assert.rejects(evaluator.evaluate(payload), { status:429 });
  const result = await pending, pid = evaluator.child.pid;
  assert.equal(result.geographic, false); assert.equal(result.guidanceAllowed, false);
  assert.equal(result.independentBatchOrigin, true); assert.ok(result.segments.length);
  await assert.rejects(evaluator.evaluate(gzipSync('# []\n').toString('base64')), { status:422 });
  assert.equal((await evaluator.evaluate(payload)).performance.device, 'cpu');
  assert.equal(evaluator.child.pid, pid);
});
