# Zigbee Sniffer — Berry backend.
#
# Turns an EFR32 radio with the Zigbee coordinator firmware (EmberZNet NCP, EZSP over ASH) into a
# 802.15.4 sniffer, the same way ember-zli "sniff" does (github.com/Nerivec/ember-zli):
# ASH reset -> EZSP version -> mfglibStart(rx callbacks) -> mfglibSetChannel; every received frame
# then arrives as the mfglibRxHandler callback. The radio is taken from the Zigbee socket with
# ZB.suspend() and driven directly over its UART (ZB.writeBytes / ZB.readBytes).
#
# Captured frames go to the app page (log) and/or to Wireshark as ZEP v2 over UDP (port 17754).
# Stopping ends mfglib and hardware-resets the radio, so Zigbee2MQTT / ZHA can connect again.
#
# UI -> backend (BeApp.sendMessage, JSON string):
#   {"cmd":"status"}
#   {"cmd":"start","chip":1,"channel":15,"ui":true,"zep":true,"host":"192.168.1.10","port":17754,"auto":false}
#   {"cmd":"stop"}   {"cmd":"channel","channel":20}
#   {"cmd":"set","ui":true,"zep":false,"host":"...","port":17754,"auto":false}
#
# backend -> UI (BEAPP.send -> BeApp.onMessage, JSON string):
#   {"type":"status",...}   {"type":"log","level":"info"|"error","text":...}
#   {"type":"pkts","now":<millis>,"list":[[<millis>,<lqi>,<rssi>,"<hex, no FCS>"],...]}

import BEAPP
import SLZB
import ZB
import TIME
import NETWORK
import FS
import json

var CFG_FILE = "/beapps/zb_sniffer/config.json"
var ZEP_PORT = 17754
var EZSP_TIMEOUT = 1500      # ms per try, 3 tries
var UI_FLUSH_MS = 200        # collect packets this long before sending them to the page
var UI_PENDING_MAX = 200     # packets kept while the page queue is full, newer ones are dropped
var STATUS_MS = 1000

# EZSP frame ids
var FID_VERSION = 0x0000
var FID_INVALID_COMMAND = 0x0058
var FID_GET_EUI64 = 0x0026
var FID_MFGLIB_START = 0x0083
var FID_MFGLIB_END = 0x0084
var FID_MFGLIB_SET_CHANNEL = 0x008A
var FID_MFGLIB_RX_HANDLER = 0x008E

var ch = BEAPP.claim()
if ch == 0
    SLZB.log("no free app channel, exiting")
    return
end

BEAPP.setLogSize(4096)
BEAPP.log("Zigbee Sniffer backend started")

# ---------------------------------------------------------------- tables
# CRC-CCITT (poly 0x1021, init 0xFFFF) of ASH frames; over a frame with its CRC appended it is 0
var CRC_T = []
for i: 0 .. 255
    var c = i << 8
    for k: 0 .. 7
        c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) : (c << 1)
    end
    CRC_T.push(c & 0xFFFF)
end

# pseudo-random sequence XORed over the data field of ASH DATA frames (LFSR, seed 0x42, poly 0xB8)
var RAND = bytes()
var lfsr = 0x42
for i: 0 .. 255
    RAND.add(lfsr, 1)
    lfsr = (lfsr & 1) != 0 ? ((lfsr >> 1) ^ 0xB8) : (lfsr >> 1)
end

# ---------------------------------------------------------------- settings (config.json)
var chip = 1
var channel = 11
var toUi = true
var toZep = false
var zepHost = ""
var zepPort = ZEP_PORT
var autoStart = false

# ---------------------------------------------------------------- state
var uiOpen = false
var sniffing = false
var state = "idle"           # idle | starting | sniffing | stopping
var lastErr = ""

# ASH
var frmTx = 0                # number of our next DATA frame
var frmRx = 0                # number of the next DATA frame expected from the radio
var rxFrame = bytes()
var rxEsc = false
var rxBad = false
var rstAck = false
var ashUp = false
var ashErr = ""
var lastData = nil           # randomized data field of our last DATA frame, for retransmission
var lastFrm = 0

# EZSP
var ezspSeq = 0
var ezspVer = 0
var legacyNext = true        # the first VERSION command uses the legacy frame format
var pendingSeq = -1
var pendingResp = nil
var pendingFid = -1
var euiStr = ""
var devId = 0

