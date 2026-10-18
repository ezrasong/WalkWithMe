import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Problem } from './domain.js';

const workerPath = fileURLToPath(new URL('./motion/worker.py', import.meta.url));
const defaultPython = path.join(homedir(), '.cache/kaze-motion/venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');

// One cached model, one bounded request, no raw-data queue or disk persistence.
export class MotionEvaluator {
  constructor(python = process.env.KAZE_MOTION_PYTHON || defaultPython) {
    this.python = python;
  }
  async evaluate(captureGzip) {
    if (this.busy) throw new Problem(429, 'Motion processor busy; skip this batch');
    if (!existsSync(this.python)) throw new Problem(503, 'Motion runtime unavailable; run src/motion/setup.py');
    this.busy = true;
    try {
      if (!this.child) await this.start();
      return await this.exchange(JSON.stringify({ captureGzip }) + '\n');
    } finally { this.busy = false; }
  }
  start() {
    this.buffer = '';
    const child = this.child = spawn(this.python, ['-u', workerPath], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', value => {
      if (child !== this.child) return;
      this.buffer += value;
      if (this.buffer.length > 180000) return this.fail();
      let end;
      while ((end = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, end); this.buffer = this.buffer.slice(end + 1);
        try {
          const value = JSON.parse(line), pending = this.pending;
          if (!pending) return this.fail();
          this.pending = null; clearTimeout(pending.timer);
          if (value.error) pending.reject(new Problem(422, value.error));
          else pending.resolve(value.ready ? true : value.result);
        } catch { this.fail(); }
      }
    });
    child.on('error', () => this.fail(child));
    child.on('exit', () => this.fail(child));
    child.stdin.on('error', () => this.fail(child));
    return this.exchange(null, 15000);
  }
  exchange(line, timeout = 3500) {
    if (!this.child) return Promise.reject(new Problem(503, 'Motion processor unavailable; skip this batch'));
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject, timer: setTimeout(() => this.fail(), timeout) };
      if (line) this.child.stdin.write(line);
    });
  }
  fail(child = this.child) {
    if (child !== this.child) return;
    const pending = this.pending; this.pending = null;
    if (pending) { clearTimeout(pending.timer); pending.reject(new Problem(503, 'Motion processor unavailable; skip this batch')); }
    this.child = null; child?.kill();
  }
  close() { this.fail(); }
}
