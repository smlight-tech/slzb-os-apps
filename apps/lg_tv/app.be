# SPDX-License-Identifier: MIT
import BEAPP
import FS
import HTTP
import ISC
import NETWORK
import SLZB
import WOL
import json
import math
import string

var directory = "/beapps/lg_tv/"
var legacy_config_path = directory + ".settings.json"
var legacy_pairing_path = directory + ".pairing.json"
var pairing_path = directory + ".pairing-v2.json"
var pairing_marker = directory + ".pairing-v2.commit"
var ch = BEAPP.claim()
if !ch return end

var clock_mask = 0x7fffffff
var max_ttl = 15000
var config = nil
var config_slot = -1
var config_revision = 0
var credential = nil
var power_permissions = ["CONTROL_POWER"]
var control_permissions = ["CONTROL_POWER", "CONTROL_AUDIO", "CONTROL_INPUT_TV",
    "LAUNCH", "WRITE_NOTIFICATION_TOAST"]
var tv_endpoints = {
    "off":"system/turnOff", "volume":"audio/setVolume",
    "volume_up":"audio/volumeUp", "volume_down":"audio/volumeDown",
    "mute":"audio/setMute", "input":"tv/switchInput",
    "launch":"system.launcher/launch", "notify":"system.notifications/createToast"
}
var channels_ready = false
var seen_ids = []
var recent_limit = 32
var tcp = nil
var pairing_id = nil
var pairing_started = 0
var pairing_seq = 0
var pairing_pin = nil
var verifying = false
var pairing_timeout = 90000

def characters(text, alphabet, min_length, max_length)
    if type(text) != "string" || size(text) < min_length || size(text) > max_length
        return false
    end
    for i : 0 .. size(text) - 1
        if string.find(alphabet, text[i]) < 0 return false end
    end
    return true
end

def private_ip(host)
    if !characters(host, "0123456789.", 7, 15) return false end
    var parts = string.split(host, ".")
    if size(parts) != 4 return false end
    for part : parts
        if size(part) == 0 || size(part) > 3 || (size(part) > 1 && part[0] == "0")
            return false
        end
        if int(part) > 255 return false end
    end
    var first = int(parts[0])
    var second = int(parts[1])
    return first == 10 || (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168)
end

def mac_address(mac)
    if !characters(mac, "0123456789ABCDEFabcdef:", 17, 17) return nil end
    var parts = string.split(mac, ":")
    if size(parts) != 6 return nil end
    for part : parts
        if size(part) != 2 return nil end
    end
    var upper = string.toupper(mac)
    if upper == "00:00:00:00:00:00" || string.find("02468ACE", upper[1]) < 0
        return nil
    end
    return upper
end

def valid_channel(channel)
    return type(channel) == "int" && channel >= 0 && channel <= 100
end

def parse_config(data)
    if !isinstance(data, map) return nil end
    var host = data.find("host")
    var mac = mac_address(data.find("mac"))
    var request = data.find("request")
    var result = data.find("result")
    var lock = data.find("lock")
    if !private_ip(host) || mac == nil || !valid_channel(request) ||
        !valid_channel(result) || !valid_channel(lock) ||
        request == result || request == lock || result == lock
        return nil
    end
    return {"host":host, "mac":mac, "request":request, "result":result, "lock":lock}
end

def cleanup_file(file)
    if file == nil return end
    try
        file.close()
    except ..
        BEAPP.log("LG TV storage cleanup failed")
    end
end

def read_json(path)
    var file = nil
    try
        if !FS.exists(path) return nil end
        file = FS.open(path, "r")
        var raw = file.read(1025)
        file.close()
        file = nil
        if type(raw) == "string" && size(raw) <= 1024 return json.load(raw) end
    except ..
        cleanup_file(file)
    end
end

def write_json(path, data)
    var file = nil
    try
        var raw = json.dump(data)
        file = FS.open(path, "w")
        file.write(raw)
        file.close()
        file = nil
        file = FS.open(path, "r")
        var stored = file.read(size(raw) + 1)
        file.close()
        return stored == raw
    except ..
        cleanup_file(file)
        return false
    end
end

def remove_file(path)
    try
        if FS.exists(path) FS.deleteFile(path) end
        return !FS.exists(path)
    except ..
        return false
    end
end

def settings_prefix(slot)
    return directory + ".settings-" + str(slot)