# counters
var pktCount = 0
var zepSent = 0
var zepFail = 0
var uiDropped = 0
var crcErrors = 0

# outputs
var udp = nil
var zepSeq = 0
var baseUnix = 0             # wall clock at baseMillis, for the ZEP timestamp (0 = time not synced)
var baseMillis = 0
var uiBatch = []
var lastFlush = 0
var lastStatus = 0

# ---------------------------------------------------------------- page
def uiSend(m)
    if uiOpen return BEAPP.send(ch, json.dump(m)) end
    return 0
end

def uiLog(level, text)
    BEAPP.log(text)
    uiSend({"type": "log", "level": level, "text": text})
end

def radioList()
    var out = []
    for id: 1 .. 3
        try
            out.push({
                "id": id, "model": ZB.chipModel(id),
                "efr": ZB.isEFR(id), "zw": ZB.isZW(id),
                "fwType": ZB.getFirmwareType(id), "fwRev": ZB.getFirmwareRev(id),
                "clients": ZB.getZbClients(id)
            })
        except .. as e, m
            # no radio with this number
        end
    end
    return out
end

def uiStatus()
    uiSend({
        "type": "status", "state": state, "err": lastErr,
        "chip": chip, "channel": channel,
        "ui": toUi, "zep": toZep, "host": zepHost, "port": zepPort, "auto": autoStart,
        "ezsp": ezspVer, "eui": euiStr,
        "pkts": pktCount, "zepSent": zepSent, "zepFail": zepFail, "uiDrop": uiDropped, "crcErr": crcErrors,
        "radios": radioList()
    })
    lastStatus = SLZB.millis()
end

def uiFlush()
    lastFlush = SLZB.millis()
    if uiBatch.size() == 0 return end
    if !uiOpen
        uiBatch = []
        return
    end
    if BEAPP.send(ch, json.dump({"type": "pkts", "now": SLZB.millis(), "list": uiBatch})) != 0
        uiBatch = []
    end
    # queue full: the batch stays and is sent with the next flush
end

# ---------------------------------------------------------------- config
def cfgLoad()
    try
        if !FS.exists(CFG_FILE) return end
        var f = FS.open(CFG_FILE, "r")
        var c = json.load(f.read())
        f.close()
        if c == nil return end
        if c.contains("chip") chip = int(c["chip"]) end
        if c.contains("channel") channel = int(c["channel"]) end
        if c.contains("ui") toUi = c["ui"] == true end
        if c.contains("zep") toZep = c["zep"] == true end
        if c.contains("host") zepHost = str(c["host"]) end
        if c.contains("port") zepPort = int(c["port"]) end
        if c.contains("auto") autoStart = c["auto"] == true end
    except .. as e, m
        BEAPP.log("config.json not readable: " .. str(m))
    end
end

def cfgSave()
    try
        var f = FS.open(CFG_FILE, "w")
        f.write(json.dump({"chip": chip, "channel": channel, "ui": toUi, "zep": toZep,
                           "host": zepHost, "port": zepPort, "auto": autoStart}))
        f.close()
    except .. as e, m
        BEAPP.log("cannot save config.json: " .. str(m))
    end
end

# ---------------------------------------------------------------- ZEP (Wireshark)
def daysFromCivil(y, m, d)
    y -= m <= 2 ? 1 : 0
    var era = y / 400
    var yoe = y - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) / 5 + d - 1
    var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
end

def clockInit()
    baseUnix = 0
    baseMillis = SLZB.millis()
    var t = TIME.getAll()
    if t != nil
        baseUnix = daysFromCivil(t["year"], t["month"], t["day"]) * 86400 + t["hour"] * 3600 + t["min"] * 60 + t["sec"]
    end
end

# 8-byte NTP timestamp (seconds since 1900 + 1/65536 s fraction); 32-bit safe: 2208988800 is added in 16-bit halves
def addNtpTime(f)
    if baseUnix == 0
        f.add(0, -4)
        f.add(0, -4)
        return
    end
    var el = SLZB.millis() - baseMillis
    var unix = baseUnix + el / 1000
    var lo = (unix & 0xFFFF) + 0x7E80
    var hi = ((unix >> 16) & 0xFFFF) + 0x83AA + (lo >> 16)
    f.add(hi & 0xFFFF, -2)
    f.add(lo & 0xFFFF, -2)
    f.add(((el % 1000) * 65536) / 1000, -2)
    f.add(0, -2)
