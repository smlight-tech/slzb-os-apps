# ZHB Timers

SLZB-OS app: timers that send commands to Zigbee Hub devices. Requires the
coordinator to run in **Zigbee Hub (standalone) mode** — otherwise the page
shows a warning and nothing fires.

- **Timer types**: *interval* (every N seconds), *timeout* (once, N seconds
  after start — stops itself), *schedule* (at HH:MM on selected weekdays, or
  every day; needs NTP time).
- **Device & action**: pick any paired Zigbee device (`ZHB.getDevices()`) and
  what to do — turn on / turn off / toggle (`sendOnOff`) or set brightness
  (`sendBri`), with a configurable endpoint.
- **Control**: start/stop, edit and delete each timer from the page.
- **Persistence**: everything (incl. the running flag) is stored in the app
  folder — `/beapps/zhb_timers/timers.json`. Enable *Start on boot* and the
  running timers survive reboots.

The timers run in the Berry backend (`app.be`, ~0.5 s tick), so they keep
firing while the page is closed; events land in the app Log (`BEAPP.log`).
If the Zigbee Hub comes up after the app (boot order), the backend re-probes
every 10 seconds and arms the timers automatically.

Requires an ESP32-S3 device (U series, MRU, Ultima) and SLZB-OS ≥ v3.3.8.dev8
(`ZHB.getDevices()`).

## Files

| File | Purpose |
|------|---------|
| `meta.json` | App manifest (`folder: zhb_timers`, no extra permissions needed) |
| `ui.html` | The app page: timer editor + list |
| `app.be` | Berry backend: timer engine, ZHB commands, config persistence |
| `icon.png` | Card icon |

## Packaging & install

Zip the files **at the archive root** (no wrapping folder), **without
compression** (`-0`, stored entries — the on-device installer does not
inflate), max 500 KB:

Install via **Apps → Local APP installer**, or drop the folder into the
`apps/` directory of the [slzb-os-apps](https://github.com/smlight-tech/slzb-os-apps)
repository to publish it in the APPS repository catalog.
