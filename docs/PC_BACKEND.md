# Backend and remote access

The Node.js backend stores sessions in `data/kaze.sqlite` on the PC.

## Cloudflare HTTPS tunnel

From the repository root:

```powershell
npm.cmd install
npm.cmd start
```

Install [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) and open a second terminal:

```sh
cloudflared tunnel --url http://127.0.0.1:4173
```

The tunnel prints a public HTTPS address. Bake that address into developer phone builds with `--dart-define=KAZE_BASE_URL=https://your-service.example`. The normal app has no backend-address field. Share the guardian link from Settings with the second phone. Keep the PC awake and both processes running in independent terminals. Stopping either process interrupts access. Restarting a Quick Tunnel changes its address and requires updated developer builds; use a stable named hostname before distributing the app.

For automatic source reload during development, use `npm run dev` instead of `npm start`. A reload briefly interrupts requests and recovers persisted deadlines; it is not continuous availability. Keep local tunnel launchers, connection addresses, logs and evidence under ignored `scripts/` and `artifacts/` directories.

For a stable address, create a named tunnel and hostname in your Cloudflare account, pointing to `http://127.0.0.1:4173`. Keep connector credentials outside the repository.

## Local development

```powershell
npm.cmd start
```

The server listens at `http://127.0.0.1:4173`. For a USB-connected Android phone:

```powershell
adb -s PHONE_SERIAL reverse tcp:4173 tcp:4173
```

Bake that localhost address into the connected phone's development build with `--dart-define=KAZE_BASE_URL=http://127.0.0.1:4173`. A second phone needs the public HTTPS address.

[Cloudflare Quick Tunnel documentation](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).
