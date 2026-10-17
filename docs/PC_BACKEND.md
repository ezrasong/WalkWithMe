# Backend and remote access

The Node.js backend stores sessions in `data/kaze.sqlite` on the PC.

## Cloudflare HTTPS tunnel

On Windows, from the repository root:

```powershell
npm.cmd install
powershell -ExecutionPolicy Bypass -File scripts/start-online.ps1
```

The launcher downloads Cloudflare's client, verifies its checksum, starts the backend on `127.0.0.1:4173`, and prints a public HTTPS address. Bake that address into developer phone builds with `--dart-define=KAZE_BASE_URL=https://your-service.example`. The normal app has no backend-address field. Share the guardian link from Settings with the second phone.

Keep the PC awake and the launcher running. Ctrl+C stops its backend and tunnel. The launcher refuses to replace another server already using port 4173.

The current address is saved in ignored `artifacts/online-url.txt`; logs are in `artifacts/online-*.log`. The Node watch supervisor reloads backend source changes while the tunnel stays running, preserving its address and SQLite database. A backend reload briefly interrupts requests and recovers persisted deadlines; it is not continuous availability. Restarting the entire launcher changes a Quick Tunnel address and requires updated developer builds. Use a stable named hostname before distributing the app.

If the PC cannot resolve a new tunnel hostname, the launcher can verify it using Cloudflare DNS over HTTPS without changing system DNS. Try cellular data if a phone's Wi-Fi network cannot resolve the address.

For a stable address, create a named tunnel and hostname in your Cloudflare account, pointing to `http://127.0.0.1:4173`. Keep connector credentials outside the repository.

On macOS/Linux, install [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/), run `npm start`, then use a second terminal:

```sh
cloudflared tunnel --url http://127.0.0.1:4173
```

## Local development

```powershell
npm.cmd start
```

The server listens at `http://127.0.0.1:4173`. For a USB-connected Android phone:

```powershell
adb -s PHONE_SERIAL reverse tcp:4173 tcp:4173
```

Enter that localhost address on the connected phone. A second phone needs the public HTTPS address.

[Cloudflare Quick Tunnel documentation](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).
