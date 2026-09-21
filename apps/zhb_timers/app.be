# ZHB Timers — Berry backend.
#
# Timers that send commands to Zigbee Hub devices. Works only while the
# coordinator runs in Zigbee Hub (standalone) mode — otherwise the UI shows
# a warning and the timers do not fire.
#
# Timer types:
#   interval  — fires every N seconds while running
#   timeout   — fires once, N seconds after being started, then stops itself
#   schedule  — fires every day at HH:MM (needs NTP-synced time)
#
# Actions: on / off / toggle (ZigbeeDevice.sendOnOff) and brightness
# (ZigbeeDevice.sendBri), sent to the configured endpoint.
#
# The configuration (incl. the running flag) lives in the app folder:
# /beapps/zhb_timers/timers.json — timers survive reboots when the app is
# set to "Start on boot".
#
# UI -> backend (BeApp.sendMessage, JSON string):
#   {"cmd":"list"}
#   {"cmd":"add","timer":{name,type,value,days,ieee,ep,action,bri}}
#   {"cmd":"edit","id":N,"timer":{...}}
#   {"cmd":"del","id":N}   {"cmd":"run","id":N,"on":true|false}
#
# backend -> UI (BEAPP.send -> BeApp.onMessage, JSON string):
#   {"type":"state","zhb":bool,"devices":[{ieee,name,model}],"timers":[...]}
#   {"type":"fired","id":N}   {"type":"error","text":"..."}

import BEAPP
import SLZB
import ZHB
import TIME
import FS
import json
import string

var ch = BEAPP.claim()
if ch == 0
    SLZB.log("no free app channel, exiting")
    return
end

BEAPP.setLogSize(8192)

var CONF = "/beapps/zhb_timers/timers.json"

var timers = []      # persisted: {id, name, type, value, ieee, ep, action, bri, enabled}
var nextId = 1
var rt = {}          # runtime per timer id (str): last / deadline / firedAt — not persisted
var uiOpen = false
var zhbOk = false

def uiSend(m)
    if uiOpen BEAPP.send(ch, json.dump(m)) end
end

def loadConf()
    if !FS.exists(CONF) return end
    try
        var f = FS.open(CONF, "r")
        var doc = json.load(f.read())
        f.close()
        if doc != nil
            timers = doc.find("timers", [])
            nextId = doc.find("nextId", 1)
        end
    except .. as e, m
        BEAPP.log("config load failed: " .. str(m))
    end
end

def saveConf()
    try
        var f = FS.open(CONF, "w")
        f.write(json.dump({"timers": timers, "nextId": nextId}))
        f.close()
    except .. as e, m
        BEAPP.log("config save failed: " .. str(m))
    end
end

# device list for the UI; also probes whether Zigbee Hub mode is active
def deviceList()
    var out = []
    try
        for dev: ZHB.getDevices()
            out.push({"ieee": dev.getIeee(), "name": dev.getName(), "model": dev.getModel()})
        end
        zhbOk = true
    except .. as e, m
        zhbOk = false
    end
    return out
end

def pushState()
    uiSend({"type": "state", "zhb": zhbOk, "devices": deviceList(), "timers": timers})
end

def timerLabel(t)
    return "'" .. str(t.find("name", "")) .. "' (#" .. str(t["id"]) .. ")"
end

def fire(t)
    try
        # getIeee() returns hex without the 0x prefix; getDevice() needs it to parse as IEEE
        var dev = ZHB.getDevice("0x" .. str(t["ieee"]))
        var ep = int(t.find("ep", 1))
        var act = str(t["action"])

        if act == "on"
            dev.sendOnOff(1, ep)
        elif act == "off"
            dev.sendOnOff(0, ep)
        elif act == "toggle"
            dev.sendOnOff(2, ep)
        elif act == "bri"
            dev.sendBri(int(t.find("bri", 128)), ep)
        end

        BEAPP.log("timer " .. timerLabel(t) .. " fired: " .. act)
        uiSend({"type": "fired", "id": t["id"]})
    except .. as e, m
        BEAPP.log("timer " .. timerLabel(t) .. " failed: " .. str(m))
        uiSend({"type": "error", "text": "timer " .. timerLabel(t) .. " failed: " .. str(m)})
    end
end

