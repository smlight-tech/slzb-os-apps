# ZTOE Parser — Berry backend.
#
# Parses the hourly power outage schedule of Zhytomyroblenergo (www.ztoe.com.ua/unhooking-search.php)
# for one sub-queue ("черга.підчерга", e.g. 3.1) and broadcasts it to other scripts over an ISC
# broadcast channel. The sub-queue is found by address on the app page (district -> settlement ->
# street -> houses), the same way as the search form of the site, and is kept in config.json.
#
# The site is windows-1251: names are never decoded here, they go to the page as raw bytes in base64
# (the page decodes them with TextDecoder) and come back as UTF-8 only to be stored in the config.
#
# UI -> backend (BeApp.sendMessage, JSON string):
#   {"cmd":"status"}   {"cmd":"parse"}
#   {"cmd":"rems"}   {"cmd":"towns","rem":1}   {"cmd":"streets","rem":1,"town":16613}
#   {"cmd":"houses","rem":1,"town":16613,"street":173521}
#   {"cmd":"save","queue":3,"sub":1,"interval":30,"channel":10,"enabled":true,"addr":{...}}
#
# backend -> UI (BEAPP.send -> BeApp.onMessage, JSON string):
#   {"type":"status",...}   {"type":"log","level":"info"|"error","text":...}
#   {"type":"opts","kind":"rem"|"town"|"street","b64":"<cp1251 lines: id\tname>"}
#   {"type":"houses","b64":"<cp1251 lines: cells of the result table joined by \t>"}
#
# ISC broadcast message (JSON string), see README.md:
#   {"queue":"3.1","updated":"23:00 30.09.2026",
#    "days":[{"date":"30.09.2026","slots":"000..111..","off":[{"start":800,"end":1100}]}, ...]}

import BEAPP
import SLZB
import HTTP
import ISC
import NETWORK
import FS
import string
import json

var URL = "https://www.ztoe.com.ua/unhooking-search.php"
var CFG_FILE = "/beapps/ztoe_parser/config.json"
var LISTS_FILE = "/beapps/ztoe_parser/lists.json"   # lists of the saved address, see listKey()
var CHUNK = 2048              # bytes per network read
var FORM_MAX = 131072         # the search form of the biggest town (Zhytomyr, ~970 streets) is ~57 KB
var HEAD_MAX = 262144         # page text before the schedule (form + address results)
var ROW_MAX = 32768           # one schedule row (~12 KB)
var SLOTS = 48                # half-hour slots of a day
var INTERVAL_MIN = 5          # minutes
var INTERVAL_MAX = 1440

var ch = BEAPP.claim()
if ch == 0
    SLZB.log("ZTOE Parser: немає вільного каналу додатків, вихід")
    return
end

BEAPP.setLogSize(4096)
BEAPP.log("бекенд ZTOE Parser запущено")

# ---------------------------------------------------------------- config
var queue = 0                 # 1..6, 0 = not configured
var sub = 0                   # 1..2
var interval = 30             # minutes
var iscCh = 10                # ISC broadcast channel 0..100
var enabled = true            # parse on the interval
var addr = {}                 # {"rem","remName","town","townName","street","streetName","houses"} - for the page only

# Address lists (base64 of the "id\tname" lines) by listKey(). The page re-selects the saved address every time
# it opens; the lists of that address are kept in lists.json (read once at the start) so that opening the page
# makes no requests to the site. `listsRecent` holds the last list of each kind fetched while browsing (RAM only).
var listsSaved = {}
var listsRecent = {}          # kind -> [key, b64]

# ---------------------------------------------------------------- state
var uiOpen = false
var busy = ""                 # what the backend is doing now, "" = idle
var claimedCh = -1
var lastMsg = nil             # last broadcast schedule (map)
var lastOk = 0                # millis of the last successful parse, 0 = never
var lastTry = 0
var lastErr = ""
var lastDelivered = -1        # subscribers reached by the last ISC send
var nextRun = 0

def uiSend(m)
    if uiOpen return BEAPP.send(ch, json.dump(m)) end
    return 0
end

def uiLog(level, text)
    BEAPP.log(text)
    uiSend({"type": "log", "level": level, "text": text})
end

