// Build-time configuration only. The normal app never asks for a server URL.
const kazeBackendUrl = String.fromEnvironment(
  'KAZE_BASE_URL',
  defaultValue:
      'https://figured-transmission-musical-thermal.trycloudflare.com',
);

// Optional private build preset; never put home coordinates in source control.
const kazeDemoRoute = String.fromEnvironment('KAZE_DEMO_ROUTE');
