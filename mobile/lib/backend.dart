// Build-time configuration only. The normal app never asks for a server URL.
const kazeBackendUrl = String.fromEnvironment(
  'KAZE_BASE_URL',
  defaultValue: 'https://rank-suddenly-antibody-products.trycloudflare.com',
);
