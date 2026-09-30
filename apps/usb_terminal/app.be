# USB Serial Terminal — Berry backend.
#
# Lists the USB serial devices on the USB host port and runs an interactive serial terminal
# for one of them (USBH module / USBDEV class): interface and baud rate choice, DTR / RTS
# control. The page does all the text / HEX presentation - every payload travels as HEX, so
# any bytes the device sends survive the JSON transport.
#
# The port is held only while the app page is open: closing the page closes the port and
# gives it back to the USB passthrough.
#
# UI -> backend (BeApp.sendMessage, JSON string):
#   {"cmd":"status"}   {"cmd":"list"}
#   {"cmd":"open","id":3,"itf":0,"baud":115200}   {"cmd":"close"}
#   {"cmd":"baud","baud":9600}   {"cmd":"lines","dtr":true,"rts":false}
#   {"cmd":"tx","hex":"48656C6C6F0D0A"}
#
# backend -> UI (BEAPP.send -> BeApp.onMessage, JSON string):
#   {"type":"status",...}   {"type":"devices","list":[<USBH.info() maps>]}
#   {"type":"rx","hex":"..."}   {"type":"log","level":"info"|"error","text":...}

import BEAPP
import SLZB
import USBH
import json

var RX_MSG_MAX = 2048        # bytes of received data per page message (4 KB of HEX)
var RX_PENDING_MAX = 16384   # received bytes kept while the page queue is full, older ones are dropped
var RX_FLUSH_MS = 60         # collect received data this long before sending it to the page
var LIST_POLL_MS = 2000      # device list refresh while the page is open

var ch = BEAPP.claim()
if ch == 0
    SLZB.log("no free app channel, exiting")
    return
end

BEAPP.setLogSize(4096)
BEAPP.log("USB Serial Terminal backend started")

var uiOpen = false
var dev = nil          # USBDEV while a port is open
var devId = 0
var devItf = 0
var devBaud = 115200
var devName = ""
var dtr = false
var rts = false

var rxBuf = bytes()
var lastFlush = 0
var lastList = 0
var lastListJson = ""

def uiSend(m)
    if uiOpen return BEAPP.send(ch, json.dump(m)) end
    return 0
end

def uiLog(level, text)
    BEAPP.log(text)
    uiSend({"type": "log", "level": level, "text": text})
end

def uiStatus()
    var c = USBH.channels()
    uiSend({
        "type": "status",
        "running": USBH.isRunning(),
        "freePorts": USBH.freePorts(),
        "chUsed": c["used"], "chTotal": c["total"],
        "open": dev != nil,
        "id": devId, "itf": devItf, "baud": devBaud, "name": devName,
        "dtr": dtr, "rts": rts
    })
end

def deviceList()
    var out = []
    for id: USBH.list()
        var info = USBH.info(id)
        if info != nil out.push(info) end
    end
    return out
end

# sends the device list when it changed (or always with force)
def uiDevices(force)
    var devs = deviceList()
    var js = json.dump(devs)
    if force || js != lastListJson
        lastListJson = js
        uiSend({"type": "devices", "list": devs})
        return true
    end
    return false
end

# pushes the collected received data to the page in chunks of RX_MSG_MAX
def flushRx()
    while rxBuf.size() > 0
        var n = rxBuf.size() < RX_MSG_MAX ? rxBuf.size() : RX_MSG_MAX
        if uiSend({"type": "rx", "hex": rxBuf[0 .. n - 1].tohex()}) == 0
            break   # the page queue is full - retry on the next tick
        end
        rxBuf = n < rxBuf.size() ? rxBuf[n .. rxBuf.size() - 1] : bytes()
    end

    if rxBuf.size() > RX_PENDING_MAX
        var drop = rxBuf.size() - RX_PENDING_MAX
        rxBuf = rxBuf[drop .. rxBuf.size() - 1]
        uiLog("error", "page too slow, dropped " .. str(drop) .. " received bytes")
    end

    lastFlush = SLZB.millis()
end

def portClose(reason)
    if dev != nil
        dev.close()
        dev = nil
        uiLog("info", "port closed" .. (reason ? " (" .. reason .. ")" : ""))
    end
    rxBuf = bytes()
    dtr = false
    rts = false