end

# ZEP v2 data frame; the 802.15.4 FCS is replaced by RSSI + (CRC OK | LQI/2) as in the TI CC24xx format
def zepSend(pkt, lqi, rssi)
    var d = pkt.copy()
    var n = d.size()
    d[n - 2] = rssi & 0xFF
    d[n - 1] = 0x80 | ((lqi >> 1) & 0x7F)

    var f = bytes("455802")                       # "EX", version 2
    f.add(1, 1)                                   # type: data
    f.add(channel, 1)
    f.add(devId, -2)
    f.add(0, 1)                                   # CRC mode
    f.add(lqi, 1)
    addNtpTime(f)
    f.add(zepSeq, -4)
    f.add(0, -4)                                  # 10 reserved bytes
    f.add(0, -4)
    f.add(0, -2)
    f.add(n, 1)
    f = f + d
    zepSeq = (zepSeq + 1) & 0x7FFFFFFF

    try
        if udp.send(zepHost, zepPort, f) zepSent += 1 else zepFail += 1 end
    except .. as e, m
        zepFail += 1
    end
end

# mfglibRxHandler: linkQuality, rssi, packetLength, packetContents (with the 2-byte FCS)
def onPacket(p)
    if p.size() < 3 return end
    var lqi = p[0]
    var rssi = p.geti(1, 1)
    var n = p[2]
    if n < 5 || p.size() < 3 + n return end
    var pkt = p[3 .. 2 + n]
    pktCount += 1

    if toZep && udp != nil zepSend(pkt, lqi, rssi) end
    if toUi && uiOpen
        if uiBatch.size() < UI_PENDING_MAX
            uiBatch.push([SLZB.millis(), lqi, rssi, pkt[0 .. n - 3].tohex()])
        else
            uiDropped += 1
        end
    end
end

# ---------------------------------------------------------------- EZSP frames from the radio
# one EZSP frame (data field of an ASH DATA frame, de-randomized)
def ezspOnFrame(d)
    if d.size() < 3 return end
    var seq = d[0]
    var fc = d[1]
    var fid
    var p
    if (d[2] & 0x03) == 0x01                      # extended format
        if d.size() < 5 return end
        fid = d.get(3, 2)
        p = d.size() > 5 ? d[5 .. d.size() - 1] : bytes()
    else                                          # legacy format (the first VERSION response)
        fid = d[2]
        p = d.size() > 3 ? d[3 .. d.size() - 1] : bytes()
    end

    if fid == FID_MFGLIB_RX_HANDLER
        onPacket(p)
    elif seq == pendingSeq && (fc & 0x80) != 0 && (fc & 0x18) == 0
        pendingFid = fid
        pendingResp = p
    end
end

# ---------------------------------------------------------------- ASH (UART framing of EZSP)
def crc16(b)
    var c = 0xFFFF
    var n = b.size()
    var i = 0
    while i < n
        c = ((c << 8) & 0xFFFF) ^ CRC_T[((c >> 8) ^ b[i]) & 0xFF]
        i += 1
    end
    return c
end

# frame = control byte + data field; appends the CRC, stuffs reserved bytes, ends with the flag
def ashWrite(frame)
    var f = frame.copy()
    f.add(crc16(frame), -2)
    var out = bytes()
    for i: 0 .. f.size() - 1
        var b = f[i]
        if b == 0x7E || b == 0x7D || b == 0x11 || b == 0x13 || b == 0x18 || b == 0x1A
            out.add(0x7D, 1)
            out.add(b ^ 0x20, 1)
        else
            out.add(b, 1)
        end
    end
    out.add(0x7E, 1)
    ZB.writeBytes(chip, out)
end

def ashAck()
    ashWrite(bytes().add(0x80 | frmRx, 1))
end

def ashSendData(ezsp)
    var d = ezsp.copy()
    for i: 0 .. d.size() - 1 d[i] = d[i] ^ RAND[i] end
    lastData = d
    lastFrm = frmTx
    frmTx = (frmTx + 1) & 7
    ashWrite(bytes().add((lastFrm << 4) | frmRx, 1) + d)
end

