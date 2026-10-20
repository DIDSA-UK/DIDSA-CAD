# Connect a VR headset (pairing QR code)

**Status:** built in the flat app (20 Oct 2026, branch `claude/vr-landing-feature-scope-kspao7`). The headset side, which scans the
code, is not built yet: DIDSA-VR `docs/landing-scope.md`, "Adding a server" (steps L5 and L6). This page is the contract between the two.

## Where it is

- The connection screen: **Connect a VR headset**, under Server Management.
- File > **Connect a VR headset...** while a Part is open.

Both open `client/lib/vr_pairing/headset_pairing_screen.dart`, which pairs the server the app is **connected to** (the saved
`ApiConfig` URL and key), not whatever is typed in the connection screen's fields.

## Checks before the code is shown

Run in order by `HeadsetPairing.runChecks` (`client/lib/vr_pairing/headset_pairing.dart`); the first failure stops the rest and no
code is shown. A warning still shows the code, with the reason.

| Check | Fails when | Warns when |
|---|---|---|
| Server set | No saved URL or key | |
| Address the headset can reach | Not http(s); loopback (`localhost`, `127.x`, `::1`: the on-phone Termux server); `10.0.2.2` (emulator); link-local; plain `http://` anywhere, for now | `.local` name; Tailscale (`100.64/10`, `*.ts.net`); `https://` to a private address (certificate must be trusted) |
| Server running | `GET /health` with the key fails, times out or is refused (401 / 403 named) | |
| Server works with the headset | `/openapi.json` lacks a required path: `/health`, `/document/import/native`, `/document/export/native`, `/document/parts/{part_id}/assembly-mesh.glb` | `/openapi.json` unreadable; or no `mates`, `measure`, `appearance-overrides` or `scenes` route (that tool will not work in VR) |

Plain `http://` on the local network is refused because Android on the headset blocks cleartext HTTP. When DIDSA-VR's custom
Android build allows LAN addresses (its landing scope, step L0), set `HeadsetPairing.headsetAllowsLanHttp` to true.

Nothing here can test the route from the headset itself: a server that passes may still be unreachable from it (another Wi-Fi, a
firewall).

## The code's contents

```
didsa-vr:1?n=<name>&u=<base url>&k=<api key>
```

- `1` is the payload version. The headset refuses a version it does not know.
- Each value is percent-encoded (`Uri.encodeQueryComponent`); `u` has no trailing slash. `n` is the server's host name.
- Reserved for later, optional: `s` (document session), `r` / `rk` (browser relay URL and key).

## Safety

The code carries the backend's single `CAD_API_KEY`: anyone who photographs it can use the server. So it appears only on this
screen, hides itself after 60 s (Show the code brings it back), and the screen says so. A short-lived pairing token exchanged for a
per-device key would need backend work (per-device keys do not exist yet).

## Tests

`client/test/headset_pairing_test.dart` (16): every address rule, the check order (a local address makes no request), a down server, a
wrong key, a server too old, a server without Scenes (warning), the payload round trip, and the screen (code shown, hides itself,
shown again, hidden; refused for the on-phone server). Not seen on a device; not scanned by a headset.
