# Zigbee Sniffer
SLZB-OS app: an IEEE 802.15.4 / Zigbee sniffer on an EFR32 radio of the
coordinator. The packets are shown in the app page and / or streamed live to
Wireshark. It works like the `sniff` command of
[ember-zli](https://github.com/Nerivec/ember-zli), but runs on the coordinator
itself — no USB stick and no PC-side tool are needed.

- **Radio and channel** — any EFR32 radio (EFR32MG21 / MG24 / MG26) running
  the Zigbee coordinator (EmberZNet NCP) firmware, channel 11–26. The channel
  can be changed while sniffing.
- **Packet log** — every frame with time, LQI, RSSI, length and the decoded
  IEEE 802.15.4 MAC and Zigbee NWK headers (frame type, PAN, MAC and NWK
  addresses, beacons with permit join / extended PAN ID, MAC and NWK
  commands). APS / ZCL are decoded for the frames without NWK security. Click a
  row for all fields and a HEX dump. Filters by frame type and by text
  (address, PAN, info, hex), pause, autoscroll.
- **Wireshark** — every frame is sent as a ZEP v2 datagram (UDP, port 17754 by
  default) to the PC running Wireshark; Wireshark decodes ZEP by itself and,
  with the network key added in its preferences, decrypts everything.
- **Headless** — with the Wireshark output, *Start sniffing when the app
  starts* and **Start on boot** on the app card the device keeps streaming
  without the app page open.

Traffic is not saved to files: the storage of the coordinator is small. Save the
capture in Wireshark instead.

## Requirements
- An ESP32-S3 based coordinator (U series, MRU, Ultima) with SLZB-OS
  **v3.4.2.dev1** or newer (`ZB.isEFR()` / `ZB.getFirmwareType()`, fixed
  `ZB.readBytes()`).
- An EFR32 radio with the **Zigbee coordinator (EmberZNet NCP)** firmware
  built with the manufacturing library (mfglib) — the standard coordinator
  firmwares are.

## Important
While sniffing, the radio is taken from the Zigbee socket: **its own Zigbee
network stops working** and Zigbee2MQTT / ZHA connected to that radio lose the
connection. On *Stop* the radio is restarted and they reconnect. To sniff the
network that the coordinator runs, use another radio of a multi-radio device
(MR series, Ultima), or run the sniffer on a second coordinator.

The radio only receives (mfglib receive mode), it never transmits.

## Wireshark
1. Enable **Send to Wireshark** and enter the IP address of the PC with
   Wireshark (port `17754`).
2. Capture on the network interface of that PC, display filter `zep`. No
   program has to listen on the port — Wireshark sees the datagrams arriving.
3. To decrypt the network layer add the network key in *Edit → Preferences →
   Protocols → ZigBee → Pre-configured Keys* (Zigbee2MQTT: `network_key` in
   `configuration.yaml`). Add `5A:69:67:42:65:65:41:6C:6C:69:61:6E:63:65:30:39`
   (ZigBeeAlliance09) as well to follow devices joining the network.

The 2-byte FCS of each frame is replaced by RSSI and LQI (TI CC24xx format, as
ember-zli does); Wireshark shows them in the ZEP / IEEE 802.15.4 details.

## How it works
The Berry backend (`app.be`) implements the host side of the Silicon Labs
serial protocol on top of the `ZB` module: `ZB.suspend()` pauses the Zigbee
socket of the radio, `ZB.writeBytes()` / `ZB.readBytes()` carry the ASH frames
(CRC-CCITT, byte stuffing, data randomization, frame numbers / ACK / NAK,
retransmission). Over it the EZSP commands `version`, `getEui64`,
`mfglibStart(rxCallback)` and `mfglibSetChannel` switch the radio into receive
mode; each captured frame then arrives as the `mfglibRxHandler` callback.
*Stop* sends `mfglibEnd`, resets the radio with `ZB.reboot()` and resumes the
socket (the firmware also resumes it when the app script is stopped).

Packets go to the page in batches every 200 ms (`BEAPP.send`), to Wireshark one
UDP datagram per frame (`UDP_CLIENT`). Settings are kept in
`/beapps/zb_sniffer/config.json`.

## Files
| File | Purpose |
|------|---------|
| `meta.json` | App manifest (`folder: zb_sniffer`, no extra permissions needed) |
| `ui.html` | The app page: settings, statistics, packet log with the header decoder |
| `app.be` | Berry backend: ASH / EZSP host, mfglib control, ZEP output |
| `icon.png` | Card icon for the Apps list |

## Install
Install from **Apps → APPS repository** in the coordinator web UI, or with
**Apps → Local APP installer** and the archive from `dist/zb_sniffer.zip`.
The files are extracted to `/beapps/zb_sniffer/` on the device.