end

# why USBH.open() returned nil - best guess from the public state
def openFailReason(id, itf)
    if !USBH.isRunning()
        return "USB host is not running: enable USB passthrough mode on the USB Passthrough page and reboot"
    end
    if USBH.info(id) == nil return "the device is gone" end

    var use = USBH.getUse(id, itf)
    if use == USBH.USE_SCRIPT return "the device is open in another script" end
    if use != USBH.USE_BRIDGE && USBH.freePorts() == 0
        return "no free passthrough port: both are in use or configured on the USB Passthrough page"
    end

    var c = USBH.channels()
    return "interface " .. str(itf) .. " is not compatible, or not enough USB host channels (" ..
           str(c["used"]) .. "/" .. str(c["total"]) .. " used)"
end

def portOpen(id, itf, baud)
    portClose(nil)

    var info = USBH.info(id)
    var name = info != nil ? (info["product"] != "" ? info["product"] : info["driver"]) : "#" .. str(id)
    if info != nil && info["use"] == USBH.USE_BRIDGE
        uiLog("info", "taking the port over from the USB passthrough, its TCP client is disconnected")
    end

    var d = USBH.open(id, itf, baud)
    if d == nil
        uiLog("error", "cannot open " .. name .. ": " .. openFailReason(id, itf))
        return
    end

    dev = d
    devId = id
    devItf = itf
    devBaud = baud
    devName = name
    lastFlush = SLZB.millis()
    uiLog("info", "opened " .. name .. ", interface " .. str(itf) .. ", " .. str(baud) .. " baud")
end

def handleCmd(cmd)
    if cmd == nil return end
    var c = cmd["cmd"]

    if c == "open"
        portOpen(int(cmd["id"]), int(cmd["itf"]), int(cmd["baud"]))

    elif c == "close"
        portClose(nil)

    elif c == "baud"
        var b = int(cmd["baud"])
        if dev != nil
            if dev.setBaud(b)
                devBaud = b
                uiLog("info", "baud rate " .. str(b))
            else
                uiLog("error", "the device does not accept " .. str(b) .. " baud")
            end
        else
            devBaud = b
        end

    elif c == "lines"
        var d2 = cmd["dtr"] == true
        var r2 = cmd["rts"] == true
        if dev != nil
            if dev.setLines(d2, r2)
                dtr = d2
                rts = r2
            else
                uiLog("error", "the device does not support DTR / RTS control")
            end
        end

    elif c == "tx"
        if dev == nil
            uiLog("error", "the port is not open")
        else
            try
                var data = bytes(str(cmd["hex"]))
                if data.size() > 0 && !dev.write(data)
                    uiLog("error", "send failed: the device is gone or does not accept data")
                end
            except .. as e, m
                uiLog("error", "invalid HEX data")
            end
        end

    elif c == "list"
        uiDevices(true)
    end

    uiStatus()
end

while true
    # page events; the timeout doubles as the port poll tick
    var payload = BEAPP.receive(ch, dev != nil ? 20 : 200)

    if payload != nil
        var m = json.load(payload)

        if m == nil
            # nothing

        elif m["event"] == "open"
            uiOpen = true
            uiDevices(true)
            uiStatus()

        elif m["event"] == "close"
            portClose("app page closed")
            uiOpen = false

        elif m["event"] == "msg"
            handleCmd(json.load(str(m["data"])))
        end
    end

    # --- port: collect the received data, detect an unplugged device ---
    if dev != nil
        var data = dev.read()
        if data == false
            dev = nil   # the instance is dead after an unplug, nothing to close
            rxBuf = bytes()
            uiLog("error", "the device was disconnected")
            uiDevices(true)
            uiStatus()
        elif data.size() > 0
            rxBuf += data
        end

        if rxBuf.size() > 0 && (rxBuf.size() >= RX_MSG_MAX || SLZB.millis() - lastFlush >= RX_FLUSH_MS)
            flushRx()
        end
    end

    # --- device list: plug / unplug while the page is open ---
    if uiOpen && SLZB.millis() - lastList >= LIST_POLL_MS
        lastList = SLZB.millis()
        if uiDevices(false) uiStatus() end
    end
end
