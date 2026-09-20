# TCP Tools — Berry backend.
#
# Demonstrates the TCP_SERVER / TCP_CLIENT classes driven from an app web UI:
#   - a TCP server: listens on a user-chosen port, logs every connection,
#     forwards received data to the page; messages typed on the page are
#     sent to every connected client;
#   - an interactive client: connect / send / disconnect from the page.
#
# The server keeps working while the app UI is closed (check the app Log) —
# page updates are only sent while the UI is open. All TCP instances are
# destroyed automatically when the script stops.
#
# UI -> backend (BeApp.sendMessage, JSON string):
#   {"cmd":"srv_start","port":4000}   {"cmd":"srv_stop"}
#   {"cmd":"srv_send","data":"..."}   (to all connected clients)
#   {"cmd":"cln_connect","host":"192.168.1.50","port":9100}
#   {"cmd":"cln_send","data":"..."}   {"cmd":"cln_close"}   {"cmd":"status"}
#
# backend -> UI (BEAPP.send -> BeApp.onMessage, JSON string):
#   {"type":"status",...}  {"type":"log","scope":"srv"|"cln","text":...}
#   {"type":"srv_rx","from":ip,"data":...}  {"type":"cln_rx","data":...}

import BEAPP
import SLZB
import NETWORK
import json

NETWORK.waitReady(0xff)

var ch = BEAPP.claim()
if ch == 0
    SLZB.log("no free app channel, exiting")
    return
end

BEAPP.setLogSize(8192)
BEAPP.log("TCP Tools backend started, IP " .. NETWORK.getIp())

var uiOpen = false
var srv = nil            # TCP_SERVER while running
var srvPort = 0
var clients = []         # accepted TCP_CLIENT instances
var clientIps = []       # their IPs, cached at accept (remoteIp() is gone after a disconnect)
var cln = TCP_CLIENT()   # the outgoing connection
var clnPeer = ""
var clnWasUp = false

def uiSend(m)
    if uiOpen BEAPP.send(ch, json.dump(m)) end
end

# scope: "srv" or "cln" - which card's log the line belongs to on the page
def uiLog(scope, text)
    BEAPP.log(text)
    uiSend({"type": "log", "scope": scope, "text": text})
end

def uiStatus()
    uiSend({
        "type": "status",
        "srv": srv != nil, "srvPort": srvPort, "srvClients": clients.size(),
        "cln": cln.connected(), "clnPeer": clnPeer,
        "ip": NETWORK.getIp()
    })
end

def srvStop()
    for c: clients c.close() end
    clients = []
    clientIps = []
    if srv != nil
        srv.close()
        srv = nil     # the instance is freed by the GC
        uiLog("srv", "server stopped")
    end
end

def handleCmd(cmd)
    if cmd == nil return end

    if cmd["cmd"] == "srv_start"
        srvStop()
        try
            srv = TCP_SERVER(int(cmd["port"]))
            srvPort = int(cmd["port"])
            uiLog("srv", "server listening on " .. NETWORK.getIp() .. ":" .. str(srvPort))
        except .. as e, m
            srv = nil
            uiLog("srv", "server start failed: " .. str(m))
        end

    elif cmd["cmd"] == "srv_stop"
        srvStop()

    elif cmd["cmd"] == "srv_send"
        var sentTo = 0
        for c: clients
            if c.connected() && c.write(str(cmd["data"])) > 0
                sentTo += 1
            end
        end
        if sentTo == 0 uiLog("srv", "send failed: no connected clients") end

    elif cmd["cmd"] == "cln_connect"
        clnPeer = str(cmd["host"]) .. ":" .. str(cmd["port"])
        if cln.connect(str(cmd["host"]), int(cmd["port"]), 3000)
            uiLog("cln", "connected to " .. clnPeer)
        else
            uiLog("cln", "connect to " .. clnPeer .. " failed")
            clnPeer = ""
        end

    elif cmd["cmd"] == "cln_send"
        var sent = cln.write(str(cmd["data"]))
        if sent == 0 uiLog("cln", "send failed: not connected") end

    elif cmd["cmd"] == "cln_close"
        cln.close()
        uiLog("cln", "client connection closed")
    end

    uiStatus()
end

while true
    # commands / lifecycle from the page; the 100 ms timeout doubles as the TCP poll tick
    var payload = BEAPP.receive(ch, 100)

    if payload != nil
        var m = json.load(payload)

        if m == nil
            # nothing

        elif m["event"] == "open"
            uiOpen = true
            uiStatus()
            uiLog("srv", "UI opened")

        elif m["event"] == "close"
            uiOpen = false
            BEAPP.log("UI closed, server keeps running")

        elif m["event"] == "msg"
            handleCmd(json.load(str(m["data"])))
        end
    end

    # --- server: accept new connections, forward received data to the page ---
    if srv != nil
        var nc = srv.accept()
        if nc != nil
            clients.push(nc)
            clientIps.push(nc.remoteIp())
            uiLog("srv", "client connected: " .. nc.remoteIp())
            uiStatus()
        end

        var i = 0
        while i < clients.size()
            var c = clients[i]
            if !c.connected() && c.available() == 0
                uiLog("srv", "client disconnected: " .. clientIps[i])
                c.close()
                clients.remove(i)
                clientIps.remove(i)
                uiStatus()
                continue
            end
            if c.available() > 0
                uiSend({"type": "srv_rx", "from": clientIps[i], "data": c.read()})
            end
            i += 1
        end
    end

    # --- client: forward replies to the page ---
    if cln.available() > 0
        uiSend({"type": "cln_rx", "data": cln.read()})
    end
    if clnWasUp != cln.connected()
        clnWasUp = cln.connected()
        if !clnWasUp && clnPeer != ""
            uiLog("cln", "connection to " .. clnPeer .. " dropped")
            clnPeer = ""
        end
        uiStatus()
    end
end