def uiStatus()
    var now = SLZB.millis()
    uiSend({
        "type": "status", "busy": busy, "err": lastErr,
        "queue": queue, "sub": sub, "interval": interval, "channel": iscCh, "enabled": enabled, "addr": addr,
        "claimed": claimedCh == iscCh,
        "lastOkAgo": lastOk == 0 ? -1 : (now - lastOk) / 1000,
        "nextIn": (enabled && queue > 0) ? (nextRun - now) / 1000 : -1,
        "delivered": lastDelivered,
        "schedule": lastMsg
    })
end

def setBusy(what)
    busy = what
    uiStatus()
end

def cfgLoad()
    try
        if !FS.exists(CFG_FILE) return end
        var f = FS.open(CFG_FILE, "r")
        var c = json.load(f.read())
        f.close()
        if c == nil return end
        queue = int(c.find("queue", 0))
        sub = int(c.find("sub", 0))
        interval = int(c.find("interval", 30))
        iscCh = int(c.find("channel", 10))
        enabled = c.find("enabled", true) == true
        var a = c.find("addr", nil)
        if a != nil addr = a end
    except .. as e, m
        BEAPP.log("не вдалося прочитати config.json: " .. str(m))
    end
end

def cfgSave()
    try
        var f = FS.open(CFG_FILE, "w")
        f.write(json.dump({"queue": queue, "sub": sub, "interval": interval, "channel": iscCh,
                           "enabled": enabled, "addr": addr}))
        f.close()
        return true
    except .. as e, m
        uiLog("error", "не вдалося зберегти config.json: " .. str(m))
    end
    return false
end

def listKey(kind, rem, town)
    if kind == "rem" return "rem" end
    if kind == "town" return "town:" .. str(rem) end
    return "street:" .. str(rem) .. ":" .. str(town)
end

def listsLoad()
    try
        if !FS.exists(LISTS_FILE) return end
        var f = FS.open(LISTS_FILE, "r")
        var c = json.load(f.read())
        f.close()
        if c != nil listsSaved = c end
    except .. as e, m
        BEAPP.log("не вдалося прочитати lists.json: " .. str(m))
    end
end

def listFind(key)
    if listsSaved.contains(key) return listsSaved[key] end
    for r: listsRecent
        if r[0] == key return r[1] end
    end
    return nil
end

# keeps the lists of the saved address only (the district list always)
def listsSave()
    var keep = {}
    var keys = ["rem"]
    if addr.find("rem", 0) > 0 keys.push(listKey("town", addr["rem"], 0)) end
    if addr.find("rem", 0) > 0 && addr.find("town", 0) > 0 keys.push(listKey("street", addr["rem"], addr["town"])) end
    for k: keys
        var v = listFind(k)
        if v != nil keep[k] = v end
    end
    listsSaved = keep
    try
        var f = FS.open(LISTS_FILE, "w")
        f.write(json.dump(keep))
        f.close()
    except .. as e, m
        BEAPP.log("не вдалося зберегти lists.json: " .. str(m))
    end
end

# the ISC broadcast channel follows the config
def claimChannel()
    if claimedCh == iscCh return true end
    if claimedCh >= 0
        ISC.release(claimedCh)
        claimedCh = -1
    end
    if ISC.claim(iscCh, ISC.CH_TYPE_BROADCAST)
        claimedCh = iscCh
        return true
    end
    uiLog("error", "канал ISC " .. str(iscCh) .. " зайнятий іншим скриптом - виберіть інший")
    return false
end

# ---------------------------------------------------------------- page reader
# The page is read in chunks into `page`; every read is checked for the end of the response,
# so a cut or changed page ends in an error, never in an endless loop.
var page = ""
var pageEnd = false

def fill()
    if pageEnd return false end
    var s = HTTP.streamReadString(CHUNK)
    if s == ""
        pageEnd = true            # end of the response or a read error
        return false
    end
    page = page + s
    return true
end

# skips everything up to and including `token`; false if the page ended first
def skipPast(token)
    while true
        var i = string.find(page, token)
        if i >= 0
            page = page[i + size(token) .. size(page) - 1]
            return true
        end
        # keep the tail: it may hold the beginning of `token`
        var keep = size(token) - 1
        if size(page) > keep page = page[size(page) - keep .. size(page) - 1] end
        if !fill() return false end
    end
end

