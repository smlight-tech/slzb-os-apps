#!/usr/bin/env python3
"""SLZB-OS apps catalog builder.

For every app in apps/<folder>/:
  - validates meta.json and the installer constraints (see checks below),
  - packs dist/<folder>.zip: entries STORED (the on-device installer does not
    inflate), files at the archive root, meta.json first,
  - regenerates apps.json — the catalog the coordinator web UI fetches.

Zips are deterministic (fixed timestamps), so a rebuild without content
changes is byte-identical and apps.json is left untouched.

Usage: python scripts/build.py
Exits non-zero on the first validation error (CI-friendly).
"""

import json
import os
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS_DIR = os.path.join(ROOT, "apps")
DIST_DIR = os.path.join(ROOT, "dist")
CATALOG = os.path.join(ROOT, "apps.json")

MAX_ZIP_SIZE = 500 * 1024      # installer upload limit
MAX_FILENAME = 32              # ZM_ZIP_MAX_FILENAME_LEN - 1 on the device
REQUIRED_META = ("name", "folder", "ver", "desc")
ALLOWED_PERMISSIONS = {"events", "api"}
ZIP_DATE = (1980, 1, 1, 0, 0, 0)  # fixed entry timestamp -> deterministic archives


def fail(msg):
    print(f"ERROR: {msg}")
    sys.exit(1)


def build_app(folder):
    path = os.path.join(APPS_DIR, folder)
    meta_path = os.path.join(path, "meta.json")
    if not os.path.isfile(meta_path):
        fail(f"{folder}: meta.json is missing")

    try:
        with open(meta_path, encoding="utf-8") as f:
            meta = json.load(f)
    except json.JSONDecodeError as e:
        fail(f"{folder}: meta.json is not valid JSON: {e}")

    for key in REQUIRED_META:
        if not meta.get(key):
            fail(f"{folder}: meta.json is missing required field '{key}'")
    if meta["folder"] != folder:
        fail(f"{folder}: meta.json 'folder' is '{meta['folder']}', must match the directory name")

    perms = meta.get("permissions", [])
    if not isinstance(perms, list) or not set(perms) <= ALLOWED_PERMISSIONS:
        fail(f"{folder}: invalid permissions {perms!r}, allowed: {sorted(ALLOWED_PERMISSIONS)}")

    files = sorted(
        f for f in os.listdir(path)
        if os.path.isfile(os.path.join(path, f)) and not f.startswith(".")
    )
    for f in files:
        if len(f) > MAX_FILENAME:
            fail(f"{folder}: file name '{f}' is longer than {MAX_FILENAME} chars (device limit)")

    img = meta.get("img")
    if img and img not in files:
        fail(f"{folder}: meta.json 'img' points to '{img}' which does not exist")

    # meta.json goes first — the installer streams entries in order
    ordered = ["meta.json"] + [f for f in files if f != "meta.json"]

    os.makedirs(DIST_DIR, exist_ok=True)
    zip_path = os.path.join(DIST_DIR, folder + ".zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as z:
        for f in ordered:
            info = zipfile.ZipInfo(f, date_time=ZIP_DATE)
            info.external_attr = 0o644 << 16
            with open(os.path.join(path, f), "rb") as src:
                z.writestr(info, src.read(), compress_type=zipfile.ZIP_STORED)

    size = os.path.getsize(zip_path)
    if size > MAX_ZIP_SIZE:
        fail(f"{folder}: {os.path.basename(zip_path)} is {size} bytes, limit is {MAX_ZIP_SIZE}")

    entry = {
        "name": meta["name"],
        "folder": folder,
        "appVer": meta["ver"],
        "desc": meta["desc"],
        "zip": f"dist/{folder}.zip",
        "size": size,
        "permissions": perms,
    }
    if img:
        entry["icon"] = f"apps/{folder}/{img}"
    if meta.get("minFw"):
        entry["minFw"] = meta["minFw"]

    print(f"  {folder}: {size} bytes, {len(ordered)} files")
    return entry


def main():
    if not os.path.isdir(APPS_DIR):
        fail("apps/ directory not found")

    folders = sorted(d for d in os.listdir(APPS_DIR) if os.path.isdir(os.path.join(APPS_DIR, d)))
    if not folders:
        fail("no apps found in apps/")

    print(f"Building {len(folders)} app(s):")
    apps = [build_app(f) for f in folders]

    # keep apps.json untouched (incl. its 'updated' stamp) when nothing changed
    if os.path.isfile(CATALOG):
        try:
            with open(CATALOG, encoding="utf-8") as f:
                if json.load(f).get("apps") == apps:
                    print("apps.json is up to date")
                    return
        except (json.JSONDecodeError, OSError):
            pass

    catalog = {
        "ver": 1,
        "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "apps": apps,
    }
    with open(CATALOG, "w", encoding="utf-8", newline="\n") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("apps.json regenerated")


if __name__ == "__main__":
    main()