def ashResend()
    if lastData != nil
        ashWrite(bytes().add((lastFrm << 4) | 0x08 | frmRx, 1) + lastData)
    end
end

# one ASH frame without the CRC: control byte + data field
def ashOnFrame(f)
    var ctl = f[0]

    if (ctl & 0x80) == 0                          # DATA
        if f.size() < 4 return end
        var frm = (ctl >> 4) & 7
        if frm == frmRx
            frmRx = (frmRx + 1) & 7
            ashAck()
            var d = f[1 .. f.size() - 1]
            for i: 0 .. d.size() - 1 d[i] = d[i] ^ RAND[i] end
            ezspOnFrame(d)
        elif (ctl & 0x08) != 0
            ashAck()                              # retransmission of a frame we already have
        else
            ashWrite(bytes().add(0xA0 | frmRx, 1))  # out of sequence: NAK
        end

    elif ctl == 0xC1 && f.size() == 3             # RSTACK
        if ashUp
            ashErr = "the radio reset unexpectedly (reset code 0x" .. f[2 .. 2].tohex() .. ")"
        end
        rstAck = true

    elif ctl == 0xC2 && f.size() == 3             # ERROR
        ashErr = "the radio reported a fatal error 0x" .. f[2 .. 2].tohex()

    elif (ctl & 0xE0) == 0xA0                     # NAK
        ashResend()
    end
    # ACK: commands are sent one by one and wait for their response, nothing to track
end

# reads whatever the radio sent and decodes it; returns the number of bytes read
def ashPoll()
    var n = ZB.available(chip)
    if n <= 0 return 0 end
    var data = ZB.readBytes(chip, n > 1024 ? 1024 : n)
    var sz = data.size()
    var i = 0
    while i < sz
        var c = data[i]
        i += 1
        if c == 0x7E                              # flag: end of frame
            var fs = rxFrame.size()
            if fs > 0
                if !rxBad && fs >= 3 && crc16(rxFrame) == 0
                    rxFrame.resize(fs - 2)
                    ashOnFrame(rxFrame)
                elif ashUp
                    crcErrors += 1
                end
            end
            rxFrame.clear()
            rxEsc = false
            rxBad = false
        elif c == 0x7D                            # escape: the next byte has bit 5 flipped
            rxEsc = true
        elif c == 0x1A                            # cancel
            rxFrame.clear()
            rxEsc = false
            rxBad = false
        elif c == 0x18                            # substitute: drop the frame
            rxBad = true
        elif c == 0x11 || c == 0x13 || (c == 0xFF && rxFrame.size() == 0)
            # XON / XOFF / wake byte, never frame data
        else
            if rxEsc
                c = c ^ 0x20
                rxEsc = false
            end
            if rxFrame.size() < 256 rxFrame.add(c, 1) else rxBad = true end
        end
    end
    return sz
end

def ashDrain()
    var t0 = SLZB.millis()
    while SLZB.millis() - t0 < 100
        var n = ZB.available(chip)
        if n > 0 ZB.readBytes(chip, n > 1024 ? 1024 : n) else SLZB.delay(10) end
    end
    rxFrame.clear()
    rxEsc = false
    rxBad = false
end

# RST -> wait for RSTACK
def ashReset()
    frmTx = 0
    frmRx = 0
    rstAck = false
    ashUp = false
    ashErr = ""
    lastData = nil
    rxFrame.clear()
    rxEsc = false
    rxBad = false

    ZB.writeBytes(chip, bytes("1A"))              # cancel anything half-sent
    ashWrite(bytes("C0"))
    var t0 = SLZB.millis()
    while SLZB.millis() - t0 < 4000
        if ashPoll() == 0 SLZB.delay(5) end
        if rstAck
            ashUp = true
            return true
        end
    end
    return false
end

# ---------------------------------------------------------------- EZSP
# sends a command and waits for its response; returns the response parameters or nil
def ezspCommand(fid, params)
    ezspSeq = (ezspSeq + 1) & 0xFF
    var f = bytes()
    f.add(ezspSeq, 1)
    f.add(0x00, 1)                                # frame control: command
    if legacyNext
        f.add(fid & 0xFF, 1)                      # legacy format, only for the very first VERSION
        legacyNext = false
    else
        f.add(0x01, 1)                            # extended frame format version 1
        f.add(fid, 2)
    end
    if params != nil f = f + params end

    pendingSeq = ezspSeq
    pendingResp = nil
    pendingFid = -1
    ashSendData(f)

    var t0 = SLZB.millis()
    var tries = 0
    while pendingResp == nil && ashErr == ""
        if ashPoll() == 0 SLZB.delay(2) end
        if SLZB.millis() - t0 > EZSP_TIMEOUT
            if tries >= 2 break end
            tries += 1
            t0 = SLZB.millis()
            ashResend()
        end
    end
    pendingSeq = -1
    if pendingFid == FID_INVALID_COMMAND return nil end
    return pendingResp
