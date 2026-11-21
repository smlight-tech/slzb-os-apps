# LG TV Control

Independent project; not affiliated with, endorsed by, or sponsored by LG Electronics. LG is a trademark of its respective owner.

Control one LG webOS TV from Berry scripts running on this coordinator. Pair here, then close the browser. Scripts can turn the TV on or off, change volume or mute, switch inputs, launch installed apps, and show notifications.

**Compatibility:** SLZB-MR4U with SLZB-OS v3.4.5.dev1 or later. Core controls were tested on an LG GX connected over Wi-Fi. Input and app availability varies by TV.

## Shared HTTP requirement

**Off, audio, inputs, app launches, and notifications need exclusive or cooperative access to the coordinator's single shared HTTP client.** On uses Wake-on-LAN and works independently of HTTP.

If another script holds the lock or has HTTP open, the LG TV app reports `http_busy` and leaves that connection alone. A lighting script that keeps its HTTP connection open can keep these commands busy indefinitely. Turning off **Run on boot** only affects the next restart. Use **Stop** to stop a running script. Stopping a script can leave the client open, so check the owning script's shutdown behavior before testing again.

For scripts to use HTTP together, every HTTP user must claim the same private ISC channel before opening or changing HTTP. Use the app's **HTTP lock** setting, which defaults to channel **62**. Once the lock is held, defer if HTTP is already open. Each script closes the connection it opened before releasing the claim. Checking `HTTP.isOpened()` alone cannot stop an uncoordinated script from opening the client at the same time. [HTTP sharing guide](https://github.com/joelbaby/slzb-lg-tv/blob/5a9c85e2a5abc1fca7eb9cc2c094fac7c21721e9/docs/berry-control.md#sharing-http)

## Pair and test

1. Save the TV's IP address and Wi-Fi MAC address.
2. Keep the app open in one tab for pairing. With the TV on, click **Pair** and select **Yes** on the TV.
3. If you paired with an earlier version that only controlled power, click **Update pairing** and approve the new permissions on the TV.
4. Enable **Start on boot** for the app backend so it can receive commands after a coordinator reboot.

Use **Test your TV** to send one command and check its effect. A `submitted` result means the coordinator sent the wake packet or submitted the command. The app cannot confirm that the TV accepted it or read reliable power state. On requires network wake support and the right standby settings on the TV.

## Call from Berry

Open **Use this in Berry** after testing a command. Copy the helper into your script once, then copy the matching call, such as `tv_request("off")`. The helper uses your configured command and result channels and checks for results in a timer. Leave the backend running. You can close the app page.

## Network and source

Use a trusted local network and protect access to the coordinator's management interface. The browser holds the key briefly during pairing and sends it to the coordinator over the unencrypted HTTP management bridge. The coordinator stores the key for future commands. The pairing page keeps no persistent copy. The bundled TLS client verifies the same TV certificate on both pairing connections. Later commands use the firmware's native HTTPS API, which does not verify the TV certificate. [Credential and transport details](https://github.com/joelbaby/slzb-lg-tv/blob/5a9c85e2a5abc1fca7eb9cc2c094fac7c21721e9/docs/berry-control.md#credentials-and-transport)

MIT licensed. [Published runtime source and build instructions](https://github.com/joelbaby/slzb-lg-tv/tree/5a9c85e2a5abc1fca7eb9cc2c094fac7c21721e9) · [Berry examples](https://github.com/joelbaby/slzb-lg-tv/blob/5a9c85e2a5abc1fca7eb9cc2c094fac7c21721e9/examples/README.md)
