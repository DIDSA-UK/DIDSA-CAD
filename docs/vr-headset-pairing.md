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
| This phone's server on Wi-Fi (only for the on-phone server, `127.0.0.1`) | Server Management's "Let VR headsets on this Wi-Fi connect" is off; or the phone has no Wi-Fi address | Always: the address the code will carry, and keep the phone awake |
| Address the headset can reach | Not http(s); loopback given directly; `10.0.2.2` (emulator); link-local; plain `http://` on the internet | `http://` on the local network (key unencrypted); `.local` name; Tailscale (`100.64/10`, `*.ts.net`); `https://` to a private address (certificate must be trusted) |
| Server running | `GET /health` with the key fails, times out or is refused (401 / 403 named). For the phone's server it is asked at the Wi-Fi address, so a server still listening only inside the phone fails here, with "Restart it" | |
| Server works with the headset | `/openapi.json` lacks a required path: `/health`, `/document/import/native`, `/document/export/native`, `/document/parts/{part_id}/assembly-mesh.glb` | `/openapi.json` unreadable; or no `mates`, `measure`, `appearance-overrides` or `scenes` route (that tool will not work in VR) |

Plain `http://` on the local network is allowed (`HeadsetPairing.headsetAllowsLanHttp`). Android's cleartext-HTTP rule is enforced by
its Java networking stack, and the headset app's requests use Godot's own sockets; not yet tried on a headset. If a headset test shows
it blocked, set the flag false until DIDSA-VR adds a network security config (its landing scope, "Plain http on the Quest").

## The phone's own server

Server Management's **Let VR headsets on this Wi-Fi connect** (`ApiConfig.localServerOnWifi`, off by default) starts uvicorn with
`--host 0.0.0.0` instead of `127.0.0.1` on the next Start / Restart / Pull & start. Pairing then replaces `127.0.0.1` with the phone's
Wi-Fi address (`HeadsetPairing.phoneWifiAddresses`: Wi-Fi and hotspot interfaces first, mobile-data interfaces left out) and runs the
checks against that address. The code's name is "Phone server (<address>)". While the switch is on, anything on the Wi-Fi can reach
the server; it still needs the key, which travels unencrypted over plain http.

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

`client/test/headset_pairing_test.dart` (20): every address rule, the check order (the phone's server with the switch off makes no
request), a down server, a wrong key, a server too old, a server without Scenes (warning), the phone's server (refused with the switch
off or no Wi-Fi; paired at its Wi-Fi address and checked only there; "Restart" when it does not answer there), the payload round trip,
and the screen. `test/server_management/termux_commands_test.dart`: the switch's `0.0.0.0` on Start, Restart and Pull & start. Not
seen on a device; `NetworkInterface.list` on Android not tried; not scanned by a headset.
