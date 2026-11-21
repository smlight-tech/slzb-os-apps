/* SPDX-License-Identifier: MIT */
"use strict";

const get = id => document.getElementById(id);
const report = message => { get("status").textContent = message; };
const protocol = LgPairProtocol;
const defaults = {host: "", mac: "", request: 60, result: 61, lock: 62};
const messages = {
    channel_busy: "A selected command or result channel is already in use. Choose different channels.",
    expired: "The request expired before it was sent.",
    forget_first: "Forget the previous pairing before pairing again or changing the TV IP address.",
    http_busy: "Another script is using the shared HTTP client. Try again when it releases the connection.",
    invalid_config: "Enter a private IPv4 address, the TV’s Wi-Fi MAC address, and three distinct channels from 0 to 100.",
    invalid_request: "Check the command value and try again.",
    invalid_exchange: "Pairing received an unexpected message. Try again.",
    invalid_registration: "The TV did not return a usable registration. Try pairing again.",
    network_unavailable: "The coordinator network is unavailable.",
    not_configured: "Save your TV’s settings first.",
    not_paired: "Pair the TV first.",
    pairing_busy: "A pairing session is already in progress.",
    pairing_failed: "The app could not complete pairing. Try again.",
    pairing_timeout: "Pairing timed out. Try again with the TV on.",
    permissions_required: "Use Update pairing in Setup and approve it on the TV.",
    duplicate: "This request was already handled. Check the TV before sending another.",
    queue_busy: "The app is busy. Try again in a moment.",
    storage_failed: "The coordinator could not save or remove the settings.",
    storage_uncertain: "Could not confirm the saved pairing. Reopen this page to check it before trying again.",
    transport_failed: "The coordinator could not submit the command.",
    tv_disconnected: "The TV closed the connection. Check that it is on and try again.",
    tv_unreachable: "Could not reach the TV. Check that it is on and that its IP address is correct.",
    upgrade_failed: "The TV did not accept the control connection. Check that it is on."
};
let ready = false;
let configured = false;
let paired = false;
let expanded = false;
let active = null;
let pending = null;

function renderControls() {
    const locked = !ready || Boolean(active);
    get("settings-fields").disabled = locked;
    get("pair").textContent = expanded ? "Paired" : paired ? "Update pairing" : "Pair";
    get("pair").disabled = locked || !configured || expanded;
    get("forget").disabled = locked || !configured;
    get("cancel").hidden = active?.type !== "pair" || Boolean(active.saving);
    get("power-controls").disabled = locked || !configured;
    get("on").disabled = locked || !configured;
    get("off").disabled = locked || !paired;
    for (const group of ["audio", "input", "launch", "notify"]) {
        get(`${group}-controls`).disabled = locked || !expanded;
    }
    get("test-help").textContent = !configured ? "Save your TV settings in Setup to get started." :
        !paired ? "Pair the TV in Setup to enable Off and the other controls." :
        !expanded ? messages.permissions_required : "Send one command at a time and watch the TV for the result.";
}

BeApp.onMessage(raw => {
    if (!pending) return;
    let message;
    try { message = JSON.parse(raw); } catch { return; }
    if (message?.sid !== pending.sid) return;
    if (message.op === "error") pending.finish(new Error(messages[message.status] || "The app could not complete the action."));
    else if (message.op === pending.op && message.seq === pending.seq) pending.finish(null, message);
});

function ask(session, cmd, op, fields = {}, timeout = 5000) {
    if (session.abort.signal.aborted) throw new Error("Cancelled.");
    if (pending) throw new Error("An app request is already in progress.");
    return new Promise((resolve, reject) => {
        const finish = (error, value) => {
            if (pending?.finish !== finish) return;
            pending = null;
            clearTimeout(timer);
            session.abort.signal.removeEventListener("abort", cancelled);
            if (error) reject(error);
            else resolve(value);
        };
        const cancelled = () => finish(new Error("Cancelled."));
        const noReply = cmd === "save" ? messages.storage_uncertain :
            cmd === "test" ? "No result from the app. Check your TV before trying again." :
            "No reply from the app. Check that its backend is running.";
        const timer = setTimeout(() => finish(new Error(noReply)), timeout);
        pending = {sid: session.sid, op, seq: fields.seq, finish};
        session.abort.signal.addEventListener("abort", cancelled, {once: true});
        BeApp.sendMessage({cmd, sid: session.sid, ...fields}).catch(() => {
            finish(new Error(cmd === "save" || cmd === "test" ? noReply : "Could not contact the app backend."));
        });
    });
}

