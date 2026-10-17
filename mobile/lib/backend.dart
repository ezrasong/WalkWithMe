// Build-time configuration only. The normal app never asks for a server URL.
const kazeBackendUrl = String.fromEnvironment(
  'KAZE_BASE_URL',
  defaultValue: 'https://figured-transmission-musical-thermal.trycloudflare.com',
);