# text before `token` (the token is skipped); nil if the page ended or the text is longer than maxLen
def readUntil(token, maxLen)
    while true
        var i = string.find(page, token)
        if i >= 0
            var text = i > 0 ? page[0 .. i - 1] : ""
            page = page[i + size(token) .. size(page) - 1]
            return text
        end
        if size(page) > maxLen return nil end
        if !fill() return nil end
    end
end

# opens the page (POST with `post`, GET when it is ""), runs `reader` and always closes the client;
# returns what `reader` returned, nil on any failure (lastErr is set)
def withPage(post, reader)
    if !NETWORK.isReady()
        lastErr = "мережа ще не готова"
        return nil
    end
    page = ""
    pageEnd = false
    var result = nil
    var opened = post == "" ? HTTP.open(URL, "get", 0, true) : HTTP.open(URL, "post", size(post), true)
    if opened
        try
            if post != "" HTTP.setHeader("Content-Type", "application/x-www-form-urlencoded") end
            HTTP.completeStreamConfig()
            if post != "" HTTP.streamWriteString(post) end
            var code = HTTP.perform()
            if code == 200
                result = reader()
            else
                lastErr = "www.ztoe.com.ua відповів кодом " .. str(code)
            end
        except .. as e, m
            lastErr = "помилка запиту: " .. str(e) .. " " .. str(m)
        end
    else
        lastErr = "не вдалося відкрити HTTP-клієнт"
    end
    HTTP.close()          # the rest of the page is not needed: closing drops the connection
    page = ""
    return result
end

# ---------------------------------------------------------------- address search
# options of <select name="..."> as "id\tname" lines (names stay windows-1251), value 0 skipped
def selectOptions(html, name)
    var i = string.find(html, '<select name="' .. name .. '"')
    if i < 0 return nil end
    var e = string.find(html, "</select>", i)
    if e < 0 e = size(html) end
    var lines = []
    var p = string.find(html, '<option value="', i)
    while p >= 0 && p < e
        var vs = p + 15
        var ve = string.find(html, '"', vs)
        if ve < 0 break end
        var gt = string.find(html, ">", ve)
        if gt < 0 break end
        var lt = string.find(html, "<", gt + 1)
        if lt < 0 break end
        var id = ve > vs ? html[vs .. ve - 1] : ""
        var name2 = lt > gt + 1 ? html[gt + 1 .. lt - 1] : ""
        if id != "" && id != "0" lines.push(id .. "\t" .. name2) end
        p = string.find(html, '<option value="', lt)
    end
    return lines
end

def sendOptions(kind, name, post, key)
    var cached = listFind(key)
    if cached != nil
        uiSend({"type": "opts", "kind": kind, "b64": cached})
        return
    end

    setBusy("завантаження списку")
    lastErr = ""
    var lines = withPage(post, def ()
        var form = readUntil("</form>", FORM_MAX)
        if form == nil
            lastErr = "на сторінці немає форми пошуку"
            return nil
        end
        return selectOptions(form, name)
    end)
    if lines == nil
        if lastErr == "" lastErr = "на сторінці немає цього списку" end
        uiLog("error", lastErr)
    else
        var b64 = bytes().fromstring(lines.concat("\n")).tob64()
        listsRecent[kind] = [key, b64]
        uiSend({"type": "opts", "kind": kind, "b64": b64})
    end
    setBusy("")
end

# cells of an HTML table row as plain text (tags inside a cell removed)
def rowCells(tr)
    var cells = []
    var p = string.find(tr, "<td")
    while p >= 0
        var gt = string.find(tr, ">", p)
        if gt < 0 break end
        var e = string.find(tr, "</td>", gt)
        if e < 0 e = size(tr) end
        var raw = e > gt + 1 ? tr[gt + 1 .. e - 1] : ""
        # drop inner tags (<b>, <a ...>)
        var text = ""
        var t = 0
        while t < size(raw)
            var lt = string.find(raw, "<", t)
            if lt < 0
                text += raw[t .. size(raw) - 1]
                break
            end
            if lt > t text += raw[t .. lt - 1] end
            var gt2 = string.find(raw, ">", lt)
            if gt2 < 0 break end
            t = gt2 + 1
        end
        cells.push(text)
        p = string.find(tr, "<td", e)
    end
    return cells
end