end

# status field of a response: EmberStatus (1 byte) before EZSP v14, sl_status_t (4 bytes) after
def ezspStatus(p)
    if p == nil || p.size() == 0 return -1 end
    if ezspVer < 14 || p.size() < 4 return p[0] end
    return p.get(0, 4)
end

# ---------------------------------------------------------------- sniffer control
def setChannel(c)
    var st = ezspStatus(ezspCommand(FID_MFGLIB_SET_CHANNEL, bytes().add(c, 1)))
    if st != 0
        uiLog("error", "cannot switch to channel " .. str(c) .. " (status " .. str(st) .. ")")
        return false
    end
    channel = c
    return true
end

def ezspStart()
    var r = ezspCommand(FID_VERSION, bytes().add(13, 1))
    if r == nil || r.size() < 4
        lastErr = "no EZSP answer: the radio must run the Zigbee coordinator (EmberZNet NCP) firmware"
        return false
    end
    var ver = r[0]
    if ver < 8
        lastErr = "EZSP v" .. str(ver) .. " is too old, update the radio firmware"
        return false
    end
    if ver != 13
        r = ezspCommand(FID_VERSION, bytes().add(ver, 1))
        if r == nil || r.size() < 4 || r[0] != ver
            lastErr = "the radio did not accept EZSP v" .. str(ver)
            return false
        end
    end
    ezspVer = ver

    var eui = ezspCommand(FID_GET_EUI64, nil)
    if eui != nil && eui.size() >= 8
        devId = eui.get(0, 2)                     # ZEP device id: low 16 bits of the EUI64, like ember-zli
        var le = eui[0 .. 7]
        le.reverse()
        euiStr = le.tohex()
    end

    var st = ezspStatus(ezspCommand(FID_MFGLIB_START, bytes().add(1, 1)))
    if st != 0
        lastErr = st < 0 ? "no answer to mfglibStart" :
                  "mfglibStart failed (status " .. str(st) .. "): the radio firmware may be built without the manufacturing library"
        return false
    end
    if !setChannel(channel)
        lastErr = "cannot set channel " .. str(channel)
        ezspCommand(FID_MFGLIB_END, nil)
        return false
    end
    return true
end

# hardware reset of the radio and back to the Zigbee socket
def radioRelease()
    ZB.reboot(chip)
    ashUp = false
    ashDrain()
    ZB.suspend(chip, false)
end

def startSniff()
    if sniffing return true end
    lastErr = ""

    if !ZB.isEFR(chip) || ZB.isZW(chip)
        lastErr = "radio " .. str(chip) .. " (" .. ZB.chipModel(chip) .. ") is not an EFR32 Zigbee radio"
        uiLog("error", lastErr)
        return false
    end
    if ZB.getFirmwareType(chip) != ZB.FW_COORDINATOR
        lastErr = "radio " .. str(chip) .. " does not run the Zigbee coordinator (EmberZNet NCP) firmware"
        uiLog("error", lastErr)
        return false
    end
    if toZep
        if !NETWORK.isReady()
            lastErr = "the network is not ready, cannot send to Wireshark"
            uiLog("error", lastErr)
            return false
        end
        if udp == nil udp = UDP_CLIENT() end
    end

    state = "starting"
    uiStatus()
    uiLog("info", "taking radio " .. str(chip) .. " over, the Zigbee socket of this radio is paused")

    ZB.suspend(chip, true)
    ashDrain()
    legacyNext = true
    ezspVer = 0

    var ok = ashReset()
    if !ok
        lastErr = "the radio does not answer the ASH reset: it must run the Zigbee coordinator (EmberZNet NCP) firmware"
    else
        ok = ezspStart()
    end

    if !ok
        uiLog("error", lastErr)
        radioRelease()
        state = "idle"
        uiStatus()
        return false
    end

    clockInit()
    pktCount = 0
    zepSent = 0
    zepFail = 0
    uiDropped = 0
    crcErrors = 0
    uiBatch = []
    sniffing = true
    state = "sniffing"
    uiLog("info", "sniffing channel " .. str(channel) .. " on radio " .. str(chip) .. " (EZSP v" .. str(ezspVer) .. ")" ..
          (toZep ? ", ZEP to " .. zepHost .. ":" .. str(zepPort) : ""))
    uiStatus()
    return true
