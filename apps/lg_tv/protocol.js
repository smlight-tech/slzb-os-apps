/* SPDX-License-Identifier: MIT */
"use strict";

const LgPairProtocol = (() => {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder("utf-8", { fatal: true });
    const chunkSize = 256;
    const maxMessage = 16384;
    const closed = 1;
    const sendRecord = 2;
    const receiveRecord = 4;
    const sendApp = 8;
    const receiveApp = 16;

    function random(size) {
        return crypto.getRandomValues(new Uint8Array(size));
    }

    function hex(bytes) {
        return Array.from(bytes, value => value.toString(16).padStart(2, "0")).join("");
    }

    function unhex(value) {
        if (typeof value !== "string" || value.length % 2 || /[^0-9a-f]/i.test(value)) {
            throw new Error("Invalid binary encoding");
        }
        return Uint8Array.from(value.match(/../g) ?? [], byte => parseInt(byte, 16));
    }

    function append(first, second, limit) {
        if (first.length + second.length > limit) throw new Error("Maximum message size exceeded");
        const result = new Uint8Array(first.length + second.length);
        result.set(first);
        result.set(second, first.length);
        return result;
    }

    class TlsStream {
        constructor(wasm, exchange, pin) {
            this.wasm = wasm;
            this.exchange = exchange;
            this.incoming = new Uint8Array();
            this.plaintext = new Uint8Array();
            wasm.HEAPU8.set(random(32), wasm._tls_entropy());
            if (pin) {
                const expected = unhex(pin);
                if (expected.length !== 32) throw new Error("Invalid certificate fingerprint");
                wasm.HEAPU8.set(expected, wasm._tls_expected_pin());
            }
            if (!wasm._tls_init(Boolean(pin))) this.fail();
        }

        fail() {
            const code = this.wasm._tls_error();
            throw new Error(code === 62 ? "TV certificate fingerprint changed" : "TLS ended (" + code + ")");
        }

        async pump(stop) {
            const wasm = this.wasm;
            for (;;) {
                const state = wasm._tls_state();
                if (state & closed) this.fail();
                if (state & receiveApp) {
                    const offset = wasm._tls_buffer(receiveApp);
                    const length = wasm._tls_size();
                    this.plaintext = append(this.plaintext, wasm.HEAPU8.subarray(offset, offset + length), 32768);
                    wasm._tls_ack(receiveApp, length);
                }
                if (!(state & sendRecord) && stop(state)) return;
                if (state & sendRecord) {
                    const offset = wasm._tls_buffer(sendRecord);
                    const length = Math.min(wasm._tls_size(), chunkSize);
                    const received = await this.exchange(wasm.HEAPU8.slice(offset, offset + length));
                    wasm._tls_ack(sendRecord, length);
                    this.incoming = append(this.incoming, received, 32768);
                    continue;
                }
                if (!(state & receiveRecord)) throw new Error("Unexpected TLS state");
                if (this.incoming.length === 0) {
                    this.incoming = await this.exchange(new Uint8Array());
                    continue;
                }
                const offset = wasm._tls_buffer(receiveRecord);
                const length = Math.min(this.incoming.length, wasm._tls_size());
                wasm.HEAPU8.set(this.incoming.subarray(0, length), offset);
                wasm._tls_ack(receiveRecord, length);
                this.incoming = this.incoming.subarray(length);
            }
        }

        async connect() {
            await this.pump(state => state & sendApp);
            const fingerprint = this.wasm._tls_peer_pin();
            this.pin = hex(this.wasm.HEAPU8.subarray(fingerprint, fingerprint + 32));
        }

        async write(bytes) {
            while (bytes.length) {
                await this.pump(state => state & sendApp);
                const offset = this.wasm._tls_buffer(sendApp);
                const length = Math.min(bytes.length, this.wasm._tls_size());
                this.wasm.HEAPU8.set(bytes.subarray(0, length), offset);
                this.wasm._tls_ack(sendApp, length);
                bytes = bytes.subarray(length);
            }
            await this.pump(state => state & sendApp);
        }

        async read() {
            await this.pump(() => this.plaintext.length > 0);
            const ready = this.plaintext;
            this.plaintext = new Uint8Array();
            return ready;
        }
    }

    class WebSocketStream {
        constructor(tls) {
            this.tls = tls;
            this.bytes = new Uint8Array();
        }

        async connect(host) {
            await this.tls.connect();
            const nonce = btoa(String.fromCharCode(...random(16)));
            const wasm = this.tls.wasm;
            wasm.HEAPU8.set(encoder.encode(nonce), wasm._tls_websocket_nonce());
            const digest = wasm._tls_websocket_digest();
            const accept = btoa(String.fromCharCode(...wasm.HEAPU8.subarray(digest, digest + 20)));
            const request = [
                "GET / HTTP/1.1", "Host: " + host + ":3001", "Upgrade: websocket",
                "Connection: Upgrade", "Sec-WebSocket-Key: " + nonce, "Sec-WebSocket-Version: 13", "", ""
            ];
            await this.tls.write(encoder.encode(request.join("\r\n")));

            for (;;) {
                const end = this.bytes.findIndex((value, index, bytes) =>
                    value === 13 && bytes[index + 1] === 10 && bytes[index + 2] === 13 && bytes[index + 3] === 10);
                if (end >= 0 && end <= 8192) {
                    const [status, ...rows] = decoder.decode(this.bytes.subarray(0, end)).split("\r\n");
                    const headers = Object.create(null);
                    for (const row of rows) {
                        const colon = row.indexOf(":");
                        if (colon < 1) throw new Error("Invalid WebSocket upgrade header");
                        const field = row.slice(0, colon).toLowerCase();
                        const value = row.slice(colon + 1).trim();
                        headers[field] = headers[field] ? headers[field] + "," + value : value;
                    }
                    if (!/^HTTP\/1\.1 101(?: |$)/.test(status) || headers.upgrade?.toLowerCase() !== "websocket" ||
                        !headers.connection?.toLowerCase().split(",").some(value => value.trim() === "upgrade") ||
                        headers["sec-websocket-accept"] !== accept || headers["sec-websocket-extensions"] ||
                        headers["sec-websocket-protocol"] || headers["content-length"] || headers["transfer-encoding"]) {
                        throw new Error("Invalid WebSocket upgrade");
                    }
                    this.bytes = this.bytes.subarray(end + 4);
                    return;
                }
                if (this.bytes.length > 8192) throw new Error("WebSocket headers too large");
                await this.fill(this.bytes.length + 1);
            }
        }

        async fill(size) {
            while (this.bytes.length < size) {
                this.bytes = append(this.bytes, await this.tls.read(), 32768);
            }
        }

        async sendFrame(opcode, payload) {
            if (payload.length > maxMessage) throw new Error("Maximum message size exceeded");
            const maskOffset = payload.length < 126 ? 2 : 4;
            const frame = new Uint8Array(maskOffset + 4 + payload.length);
            frame[0] = 0x80 | opcode;
            frame[1] = 0x80 | (maskOffset === 2 ? payload.length : 126);
            if (maskOffset === 4) new DataView(frame.buffer).setUint16(2, payload.length);
            const mask = random(4);
            frame.set(mask, maskOffset);
            payload.forEach((value, index) => {
                frame[maskOffset + 4 + index] = value ^ mask[index % 4];
            });
            await this.tls.write(frame);
        }

        async send(message) {
            await this.sendFrame(1, encoder.encode(JSON.stringify(message)));
        }

        async receive() {
            let message = null;
            for (;;) {
                await this.fill(2);
                const first = this.bytes[0];
                const opcode = first & 15;
                const fin = (first & 128) !== 0;
                let length = this.bytes[1] & 127;
                let offset = 2;
                if ((first & 112) || (this.bytes[1] & 128) || length === 127 ||
                    (opcode >= 8 && (!fin || length > 125))) throw new Error("Invalid WebSocket frame");
                if (length === 126) {
                    await this.fill(4);
                    length = (this.bytes[2] << 8) | this.bytes[3];
                    offset = 4;
                    if (length < 126) throw new Error("Noncanonical WebSocket length");
                }
                if (length > maxMessage) throw new Error("Maximum message size exceeded");
                await this.fill(offset + length);
                const part = this.bytes.subarray(offset, offset + length);
                this.bytes = this.bytes.subarray(offset + length);
                if (opcode === 8) throw new Error("TV closed the WebSocket");
                if (opcode === 9) await this.sendFrame(10, part);
                else if (opcode !== 10) {
                    if ((message === null && opcode !== 1) || (message !== null && opcode !== 0)) {
                        throw new Error("Unsupported WebSocket frame");
                    }
                    message = message === null ? part : append(message, part, maxMessage);
                    if (fin) return JSON.parse(decoder.decode(message));
                }
            }
        }
    }

    async function register(socket, onPrompt, existingKey) {
        const id = "register_0";
        const payload = {
            forcePairing: false,
            pairingType: "PROMPT",
            manifest: {
                manifestVersion: 1,
                appVersion: "1.1",
                permissions: [
                    "CONTROL_POWER", "CONTROL_AUDIO", "CONTROL_INPUT_TV",
                    "LAUNCH", "WRITE_NOTIFICATION_TOAST"
                ]
            }
        };
        if (existingKey) payload["client-key"] = existingKey;
        await socket.send({type: "register", id, payload});
        for (;;) {
            const reply = await socket.receive();
            if (reply?.id !== id) continue;
            if (reply.type === "error") throw new Error("TV rejected registration");
            if (reply.type === "response" && reply.payload?.pairingType === "PROMPT") {
                if (existingKey) throw new Error("TV requested approval again");
                onPrompt();
            }
            if (reply.type !== "registered") continue;
            const key = reply.payload?.["client-key"];
            if (typeof key !== "string" || !/^[\x21-\x7e]{1,256}$/.test(key)) {
                throw new Error("Registered reply contained no valid key");
            }
            return key;
        }
    }

    return { TlsStream, WebSocketStream, register, random, hex, unhex, chunkSize };
})();

if (typeof module === "object") module.exports = LgPairProtocol;
