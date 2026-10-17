// Local hardware-test fixture. Its private stdin control can reject every
// device connection without stopping the persisted server deadline timer.
import { createInterface } from 'node:readline';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/server.js';

mkdirSync(fileURLToPath(new URL('../data/', import.meta.url)), { recursive: true });
const { server } = createApp({ dbPath: fileURLToPath(new URL('../data/device-test.sqlite', import.meta.url)) });
const sockets = new Set();
let offline = false;
server.on('connection', socket => {
  sockets.add(socket);
  socket.on('close', () => sockets.delete(socket));
  if (offline) socket.destroy();
});
const stop = () => {
  for (const socket of sockets) socket.destroy();
  server.close(() => process.exit(0));
};
const control = createInterface({ input: process.stdin });
control.on('line', command => {
  if (command === 'stop') return stop();
  if (command !== 'offline' && command !== 'online') return;
  offline = command === 'offline';
  if (offline) for (const socket of sockets) socket.destroy();
  process.stdout.write(command + '\n');
});
control.on('close', stop);
server.listen(4174, '127.0.0.1', () => process.stdout.write('ready\n'));