# the address result table ("РЕМ | Населений пункт | Вулиця | Будинки | Черга | Підчерга | Примітка")
def sendHouses(post)
    setBusy("пошук адреси")
    lastErr = ""
    var lines = withPage(post, def ()
        var head = readUntil("<!--0<br>-->", HEAD_MAX)
        if head == nil
            lastErr = "сторінка обірвалась до результатів пошуку"
            return nil
        end
        var fe = string.find(head, "</form>")
        var ti = string.find(head, '<table border="1"', fe < 0 ? 0 : fe)
        var out = []
        if ti < 0 return out end          # nothing found for the address
        var te = string.find(head, "</table>", ti)
        if te < 0 te = size(head) end
        var p = string.find(head, "<tr", ti)
        var first = true
        while p >= 0 && p < te
            var e = string.find(head, "</tr>", p)
            if e < 0 e = te end
            if !first                     # the first row is the header
                var cells = rowCells(head[p .. e - 1])
                if size(cells) >= 6 out.push(cells.concat("\t")) end
            end
            first = false
            p = string.find(head, "<tr", e)
        end
        return out
    end)
    if lines == nil
        uiLog("error", lastErr)
    else
        uiSend({"type": "houses", "b64": bytes().fromstring(lines.concat("\n")).tob64()})
    end
    setBusy("")
end

# ---------------------------------------------------------------- schedule
# half-hour slot -> HHMM: 0 -> 0, 1 -> 30, 2 -> 100 ... 47 -> 2330, 48 -> 2400
def slotTime(i)
    return (i / 2) * 100 + (i % 2) * 30
end

# a slot is an outage when its cell has a background other than white
def slotOff(cell)
    var b = string.find(cell, "background")
    if b < 0 return false end
    var c = string.find(cell, ":", b)
    if c < 0 return false end
    var e = string.find(cell, ";", c)
    var q = string.find(cell, '"', c)
    if e < 0 || (q >= 0 && q < e) e = q end
    if e < 0 return false end
    var color = string.tolower(string.replace(cell[c + 1 .. e - 1], " ", ""))
    return color != "white" && color != "#ffffff" && color != "#fff" && color != "transparent" && color != ""
end

# day table: the reader stands right after its "<!--N<br>-->" mark; nil if the row is not there
def readDay(key)
    var date = ""
    if skipPast('font-size:12pt;">')
        var d = readUntil("</b>", 64)
        if d != nil date = d end
    end
    # "pidcherga_id=5" is also the beginning of "pidcherga_id=50": match with the closing quote
    if !skipPast("pidcherga_id=" .. str(key) .. '"') return nil end
    var row = readUntil("</tr>", ROW_MAX)
    if row == nil return nil end

    # the slots are the last 48 cells of the row (X.1 rows have one cell more than X.2 rows)
    var starts = []
    var p = string.find(row, "<td")
    while p >= 0
        starts.push(p)
        p = string.find(row, "<td", p + 3)
    end
    if size(starts) < SLOTS
        lastErr = "неочікуваний рядок графіка: " .. str(size(starts)) .. " клітинок"
        return nil
    end

    var slots = ""
    var off = []
    var cur = nil
    var first = size(starts) - SLOTS
    for i: 0 .. SLOTS - 1
        var a = starts[first + i]
        var b = i < SLOTS - 1 ? starts[first + i + 1] - 1 : size(row) - 1
        var isOff = slotOff(row[a .. b])
        slots += isOff ? "1" : "0"
        if isOff && cur == nil
            cur = {"start": slotTime(i), "end": 2400}
            off.push(cur)
        elif !isOff && cur != nil
            cur["end"] = slotTime(i)
            cur = nil
        end
    end
    return {"date": date, "slots": slots, "off": off}
end

def fetchSchedule()
    var key = (queue - 1) * 2 + sub
    return withPage("", def ()
        var head = readUntil("<!--0<br>-->", HEAD_MAX)
        if head == nil
            lastErr = "на сторінці немає графіка"
            return nil
        end
        var updated = ""
        var h = string.find(head, "<h4>")
        if h >= 0
            var he = string.find(head, "</h4>", h)
            var dash = string.find(head, " - ", h)
            if he > 0 && dash > 0 && dash < he updated = head[dash + 3 .. he - 1] end   # "23:00 30.09.2026"
        end

        var days = []
        var d0 = readDay(key)
        if d0 == nil
            if lastErr == "" lastErr = "підчерги " .. str(queue) .. "." .. str(sub) .. " немає в графіку" end
            return nil
        end
        days.push(d0)
        if skipPast("<!--1<br>-->")      # tomorrow, when already published
            var d1 = readDay(key)
            if d1 != nil days.push(d1) end
        end
        return {"queue": str(queue) .. "." .. str(sub), "updated": updated, "days": days}
    end)
