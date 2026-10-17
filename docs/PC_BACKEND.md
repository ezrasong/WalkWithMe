# Connecting the apps to a backend hosted on this PC

The Node server and SQLite database stay on the PC. The phone/watch/guardian need a network route to that server and the correct private session credential. `baseUrl` is already part of the Android pairing configuration.

## Recommended hackathon access: HTTPS tunnel

Keep the backend listening on `127.0.0.1:4173`:

```powershell
npm.cmd start
```

If it is already running, leave that process running; do not start a second server on the same port.

Install Cloudflare's `cloudflared` using its official Windows download/install instructions, then run this in another terminal:

```powershell
cloudflared tunnel --url http://127.0.0.1:4173
```

It prints a temporary HTTPS address. That address forwards requests through Cloudflare to this PC; Cloudflare does not run the Node backend or SQLite database. The application is reachable over the internet, but private session data still requires the application's owner/guardian/watch credential.

1. In the Flutter wearer app, enter the generated HTTPS origin as the PC server URL.
2. Create and consent to the timed safety session directly in the Flutter app.
3. The app retains its scoped owner access. Copy its private guardian link in Settings into KAZE on the second iPhone/Android phone. Do not use a localhost link on that second phone.
4. With the Watch4 already paired to the Vivo in Galaxy Wearable, open KAZE on the watch. It automatically requests the active phone session and receives the same backend URL with watch-scoped access. Tap Start on the watch to consent; no phone Settings configuration transfer is needed.
5. Share only the guardian link with consenting test contacts. Never share the owner's pairing JSON as a guardian invitation.
6. Verify the health endpoint at `<HTTPS_ADDRESS>/api/health`, then test the actual authenticated device flow on mobile data.

Quick Tunnel addresses change when restarted and have no uptime guarantee. A changed address requires updating the app configuration. Use a named tunnel with a stable hostname, or an existing correctly configured HTTPS reverse proxy, for a stable installation.

Do not add Quick Tunnel browser email-login flags to the native app endpoint: those require an interactive browser login. Native devices use KAZE's scoped bearer tokens. The Flutter guardian app and browser dashboard use HTTP polling; neither depends on SSE, which Quick Tunnels do not support.

The PC must stay awake, the backend and tunnel processes must keep running, and internet access must remain available. The server cannot deliver an alert while it is stopped. On restart it can recover a persisted overdue deadline; that is delayed recovery, not continuous availability.

Official instructions:

- https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/
- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/

## Local Wi-Fi / hotspot alternative

This PC's active Ethernet address was `192.168.2.236` when checked. Addresses can change; use `ipconfig` to confirm the current IPv4 address.

For an isolated local debug test, start the server with a LAN listener instead of its default loopback listener:

```powershell
$env:HOST = '0.0.0.0'
npm.cmd start
```

Connect the phone/watch to the same reachable local network and open `http://192.168.2.236:4173` (replace the address if it changed). Create the device session from that LAN address so the generated pairing configuration points to the PC rather than localhost. Only debug APKs permit private/local cleartext HTTP; release builds require HTTPS.

If Windows Firewall blocks this connection, allow only the necessary Node/port access on the intended private network. Some venue networks block device-to-device traffic even when the Wi-Fi name matches; use a shared hotspot or the HTTPS tunnel in that case. Router port forwarding is not required for Cloudflare Tunnel.

## USB debug alternative

For a connected phone:

```powershell
adb -s PHONE_SERIAL reverse tcp:4173 tcp:4173
```

Then `http://127.0.0.1:4173` on that phone is forwarded to the PC. This is a development connection, not a solution for a remote guardian or an untethered watch.

## Existing HTTPS reverse proxy

If using an existing Nginx endpoint, proxy it to `http://127.0.0.1:4173` and preserve the public `Host` header (`proxy_set_header Host $host`). Open the public HTTPS dashboard before creating a session so the generated app configuration uses the public origin. Supply real TLS configuration through the existing deployment; this guide does not invent a domain, certificate or router configuration.

Do not enable wildcard CORS or disable app authorization to fix a connection problem. Phone HTTP clients do not need browser CORS permissions, and the guardian dashboard can use the same HTTPS origin as the API.