end

def read_settings_slot(slot)
    var prefix = settings_prefix(slot)
    var committed = read_json(prefix + ".commit")
    if type(committed) != "int" || committed < 1 || committed > clock_mask return nil end
    var candidate = read_json(prefix + ".json")
    if !isinstance(candidate, map) || candidate.find("revision") != committed return nil end
    var settings = parse_config(candidate.find("settings"))
    if settings != nil return {"revision":committed, "settings":settings} end
end

def load_config()
    var selected = nil
    for slot : 0 .. 1
        var entry = read_settings_slot(slot)
        if entry != nil && entry["revision"] > config_revision
            selected = entry["settings"]
            config_revision = entry["revision"]
            config_slot = slot
        end
    end
    if selected != nil return selected end
    # Read installations that seed an initial configuration with the earlier format.
    return parse_config(read_json(legacy_config_path))
end

def store_config(settings)
    if config_revision == clock_mask return false end
    var slot = config_slot == 0 ? 1 : 0
    var generation = config_revision + 1
    var prefix = settings_prefix(slot)
    var marker = prefix + ".commit"
    # Leave the active slot intact. An interrupted or unverified candidate has
    # no commit marker and cannot be selected on restart.
    if !remove_file(marker) || !write_json(prefix + ".json", {
        "settings":settings, "revision":generation
    })
        return false
    end
    if !write_json(marker, generation)
        remove_file(marker)
        return false
    end
    config_slot = slot
    config_revision = generation
    return true
end

def valid_key(key)
    if type(key) != "string" || size(key) < 1 || size(key) > 256 return false end
    var encoded = bytes()
    encoded.fromstring(key)
    for i : 0 .. encoded.size() - 1
        var value = encoded.get(i)
        if value < 33 || value > 126 return false end
    end
    return true
end

def credential_at(path, profile)
    var data = read_json(path)
    if config != nil && isinstance(data, map) && data.find("host") == config["host"] &&
        valid_key(data.find("key")) && characters(data.find("pin"), "0123456789abcdef", 64, 64)
        data["profile"] = profile
        return data
    end
end

def load_credential()
    if read_json(pairing_marker) == 2
        var saved = credential_at(pairing_path, 2)
        if saved != nil return saved end
    end
    return credential_at(legacy_pairing_path, 1)
end

def pairing_exists()
    return FS.exists(legacy_pairing_path) || FS.exists(pairing_marker)
end

def expanded_pairing()
    return credential != nil && credential["profile"] == 2
end

def reply(kind, id, status)
    return BEAPP.send(ch, json.dump({"op":kind, "sid":id, "status":status})) == 1
end

def status_reply(id)
    return BEAPP.send(ch, json.dump({"op":"status", "sid":id,
        "config":config, "paired":credential != nil, "expanded":expanded_pairing(),
        "channelsReady":channels_ready})) == 1
end

def claim_channels(settings, previous)
    var request = settings["request"]
    var result = settings["result"]
    var new_request = previous == nil || request != previous["request"]
    var new_result = previous == nil || result != previous["result"]
    if new_request && !ISC.claim(request, ISC.CH_TYPE_PUBLIC) return false end
    if new_result && !ISC.claim(result, ISC.CH_TYPE_BROADCAST)
        if new_request ISC.release(request) end
        return false
    end
    return true
end

def release_channels(settings, retained)
    if settings == nil return end
    if retained == nil || settings["request"] != retained["request"]
        ISC.release(settings["request"])
    end
    if retained == nil || settings["result"] != retained["result"]
        ISC.release(settings["result"])
    end
end

def close_tcp()
    var socket = tcp
    tcp = nil
    if socket != nil
        try
            socket.close()
        except ..
            BEAPP.log("LG TV pairing socket cleanup failed")
        end
    end
end

def stop_pairing()
    pairing_id = nil
    pairing_pin = nil
    close_tcp()
end

def save_config(id, data)
    var settings = parse_config(data)
    if settings == nil
        reply("configure", id, "invalid_config")
        return
    end
    if config != nil && config["host"] != settings["host"] && pairing_exists()
        reply("configure", id, "forget_first")
        return
    end
    var previous = channels_ready ? config : nil
    if !claim_channels(settings, previous)
        reply("configure", id, "channel_busy")
        return
    end
    if !store_config(settings)
        release_channels(settings, previous)
        reply("configure", id, "storage_failed")
        return
    end
    stop_pairing()
    release_channels(previous, settings)
    config = settings
    channels_ready = true
    reply("configure", id, "saved")
