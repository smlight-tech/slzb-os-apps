# USB Serial Terminal
SLZB-OS app: an interactive serial terminal for USB serial adapters and dongles
(CP210x, FTDI, CH34x, CDC-ACM) plugged into the USB port of the coordinator,
directly or through a USB hub. Built on the `USBH` Berry module.

- **Device list** — every connected USB serial device with its name, VID:PID,
  driver, serial number, the interfaces that can be opened and who uses it right
  now (free / USB passthrough / another script / this terminal). Plugging and
  unplugging is picked up automatically.
- **Terminal** — open a device with the chosen **interface** and **baud rate**
  (the baud rate can also be changed while the port is open).
- **Text or HEX** — the received data is shown as text (CR, LF, CR+LF end a
  line, other control characters are shown as symbols) or as a HEX dump with an
  ASCII column. Switching the view re-renders everything received so far.
  Optional timestamps, echo of the sent data, RX / TX byte counters.
- **Send** — text with a selectable line ending (none, LF, CR, CR+LF) or raw
  HEX bytes (`FE 00 21 01 20`, `fe0021`, `0xFE,0x00` are all accepted); ↑ / ↓
  recall the previous inputs.
- **DTR / RTS** — switch the modem control lines, e.g. to reset a dongle or to
  enter its bootloader. Both lines are inactive after the port is opened.

## Requirements
- An ESP32-S3 based coordinator (U series, MRU, Ultima) with SLZB-OS
  **v3.4.2.dev1** or newer.
- **USB to Ethernet passthrough mode** enabled on the **USB Passthrough** page
  (and a reboot) — this switches the USB port to host mode. No device has to be
  opened on that page. It cannot be used together with an active 4G/LTE add-on.

## How it works
The Berry backend (`app.be`) owns the port; the page only renders and sends JSON
commands over the app message channel (`BeApp.sendMessage` ⇄ `BEAPP.receive` /
`BEAPP.send`). All data travels as HEX in both directions, so any bytes the
device sends survive the transport; received data is collected for ~60 ms and
sent to the page in chunks of up to 2 KB.

- Opening a device that the USB passthrough is serving takes its port over and
  disconnects the passthrough TCP client.
- The port is held only while the app page is open: closing (or reloading) the
  page closes the port and gives it back to the USB passthrough.
- The device list shows why a device cannot be opened: both passthrough ports
  taken or configured on the USB Passthrough page, the device open in another
  script, or not enough USB host channels (the ESP32-S3 has 8: each device takes
  1, an open port 2–3 more, a USB hub 2).

## Files
| File | Purpose |
|------|---------|
| `meta.json` | App manifest (`folder: usb_terminal`, no extra permissions needed) |
| `ui.html` | The app page, loaded into the sandboxed iframe |
| `app.be` | Berry backend: device list, port handling, RX batching |
| `icon.png` | Card icon for the Apps list |

## Install
Install from **Apps → APPS repository** in the coordinator web UI, or with
**Apps → Local APP installer** and the archive from `dist/usb_terminal.zip`.
The files are extracted to `/beapps/usb_terminal/` on the device.