def tick()
    var now = SLZB.millis()

    for t: timers
        if !t.find("enabled", false) continue end

        var key = str(t["id"])
        var r = rt.find(key)
        if r == nil
            r = {}
            rt[key] = r
        end

        if t["type"] == "interval"
            var last = r.find("last")
            if last == nil || now - last < 0   # first tick after start, or millis wrap
                r["last"] = now
            elif now - last >= int(t["value"]) * 1000
                r["last"] = now
                fire(t)
            end

        elif t["type"] == "timeout"
            var dl = r.find("deadline")
            if dl == nil
                r["deadline"] = now + int(t["value"]) * 1000
            elif now - dl >= 0
                r.remove("deadline")
                t["enabled"] = false   # one-shot: stop itself
                saveConf()
                fire(t)
                pushState()
            end

        elif t["type"] == "schedule"
            var tm = TIME.getAll()      # need the weekday too (Sunday = 0)
            if tm == nil continue end   # no NTP sync yet

            var days = t.find("days", [])
            var dayOk = days == nil || days.size() == 0 || days.find(tm["weekday"]) != nil

            var cur = string.format("%02d:%02d", tm["hour"], tm["min"])
            if dayOk && cur == str(t["value"])
                if r.find("firedAt") != cur
                    r["firedAt"] = cur   # fire once within the matching minute
                    fire(t)
                end
            elif r.contains("firedAt")
                r.remove("firedAt")      # re-arm for the next matching day
            end
        end
    end
end

# validate the UI payload; returns the sanitized timer map, or a string with the error
def sanitizeTimer(c)
    if c == nil return "invalid timer" end

    var tp = str(c.find("type", ""))
    if tp != "interval" && tp != "timeout" && tp != "schedule" return "invalid timer type" end
    if str(c.find("ieee", "")) == "" return "please select a device" end

    # schedule only: weekdays 0..6 (Sunday = 0); empty = every day
    var days = []
    var din = c.find("days")
    if isinstance(din, list)
        for d: din
            var i = int(d)
            if i >= 0 && i <= 6 && days.find(i) == nil days.push(i) end
        end
    end

    return {
        "name": str(c.find("name", "")),
        "type": tp, "value": c.find("value", 60), "days": days,
        "ieee": str(c["ieee"]), "ep": int(c.find("ep", 1)),
        "action": str(c.find("action", "toggle")), "bri": int(c.find("bri", 128))
    }
end

def handleCmd(cmd)
    if cmd == nil return end

    if cmd["cmd"] == "list"
        pushState()
        return
    end

    if cmd["cmd"] == "add" || cmd["cmd"] == "edit"
        var res = sanitizeTimer(cmd.find("timer"))

        if type(res) == "string"
            uiSend({"type": "error", "text": res})

        elif cmd["cmd"] == "add"
            res["id"] = nextId
            res["enabled"] = false
            if res["name"] == "" res["name"] = "Timer " .. str(nextId) end
            timers.push(res)
            nextId += 1
            saveConf()
            BEAPP.log("timer added: " .. timerLabel(res))

        else  # edit: overwrite the fields, keep id and the running flag
            for t: timers
                if t["id"] == cmd["id"]
                    for k: ["name", "type", "value", "days", "ieee", "ep", "action", "bri"]
                        t[k] = res[k]
                    end
                    if t["name"] == "" t["name"] = "Timer " .. str(t["id"]) end
                    rt.remove(str(t["id"]))   # re-baseline interval/timeout/schedule state
                    saveConf()
                    BEAPP.log("timer updated: " .. timerLabel(t))
                    break
                end
            end
        end

    elif cmd["cmd"] == "del"
        var i = 0
        while i < timers.size()
            if timers[i]["id"] == cmd["id"]
                BEAPP.log("timer removed: " .. timerLabel(timers[i]))
                rt.remove(str(cmd["id"]))
                timers.remove(i)
                saveConf()
                break
            end
            i += 1
        end

    elif cmd["cmd"] == "run"
        for t: timers
            if t["id"] == cmd["id"]
                t["enabled"] = cmd.find("on", false) == true
                rt.remove(str(t["id"]))   # reset the interval/timeout baseline
                saveConf()
                BEAPP.log("timer " .. timerLabel(t) .. (t["enabled"] ? " started" : " stopped"))
                break
            end
        end
    end

    pushState()
end

loadConf()
deviceList()   # sets zhbOk
BEAPP.log("ZHB Timers started: " .. str(timers.size()) .. " timer(s), ZHB " .. (zhbOk ? "active" : "NOT active"))

var lastProbe = SLZB.millis()

while true
    # commands / lifecycle from the page; the 500 ms timeout doubles as the timer tick
    var payload = BEAPP.receive(ch, 500)

    if payload != nil
        var m = json.load(payload)

        if m == nil
            # nothing

        elif m["event"] == "open"
            uiOpen = true
            pushState()

        elif m["event"] == "close"
            uiOpen = false

        elif m["event"] == "msg"
            handleCmd(json.load(str(m["data"])))
        end
    end

    if zhbOk
        tick()
    else
        # the hub may come up after this script (boot order) - re-probe every 10 s
        var now = SLZB.millis()
        if now - lastProbe >= 10000 || now - lastProbe < 0
            lastProbe = now
            deviceList()
            if zhbOk
                BEAPP.log("Zigbee Hub is up, timers armed")
                pushState()
            end
        end
    end
end