function closeSession(session) {
    if (session.saving) return;
    session.abort.abort();
    if (session.type === "pair") {
        BeApp.sendMessage({cmd: "close", sid: session.sid}).catch(() => {});
    }
}

function expectStatus(reply, expected) {
    if (reply.status !== expected) throw new Error(messages[reply.status] || "The app could not complete the action.");
}

async function run(type, action) {
    if (active) return;
    const session = {type, sid: protocol.hex(protocol.random(16)), abort: new AbortController()};
    active = session;
    renderControls();
    try {
        await action(session);
    } catch (error) {
        report(error.message);
    } finally {
        if (session.type === "pair") closeSession(session);
        active = null;
        renderControls();
    }
}

async function refresh(session, feedback = "") {
    const status = await ask(session, "status", "status");
    configured = Boolean(status.config);
    paired = status.paired === true;
    expanded = status.expanded === true;
    const settings = status.config || defaults;
    for (const name of Object.keys(defaults)) get(name).value = settings[name];
    renderBerryHelper(settings);
    if (session.type === "load") get("setup").open = !expanded || !status.channelsReady;
    if (configured && !status.channelsReady) {
        report("The script channels are in use. Choose free channels and save settings.");
    } else {
        const pairingStatus = expanded ? "Paired." :
            paired ? "Paired for power. Update pairing to enable the new TV commands." :
            configured ? "Ready to pair." : "Enter your TV’s settings.";
        report(feedback || pairingStatus);
    }
}

get("settings").addEventListener("submit", event => {
    event.preventDefault();
    void run("configure", async session => {
        const fields = {
            host: get("host").value.trim(),
            mac: get("mac").value.trim().replaceAll("-", ":"),
            request: get("request").valueAsNumber,
            result: get("result").valueAsNumber,
            lock: get("lock").valueAsNumber
        };
        expectStatus(await ask(session, "configure", "configure", fields), "saved");
        await refresh(session, "Settings saved.");
    });
});

async function connect(session, cmd, pin = null) {
    const opened = await ask(session, cmd, "open");
    let sequence = 0;
    const exchange = async bytes => {
        const reply = await ask(session, "step", "step", {
            seq: sequence++, tx: protocol.hex(bytes)
        });
        if (typeof reply.rx !== "string" || reply.rx.length > 2 * protocol.chunkSize) {
            throw new Error("The app received an invalid TLS record.");
        }
        return protocol.unhex(reply.rx);
    };
    const tls = new protocol.TlsStream(await createTls(), exchange, pin ?? opened.pin ?? null);
    const socket = new protocol.WebSocketStream(tls);
    await socket.connect(opened.host);
    return {socket, pin: tls.pin};
}

get("pair").addEventListener("click", () => {
    void run("pair", async session => {
        report("Connecting to the TV…");
        const timer = setTimeout(() => closeSession(session), 85000);
        try {
            const initial = await connect(session, paired ? "upgrade" : "open");
            const key = await protocol.register(initial.socket, () => report("Press Yes on the TV."));
            report("Verifying the TV registration…");
            const verified = await connect(session, "reopen", initial.pin);
            if (await protocol.register(verified.socket, () => {}, key) !== key) {
                throw new Error("The TV returned a different key during verification.");
            }
            clearTimeout(timer);
            session.saving = true;
            renderControls();
            report("Saving pairing…");
            expectStatus(await ask(session, "save", "save", {key, pin: verified.pin}), "paired");
            paired = true;
            expanded = true;
        } finally {
            clearTimeout(timer);
        }
        report("Paired. You can close this page and run TV commands from Berry.");
    });
});

function testResult(label, message) {
    get("test-result").textContent = `${label} · ${message}`;
}