end

def remaining(expires)
    return (expires - (SLZB.millis() & clock_mask)) & clock_mask
end

def is_live(expires)
    var left = remaining(expires)
    return left > 0 && left <= max_ttl
end

# Firmware exposes math.rand(), but no secure entropy source to Berry.
# These nonces and masks are protocol bytes, never authentication secrets.
def random_bytes(length)
    var output = bytes()
    for i : 1 .. length output.add((math.rand() >> 8) & 255) end
    return output
end

def frame_for(data)
    var payload = bytes()
    payload.fromstring(json.dump(data))
    var frame = bytes()
    var length = payload.size()
    frame.add(0x81)
    if length < 126
        frame.add(0x80 | length)
    else
        frame.add(0xfe)
        frame.add((length >> 8) & 255)
        frame.add(length & 255)
    end
    var mask = random_bytes(4)
    for i : 0 .. 3 frame.add(mask.get(i)) end
    for i : 0 .. length - 1 frame.add(payload.get(i) ^ mask.get(i % 4)) end
    return frame
end

def valid_notification(value)
    if type(value) != "string" || size(value) < 1 || size(value) > 160 return false end
    var encoded = bytes()
    encoded.fromstring(value)
    var position = 0
    while position < encoded.size()
        var lead = encoded.get(position)
        position += 1
        if lead < 0x80
            if lead < 32 || lead == 127 return false end
            continue
        end
        if lead < 0xc2 || lead > 0xf4 return false end
        var trailing = lead < 0xe0 ? 1 : lead < 0xf0 ? 2 : 3
        if position + trailing > encoded.size() return false end
        # The first continuation byte bounds overlong sequences, surrogates,
        # and code points above U+10FFFF.
        var first = encoded.get(position)
        if (lead == 0xe0 && first < 0xa0) || (lead == 0xed && first >= 0xa0) ||
            (lead == 0xf0 && first < 0x90) || (lead == 0xf4 && first > 0x8f)
            return false
        end
        for offset : 0 .. trailing - 1
            var continuation = encoded.get(position + offset)
            if continuation < 0x80 || continuation > 0xbf return false end
        end
        position += trailing
    end
    return true
end

