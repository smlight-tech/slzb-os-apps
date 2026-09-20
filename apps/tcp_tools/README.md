# TCP Tools
SLZB-OS app demonstrating the `TCP_SERVER` / `TCP_CLIENT` Berry classes with a
web UI (BeApp SDK, sandboxed iframe):

- **Server** — listens on a user-chosen port and shows every connection and
  received line on the page; messages typed on the page are sent to **all
  connected clients**. Test it from any computer: `nc <device-ip> <port>`.
  The server keeps running while the app page is closed — events land in the
  app Log (`BEAPP.log`).
- **Client** — raw TCP connection to any host: connect, send lines, watch the
  replies. Point it at `127.0.0.1` and the server's port to loop the two
  halves together.

All TCP work happens in the Berry backend (`app.be`); the page only renders
state and sends JSON commands over the app message channel
(`BeApp.sendMessage` ⇄ `BEAPP.receive` / `BEAPP.send`). The TCP instances live
in PSRAM and are destroyed automatically when the script stops.

Requires an ESP32-S3 device (U series, MRU, Ultima) — the TCP classes are not
available on other models.

## Files
| File | Purpose |
|------|---------|
| `meta.json` | App manifest (`folder: tcp_tools`, no extra permissions needed) |
| `ui.html` | The app page, loaded into the sandboxed iframe |
| `app.be` | Berry backend: the echo server, the client and the command loop |
| `icon.png` | Card icon for the Apps list |

## Install
Install via **Apps → Local APP installer** in the coordinator web UI.
The files are extracted to `/beapps/tcp_tools/` on the device.