end

def runParse()
    if queue < 1 || sub < 1
        lastErr = "спочатку виберіть адресу або підчергу"
        uiStatus()
        return
    end
    lastTry = SLZB.millis()
    nextRun = lastTry + interval * 60000
    setBusy("отримання графіка")
    lastErr = ""
    var msg = fetchSchedule()
    if msg == nil
        uiLog("error", "не вдалося отримати графік: " .. lastErr)
    else
        lastMsg = msg
        lastOk = SLZB.millis()
        if claimChannel()
            lastDelivered = ISC.send(iscCh, json.dump(msg))
        else
            lastDelivered = -1
            lastErr = "канал ISC " .. str(iscCh) .. " зайнятий іншим скриптом, графік не надіслано"
        end
        var n = 0
        for d: msg["days"] n += size(d["off"]) end
        BEAPP.log("графік " .. msg["queue"] .. " (" .. msg["updated"] .. "): відключень " .. str(n) .. ", " ..
                  (lastDelivered < 0 ? "не надіслано" : "отримали скриптів: " .. str(lastDelivered)))
    end
    setBusy("")
end

# ---------------------------------------------------------------- commands
def urlInt(v)
    return str(int(v))
end

def handleCmd(cmd)
    if cmd == nil return end
    var c = cmd["cmd"]

    if c == "rems"
        sendOptions("rem", "rem_id", "", listKey("rem", 0, 0))
    elif c == "towns"
        sendOptions("town", "naspunkt_id", "rem_id=" .. urlInt(cmd["rem"]), listKey("town", int(cmd["rem"]), 0))
    elif c == "streets"
        sendOptions("street", "vulica_id", "rem_id=" .. urlInt(cmd["rem"]) .. "&naspunkt_id=" .. urlInt(cmd["town"]),
                    listKey("street", int(cmd["rem"]), int(cmd["town"])))
    elif c == "houses"
        sendHouses("rem_id=" .. urlInt(cmd["rem"]) .. "&naspunkt_id=" .. urlInt(cmd["town"]) .. "&vulica_id=" .. urlInt(cmd["street"]))

    elif c == "save"
        var q = int(cmd.find("queue", queue))
        var s = int(cmd.find("sub", sub))
        var iv = int(cmd.find("interval", interval))
        var chn = int(cmd.find("channel", iscCh))
        if q < 1 || q > 6 || s < 1 || s > 2
            uiLog("error", "підчерга має бути від 1.1 до 6.2")
        elif iv < INTERVAL_MIN || iv > INTERVAL_MAX
            uiLog("error", "інтервал має бути від " .. str(INTERVAL_MIN) .. " до " .. str(INTERVAL_MAX) .. " хвилин")
        elif chn < 0 || chn > 100
            uiLog("error", "канал ISC має бути від 0 до 100")
        else
            var changed = q != queue || s != sub
            queue = q
            sub = s
            interval = iv
            iscCh = chn
            enabled = cmd.find("enabled", enabled) == true
            if cmd.contains("addr")
                addr = cmd["addr"]
                listsSave()
            end
            if cfgSave() uiLog("info", "налаштування збережено") end
            claimChannel()
            if changed lastMsg = nil end
            nextRun = SLZB.millis()      # parse right away with the new settings
        end

    elif c == "parse"
        runParse()
    end

    uiStatus()
end

# ---------------------------------------------------------------- main
cfgLoad()
listsLoad()
claimChannel()
nextRun = SLZB.millis() + 10000          # first parse shortly after the start (network, time)
var lastStatus = 0

while true
    var payload = BEAPP.receive(ch, 1000)

    if payload != nil
        var m = json.load(payload)
        if m == nil
            # nothing
        elif m["event"] == "open"
            uiOpen = true
            uiStatus()
        elif m["event"] == "close"
            uiOpen = false
        elif m["event"] == "msg"
            handleCmd(json.load(str(m["data"])))
        end
    end

    var now = SLZB.millis()
    if enabled && queue > 0 && now - nextRun >= 0 && NETWORK.isReady()
        runParse()
    end
    if uiOpen && now - lastStatus >= 5000
        lastStatus = now
        uiStatus()
    end
end