function sendTest(action, label, value) {
    if (active || !ready) return;
    if (!configured) return testResult(label, messages.not_configured);
    if (action !== "on" && !paired) return testResult(label, messages.not_paired);
    if (action !== "on" && action !== "off" && !expanded) {
        return testResult(label, messages.permissions_required);
    }
    const fields = {action};
    if (value !== undefined) fields.value = value;
    get("berry-call").value = `tv_request("${action}"${value === undefined ? "" : `, ${JSON.stringify(value)}`})`;
    get("copy-status").textContent = "";
    void run("test", async session => {
        testResult(label, "Sending…");
        try {
            const {expires} = await ask(session, "prepare_test", "prepare_test");
            if (!Number.isInteger(expires) || expires < 0 || expires > 0x7fffffff) {
                throw new Error("The app did not supply a command deadline. Try again.");
            }
            expectStatus(await ask(session, "test", "test", {...fields, expires}, 18000), "submitted");
            testResult(label, action === "on" ? "Wake packet sent. Check your TV." : "Command submitted. Check your TV.");
        } catch (error) {
            testResult(label, error.message);
        }
    });
}

for (const [button, action, label, value] of [
    ["on", "on", "On"], ["off", "off", "Off"],
    ["volume-down", "volume_down", "Volume down"], ["volume-up", "volume_up", "Volume up"],
    ["mute", "mute", "Mute", true], ["unmute", "mute", "Unmute", false]
]) {
    get(button).addEventListener("click", () => sendTest(action, label, value));
}

get("volume-form").addEventListener("submit", event => {
    event.preventDefault();
    const volume = get("volume").valueAsNumber;
    if (!Number.isInteger(volume) || volume < 0 || volume > 100) {
        return testResult("Set volume", "Enter a whole number from 0 to 100.");
    }
    sendTest("volume", `Set volume to ${volume}`, volume);
});

for (const [action, label] of [["input", "Switch input"], ["launch", "Launch app"]]) {
    const preset = get(`${action}-preset`);
    const custom = get(`${action}-custom`);
    preset.addEventListener("change", () => {
        const showCustom = preset.value === "custom";
        get(`${action}-custom-field`).hidden = !showCustom;
        custom.disabled = !showCustom;
    });
    get(`${action}-form`).addEventListener("submit", event => {
        event.preventDefault();
        const value = preset.value === "custom" ? custom.value.trim() : preset.value;
        if (!/^[A-Za-z0-9_.-]{1,96}$/.test(value)) {
            return testResult(label, "Enter an ID with letters, digits, periods, underscores, or hyphens.");
        }
        // The tuner is a built-in app, not an external input ID.
        const liveTv = action === "input" && preset.value === "com.webos.app.livetv";
        sendTest(liveTv ? "launch" : action,
            liveTv ? "Live TV" : `${label} · ${value}`, value);
    });
}

get("notify-form").addEventListener("submit", event => {
    event.preventDefault();
    const value = get("notification").value.trim();
    if (!value || /[\x00-\x1f\x7f\uD800-\uDFFF]/u.test(value) || new TextEncoder().encode(value).length > 160) {
        return testResult("Notification", "Enter 1–160 UTF-8 bytes of plain text.");
    }
    sendTest("notify", "Notification", value);
});

function renderBerryHelper(settings) {
    get("berry-helper").value = LgBerryExample
        .replace(/^var command_channel = 60$/m, `var command_channel = ${settings.request}`)
        .replace(/^var result_channel = 61$/m, `var result_channel = ${settings.result}`);
}

for (const part of ["call", "helper"]) {
    get(`copy-${part}`).addEventListener("click", async () => {
        const field = get(`berry-${part}`);
        if (navigator.clipboard?.writeText) {
            try {
                await navigator.clipboard.writeText(field.value);
                get("copy-status").textContent = "Copied.";
                return;
            } catch {
                // The coordinator page may run in an HTTP iframe without clipboard permission.
            }
        }
        field.focus();
        field.select();
        get("copy-status").textContent = "Text selected. Use your device’s Copy command.";
    });
}

get("forget").addEventListener("click", () => {
    void run("forget", async session => {
        expectStatus(await ask(session, "forget", "forget"), "forgotten");
        await refresh(session, "Pairing removed from the coordinator.");
    });
});
get("cancel").addEventListener("click", () => { if (active?.type === "pair") closeSession(active); });
window.addEventListener("pagehide", () => { if (active) closeSession(active); });

renderBerryHelper(defaults);
Promise.all([BeApp.ready(), createTls()]).then(([info]) => {
    if (info.folder !== "lg_tv") throw new Error("Open LG TV from the coordinator’s Apps page.");
    protocol.random(16);
    ready = true;
    return run("load", refresh);
}).catch(error => report(error.message));