def tv_request(action, value)
    var endpoint = tv_endpoints.find(action)
    if endpoint == nil return nil end
    var request = {"id":"tv_command", "type":"request", "uri":"ssap://" + endpoint}
    if action == "volume"
        if type(value) != "int" || value < 0 || value > 100 return nil end
        request["payload"] = {"volume":value}
    elif action == "mute"
        if type(value) != "bool" return nil end
        request["payload"] = {"mute":value}
    elif action == "input" || action == "launch"
        if !characters(value, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-", 1, 96)
            return nil
        end
        if action == "input"
            request["payload"] = {"inputId":value}
        else
            request["payload"] = {"id":value}
        end
    elif action == "notify"
        if !valid_notification(value) return nil end
        request["payload"] = {"message":value}
    elif value != nil
        return nil
    end
    return request
end

def send_tv_frames(request, expires)
    if !HTTP.setHeader("Upgrade", "websocket") || !HTTP.setHeader("Connection", "Upgrade") ||
        !HTTP.setHeader("Sec-WebSocket-Version", "13") ||
        !HTTP.setHeader("Sec-WebSocket-Key", random_bytes(16).tob64())
        return "transport_failed"
    end
    HTTP.completeStreamConfig()
    if HTTP.perform() != 101 return "upgrade_failed" end
    if !is_live(expires) return "expired" end
    var permissions = expanded_pairing() ? control_permissions : power_permissions
    HTTP.streamWriteBytes(frame_for({"id":"register_0", "type":"register", "payload":{
        "forcePairing":false, "pairingType":"PROMPT", "client-key":credential["key"],
        "manifest":{"manifestVersion":1, "appVersion":"1.1", "permissions":permissions}
    }}))
    # The firmware cannot read normal upgraded-stream responses. Give the TV
    # time to process registration, then submit without claiming confirmation.
    SLZB.delay(800)
    if !is_live(expires) return "expired" end
    HTTP.streamWriteBytes(frame_for(request))
    SLZB.delay(1000)
    return "submitted"
end

def send_tv(request, expires)
    var lock = config["lock"]
    if !ISC.claim(lock, ISC.CH_TYPE_PRIVATE) return "http_busy" end
    var owned = false
    var status = "transport_failed"
    try
        if HTTP.isOpened()
            status = "http_busy"
        elif !is_live(expires)
            status = "expired"
        else
            owned = HTTP.open("https://" + config["host"] + ":3001/", "get", 0, true)
            if owned status = send_tv_frames(request, expires) end
        end
    except ..
        status = "transport_failed"
    end
    if owned
        try
            HTTP.close()
        except ..
            # Report an uncertain result and leave the client for inspection.
            status = "transport_failed"
        end
    end
    ISC.release(lock)
    return status
end

def execute(action, value, expires)
    if config == nil return "not_configured" end
    if !is_live(expires) return "expired" end
    if pairing_id != nil return "pairing_busy" end
    try
        if action == "on"
            if value != nil return "invalid_request" end
            return WOL.wake(config["mac"]) ? "submitted" : "transport_failed"
        end
        var request = tv_request(action, value)
        if request == nil return "invalid_request" end
        if credential == nil return "not_paired" end
        if action != "off" && !expanded_pairing() return "permissions_required" end
        return send_tv(request, expires)
    except ..
        return "transport_failed"
    end
end

def run_request(action, value, id, expires)
    if !is_live(expires) return "expired" end
    var i = size(seen_ids) - 1
    while i >= 0
        var entry = seen_ids[i]
        if !is_live(entry["expires"])
            seen_ids.pop(i)
        elif entry["id"] == id
            return "duplicate"
        end
        i -= 1
    end
    if size(seen_ids) >= recent_limit return "queue_busy" end
    seen_ids.push({"id":id, "expires":expires})
    return execute(action, value, expires)
end

def start_requests()
    config = load_config()
    if config != nil channels_ready = claim_channels(config, nil) end
    credential = load_credential()
end

def valid_expiry(expires)
    return type(expires) == "int" && expires >= 0 && expires <= clock_mask
end

def consume(raw)
    if type(raw) != "string" || size(raw) > 1152 return end
    var data = json.load(raw)
    if !isinstance(data, map) return end
    var id = data.find("id")
    if !characters(id, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-", 1, 48)
        return
    end
    var action = data.find("action")
    var expires = data.find("expires")
    var status = "invalid_request"
    if data.find("v") == 1 && type(action) == "string" && valid_expiry(expires)
        status = run_request(action, data.find("value"), id, expires)
    end
    ISC.send(config["result"], json.dump({"v":1, "id":id, "status":status}))
end

def pair_error(id, status)
    stop_pairing()
    reply("error", id, status)
end

def connect_pair(id)
    if !NETWORK.isReady()
        pair_error(id, "network_unavailable")
        return
    end
    tcp = TCP_CLIENT()
    if !tcp.connect(config["host"], 3001, 2500)
        pair_error(id, "tv_unreachable")
        return
    end
    pairing_seq = 0
    var opened = {"op":"open", "sid":id, "host":config["host"]}
    if pairing_pin != nil opened["pin"] = pairing_pin end
    if BEAPP.send(ch, json.dump(opened)) != 1
        stop_pairing()
    end
end

def open_pair(id, upgrade)
    if pairing_id != nil
        reply("error", id, "pairing_busy")
    elif config == nil
        reply("error", id, "not_configured")
    elif upgrade && credential == nil
        reply("error", id, "not_paired")
    elif expanded_pairing() || (!upgrade && pairing_exists())
        reply("error", id, "forget_first")
    else
        pairing_id = id
        pairing_pin = upgrade ? credential["pin"] : nil
        pairing_started = SLZB.millis() & clock_mask
        verifying = false
        connect_pair(id)
    end
end

def pair_step(data, id)
    var tx_text = data.find("tx")
    if data.find("seq") != pairing_seq || type(tx_text) != "string" || size(tx_text) % 2 != 0 ||
        (tx_text != "" && !characters(tx_text, "0123456789abcdef", 2, 512))
        pair_error(id, "invalid_exchange")
        return
    end
    if tx_text != ""
        var tx = bytes(tx_text)
        if tcp.write(tx) != tx.size()
            pair_error(id, "tv_disconnected")
            return
        end
    end
    var rx = ""
    if tcp.waitAvailable(35) > 0 rx = tcp.readBytes(256).tohex() end
    if rx == "" && !tcp.connected()
        pair_error(id, "tv_disconnected")
        return
    end
    var result = {"op":"step", "sid":id, "seq":pairing_seq, "rx":rx}
    pairing_seq += 1
    if BEAPP.send(ch, json.dump(result)) != 1 stop_pairing() end
end

def save_pairing(id, data)
    var key = data.find("key")
    var pin = data.find("pin")
    if !verifying || pairing_seq == 0 || !valid_key(key) ||
        !characters(pin, "0123456789abcdef", 64, 64) || (pairing_pin != nil && pin != pairing_pin)
        pair_error(id, "invalid_registration")
        return
    end
    stop_pairing()
    var saved = {"host":config["host"], "key":key, "pin":pin, "profile":2}
    # A separate record preserves the previous power-only pairing until the
    # new key has been verified on the TV and committed on the coordinator.
    if !remove_file(pairing_marker) || !write_json(pairing_path, saved)
        reply("error", id, "storage_failed")
        return
    end
    if !write_json(pairing_marker, 2)
        if remove_file(pairing_marker) || remove_file(pairing_path)
            reply("error", id, "storage_failed")
        else
            # The marker may have reached disk despite the failed readback.
            # Match the normal startup selection when it can be read again.
            var recovered = load_credential()
            if recovered != nil credential = recovered end
            reply("error", id, "storage_uncertain")
        end
        return
    end
    credential = saved
    reply("save", id, "paired")
end

def forget(id)
    stop_pairing()
    if !remove_file(legacy_pairing_path) || !remove_file(pairing_marker)
        reply("forget", id, "storage_failed")
        return
    end
    credential = nil
    if !remove_file(pairing_path)
        reply("forget", id, "storage_failed")
        return
    end
    reply("forget", id, "forgotten")
end

def accept(data)
    if !isinstance(data, map) return end
    var id = data.find("sid")
    if !characters(id, "0123456789abcdef", 32, 32) return end
    var cmd = data.find("cmd")
    if cmd == "status"
        status_reply(id)
    elif cmd == "configure"
        save_config(id, data)
    elif cmd == "prepare_test"
        # Stamp a deadline before the browser queues the command, so a slow
        # coordinator cannot give a stale request a fresh lifetime.
        BEAPP.send(ch, json.dump({"op":"prepare_test", "sid":id,
            "expires":(SLZB.millis() + max_ttl) & clock_mask}))
    elif cmd == "test"
        var action = data.find("action")
        var expires = data.find("expires")
        var status = "invalid_request"
        if type(action) == "string" && valid_expiry(expires)
            status = run_request(action, data.find("value"), "ui-" + id, expires)
        end
        reply("test", id, status)
    elif cmd == "forget"
        forget(id)
    elif cmd == "open" || cmd == "upgrade"
        open_pair(id, cmd == "upgrade")
    elif pairing_id != nil && pairing_id == id
        if cmd == "close"
            stop_pairing()
        elif cmd == "step"
            pair_step(data, id)
        elif cmd == "reopen" && !verifying && pairing_seq > 0
            close_tcp()
            verifying = true
            connect_pair(id)
        elif cmd == "save"
            save_pairing(id, data)
        end
    end
end

def accept_event(raw)
    var event = json.load(raw)
    if !isinstance(event, map) return end
    if event.find("event") == "close"
        stop_pairing()
    elif event.find("event") == "msg"
        var data = event.find("data")
        if type(data) == "string" && size(data) <= 1100 accept(json.load(data)) end
    end
end

start_requests()
while true
    var raw = BEAPP.receive(ch, 100)
    try
        if pairing_id != nil &&
            (((SLZB.millis() & clock_mask) - pairing_started) & clock_mask) >= pairing_timeout
            pair_error(pairing_id, "pairing_timeout")
        end
        if raw != nil accept_event(raw) end
        if channels_ready
            var request = ISC.receive(config["request"], 0)
            if request != nil consume(request) end
        end
    except ..
        if pairing_id != nil pair_error(pairing_id, "pairing_failed") end
        BEAPP.log("LG TV rejected an operation")
    end
end
