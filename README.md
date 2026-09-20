# SLZB-OS Apps

App repository for [SMLIGHT SLZB-OS](https://smlight.tech) Zigbee/Thread coordinators.
The **APPS repository** button in the coordinator web UI reads the catalog
(`apps.json`) from this repository and installs apps straight onto the device.

Apps run on ESP32-S3 based coordinators (U series, MRU, Ultima): a Berry
backend script on the device plus an optional web page served into the
coordinator UI (sandboxed iframe, [BeApp SDK](https://github.com/smlight-dev/slzb-os-scripts)).

## Repository layout

```
apps/
  <folder>/            one app; the directory name must equal "folder" in meta.json
    meta.json          manifest: name, folder, ver, desc, img, permissions, minFw
    app.be             Berry backend (optional for UI-only apps), installed as /beapps/<folder>/app.be
    ui.html            the app page (optional for background-only apps)
    icon.png           card icon
    README.md          app description
dist/
  <folder>.zip         GENERATED — ready-to-install archives, do not edit
apps.json              GENERATED — the catalog the coordinator UI fetches, do not edit
scripts/build.py       validation + zip packing + catalog generation
```

`dist/` and `apps.json` are rebuilt by CI on every push to `apps/` — never
edit them by hand. To build locally: `python scripts/build.py`.

## meta.json

```json
{
    "name": "TCP Tools",
    "folder": "tcp_tools",
    "ver": "1.0.0",
    "desc": "One-line description shown on the app card",
    "img": "icon.png",
    "permissions": [],
    "minFw": "v3.3.8.dev8"
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `name` | yes | Display name |
| `folder` | yes | Install target: `/beapps/<folder>/`; must equal the directory name |
| `ver` | yes | App version, used for the "update available" check |
| `desc` | yes | Short description for the card |
| `img` | no | Icon file inside the app folder |
| `permissions` | no | `"events"` (coordinator SSE events) and/or `"api"` (raw `/api2` access — trusted apps only). Shown to the user before install |
| `minFw` | no | Minimal SLZB-OS version the app needs |

## Device constraints (checked by CI)

- zip entries are **stored, not compressed** — the on-device installer does not inflate;
- all files at the archive root (no wrapping folder), `meta.json` first;
- archive ≤ 500 KB, file names ≤ 32 characters.

## Adding an app

1. Create `apps/<folder>/` with `meta.json`, your files and an icon.
2. Run `python scripts/build.py` — it validates everything and rebuilds the catalog.
3. Open a pull request touching only `apps/<folder>/` — CI builds `dist/` and `apps.json` after merge.

## How installation works

The coordinator web UI fetches `apps.json`, renders the catalog with icons and
descriptions, and on **Install** downloads `dist/<folder>.zip` in the browser
and uploads it to the device (`/fileUpload` → app installer). The device never
talks to GitHub itself, so installs work from any network the browser can
reach GitHub from.