end

def stopSniff(reason)
    if !sniffing return end
    state = "stopping"
    uiStatus()
    if ashErr == "" ezspCommand(FID_MFGLIB_END, nil) end
    sniffing = false
    uiFlush()
    radioRelease()
    state = "idle"
    uiLog(reason == nil ? "info" : "error", "sniffing stopped" .. (reason != nil ? ": " .. reason : "") ..
          ", radio " .. str(chip) .. " restarted and given back to the Zigbee socket")
    uiStatus()
end

# ---------------------------------------------------------------- commands
def applyOutputs(cmd)
    var ui = cmd.contains("ui") ? cmd["ui"] == true : toUi
    var zep = cmd.contains("zep") ? cmd["zep"] == true : toZep
    var host = cmd.contains("host") ? str(cmd["host"]) : zepHost
    var port = cmd.contains("port") ? int(cmd["port"]) : zepPort

    if !ui && !zep
        uiLog("error", "choose at least one destination")
        return false
    end
    if zep && host == ""
        uiLog("error", "enter the Wireshark host")
        return false
    end
    if port < 1 || port > 65535
        uiLog("error", "invalid UDP port")
        return false
    end
    toUi = ui
    toZep = zep
    zepHost = host
    zepPort = port
    if cmd.contains("auto") autoStart = cmd["auto"] == true end
    if toZep && udp == nil && NETWORK.isReady() udp = UDP_CLIENT() end
    return true
end

def handleCmd(cmd)
    if cmd == nil return end
    var c = cmd["cmd"]

    if c == "start"
        if sniffing
            uiLog("error", "already sniffing")
        else
            var ok = applyOutputs(cmd)
            var chn = int(cmd.find("channel", channel))
            if chn < 11 || chn > 26
                uiLog("error", "channel must be 11..26")
                ok = false
            end
            if ok
                chip = int(cmd.find("chip", chip))
                channel = chn
                cfgSave()
                startSniff()
            end
        end

    elif c == "stop"
        stopSniff(nil)

    elif c == "channel"
        var chn = int(cmd.find("channel", 0))
        if chn < 11 || chn > 26
            uiLog("error", "channel must be 11..26")
        elif sniffing
            if setChannel(chn)
                uiLog("info", "channel " .. str(chn))
                cfgSave()
            end
        else
            channel = chn
        end

    elif c == "set"
        if applyOutputs(cmd)
            cfgSave()
            if sniffing uiLog("info", "destinations updated") end
        end
    end

    uiStatus()
end

# ---------------------------------------------------------------- main
cfgLoad()
if autoStart && toZep
    BEAPP.log("auto start: waiting for the network")
    if NETWORK.waitReady(120)
        SLZB.delay(3000)                          # let the radios finish their start
        startSniff()
    else
        BEAPP.log("auto start: no network")
    end
end

while true
    var busy = false
    if sniffing
        busy = ashPoll() > 0
        if ashErr != ""
            lastErr = ashErr
            stopSniff(ashErr)
        end
        if SLZB.millis() - lastFlush >= UI_FLUSH_MS uiFlush() end
    end

    # page events; the timeout doubles as the radio poll tick
    var payload = BEAPP.receive(ch, sniffing ? (busy ? 0 : 5) : 200)

    if payload != nil
        var m = json.load(payload)

        if m == nil
            # nothing

        elif m["event"] == "open"
            uiOpen = true
            uiBatch = []
            uiStatus()

        elif m["event"] == "close"
            uiOpen = false
            uiBatch = []
            if sniffing && !toZep stopSniff("the app page was closed and Wireshark is not a destination") end

        elif m["event"] == "msg"
            handleCmd(json.load(str(m["data"])))
        end
    end

    if uiOpen && SLZB.millis() - lastStatus >= STATUS_MS uiStatus() end
end
