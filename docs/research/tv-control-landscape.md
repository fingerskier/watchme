# Smart TV control: platform research for watchme

*Snapshot date: 2026-10-21. This synthesizes nine research reports. Each report was adversarially fact-checked and corrected before synthesis.*

## How to read this document

- **Evidence.** Facts come from the reports, which cite primary sources: vendor docs, Chromium/Gecko/WebKit source, chromestatus, bug trackers, library source, and GitHub/PyPI/pub.dev metadata. Every report exhausted its web-search budget partway through, so some items rest on secondary sources. These are marked **(unverified)**, **(inference)** or **(weak source)**. **Nothing here was tested against real TVs.**
- **Capability ratings:** **Y** yes, **P** partial, **N** no, **?** unknown.
- **Browser ratings:**
  - **works** (qualified with known caveats where they exist)
  - **steps**: works after manual user steps
  - **write-only**: commands are sent but responses cannot be read
  - **blocked**
  - **unverified**
- **Two questions to keep apart.** "Can watchme have a web UI?" Always yes. "Can the browser itself speak the TV's protocol?" Rarely, and the answer depends on the transport and the browser. The rest of this document keeps the two separate.

## 1. Summary

1. **Native code can control nearly every platform surveyed.** This means `dart:io` in Flutter or a Dart hub, or Node. The hard parts are pairing quirks, firmware churn and OS permissions, not missing APIs. Exceptions: TiVo OS (no known local API), Xumo TVs (HomeKit power and input only; the official app protocol is undocumented), and Matter Casting without CSA attestation. Apple TV pairing is currently broken in the reference library.
2. **A browser page can speak only a few TV protocols directly, and which browsers work depends on the transport.**
   - http:// and ws:// to the LAN from an HTTPS page: Chromium only, after the Local Network Access prompt. Mostly write-only.
   - Self-signed wss://: Chromium and Firefox after certificate steps; Safari unverified.
   - Cloud HTTPS (SmartThings): every browser, with bring-your-own OAuth credentials.
   - Media casting: Cast Web Sender (Chromium) or AirPlay via Remote Playback (Safari).
   - Attached hardware from a secure context: Web Serial (USB-CEC, IR dongles) and Web Bluetooth (custom bridges).
   - In no browser can a page do discovery (SSDP/mDNS), Wake-on-LAN, raw TCP or TLS, TLS client certificates, or UDP.
3. **A web UI served by a LAN hub works for every platform that has a working native path, in every browser, including iOS Safari.** The hub does the protocol work behind a same-origin API.
4. **2026 was a year of breaking changes.** Drivers must probe each device at runtime and surface the device's raw error messages. Notable changes:
   - LG blacklisted the signed pairing manifest that open-source clients copied.
   - Some 2026 Samsung firmware silently refuses pairing.
   - A Google Play update broke Android TV app launch by package name.
   - Roku 14.1 made "Limited" mode the effective default.
   - SmartThings announced paid API tiers.
   - Chrome extended Local Network Access to WebSockets.
   - Android 17 added a runtime local-network permission.
   - tvOS 26/27 broke pyatv pairing.
5. **pub.dev has almost nothing usable.** watchme will write its own Dart drivers, porting from Apache, MIT and BSD references (mostly Home Assistant libraries and homebridge plugins). Several popular references are LGPL, GPL or AGPL and can only be read, not copied, by an Apache-2.0 project.

## 2. Hosting models

| Model | What it is | Who speaks the TV protocol |
|---|---|---|
| A. Public HTTPS static site (e.g. GitHub Pages) | The page talks to TVs directly | The browser; what it can reach depends on browser and transport (§3-4) |
| B. Plain-http page served from a LAN host, page talks to TVs | Same as A but hosted on the LAN | The browser |
| C. **LAN hub** serves the UI and a same-origin API | The page only talks to its own origin | The hub (native) |
| D. Desktop app serves the UI at `http://localhost` | Same as C on one machine; localhost is a secure context | The desktop process (native) |
| E. Isolated Web App + Direct Sockets | Raw TCP/UDP for "web" code | The browser, but only on Chrome-Enterprise-managed ChromeOS. Not a consumer channel. |
| F. Browser extension | `host_permissions` bypass CORS | The extension. Still no raw sockets or UDP. |
| G. Flutter web | Inherits the limits of whichever of A-D hosts it. `dart:io` does not exist on web. | Same as its host |

## 3. Browser platform constraints (October 2026)

### 3.1 Versions and behavior

| Topic | Chrome / Edge | Firefox | Safari and every iOS browser (WebKit) |
|---|---|---|---|
| Local Network Access prompt, public page to private IP | Since 142 (2025-10-28). Split into `local-network`/`loopback-network` in 145. WebSockets and WebTransport since 147 (2026-04-07). Temporary enterprise opt-out policy: chromestatus lists its removal at 156 (2026-10-20), but the policy definition on Chromium main still supports it and says it "will be removed after M163" (verified 2026-10-21). `LocalNetworkAccessIpAddressSpaceOverrides` (146+) remains either way. | Default for all desktop users in 153 (2026-07-21). WebSockets since 154 (2026-08-18). | None. `LocalNetworkAccessEnabled` is still default false. |
| HTTPS page to `http://` or `ws://` private IP | Allowed after the LNA grant, for private-IP literals, `.local`, or `targetAddressSpace` (fetch since 142, WebSocket since 154) | **Blocked** as mixed content. Only loopback is exempt (bug 2081728). No `targetAddressSpace`. | **Blocked**, even loopback (WebKit bug 171934) |
| HTTPS page to self-signed `wss://` or `https://` private IP | Not mixed content. Needs the LNA grant plus a certificate exception (below). | Not mixed content. Needs the LNA prompt plus a permanent certificate exception. | No LNA gate. Certificate-exception behaviour for wss unverified. |
| HTTPS page to a CORS-open cloud API (e.g. SmartThings) | Works (not LNA-gated, not mixed content) | Works | Works |
| Non-secure (http) public page to LAN | Blocked outright (the origin trial ended at 152) | Allowed behind a prompt "for now" (bug 2059274) | No LNA. CORS still applies. |
| LAN-served page to a LAN device (local to local) | Not gated (Chrome says it intends to extend LNA here later) | Not gated | Not gated |
| Self-signed certificate exception | Per host, shared across ports and schemes, expires after **7 days** (Chromium `stateful_ssl_host_state_delegate.cc`). WebSockets get no interstitial. | Permanent override per host:port | **Unverified** for wss. Old reports of failure predate WebKit's NSURLSession WebSocket stack. |
| HTTPS-by-default | 154 warns only for public sites. Private IPs and single-label names are exempt. `.local` is exempt per source (not tested). | n/a | n/a |
| Web Serial | Desktop 89+. Android 148+, but only where wired serial ports are exposed. | 151+ desktop, behind an add-on gate | No |
| Web Bluetooth | Central role only. The HID service 0x1812 is blocklisted. | No | No |
| WebUSB / WebHID | Yes. WebHID is desktop-only; Android dev trial in 154, ship planned for 157. | No | No |
| Cast Web Sender / Remote Playback | Yes (HTTPS required) / 121+ | No / No | No (no Cast on iOS Chrome) / 13.1+ (AirPlay) |
| Direct Sockets | Isolated Web Apps only. IWAs are default-on only on ChromeOS, and policy installs need a Google allowlist from 143. | No (negative position) | No |

Sources:
- https://developer.chrome.com/blog/local-network-access
- https://chromestatus.com/feature/5152728072060928
- https://chromestatus.com/feature/5197681148428288
- https://chromestatus.com/feature/4779920606756864
- https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/LocalNetworkAccessSettings/LocalNetworkAccessRestrictionsTemporaryOptOut.yaml
- https://bugzilla.mozilla.org/show_bug.cgi?id=2081728
- https://bugs.webkit.org/show_bug.cgi?id=171934
- https://chromium.googlesource.com/chromium/src/+/main/components/security_interstitials/content/stateful_ssl_host_state_delegate.cc
- https://blog.google/security/https-by-defau/
- https://developer.chrome.com/docs/iwa/allowlist
- https://hacks.mozilla.org/2026/05/web-serial-support-in-firefox/

### 3.2 Rules that decide almost every row below

- **Mixed content is about the scheme, not the network.** http:// and ws:// to a TV from an HTTPS page are mixed content; only Chromium lifts that (after LNA, for private-IP literals and `.local`). Self-signed `wss://`/`https://` and cloud HTTPS are not mixed content, so they are open to Firefox too, and cloud HTTPS needs no LNA prompt at all.
- **CORS is untouched by LNA.** TVs almost never send `Access-Control-Allow-Origin`. That leaves two cases:
  - **"Simple" requests** (GET/HEAD/POST, no custom headers, text/plain or form body) go out, but responses are opaque. They are fire-and-forget only.
  - **Anything else** is preflighted, and the device does not answer the preflight. That covers JSON content types, `Authorization`/PSK/`SOAPAction`/`X-Api-Key` headers, and PUT/DELETE. The request is never sent.
  - `mode:'no-cors'` allows only GET/HEAD/POST and **silently drops non-safelisted headers**. So token-header APIs (Fire TV, Vizio, Sony PSK, UPnP SOAP) cannot be rescued with it (https://fetch.spec.whatwg.org/#cors-safelisted-method).
- **Origin cannot be spoofed by a page.** Devices may filter on it:
  - LG SSAP rejects web origins with close code 1008 (2023 evidence).
  - DIAL servers return 403 for origins not on the app's allowlist, and Amazon forbids `http:` origins.
  - Roku 403s were later attributed to hostname Host headers, not to Origin.
- **Raw TCP, TLS client certificates, reading peer certificates, UDP, multicast and broadcast are impossible in a page.** WebRTC is not a loophole: it only exchanges ICE/DTLS/SCTP with a WebRTC peer. node-forge's TLS supports only TLS 1.0/1.1, so in-page TLS over a relay would need a WASM stack and still needs a native relay.
- **Power-on from a page is narrow.** Wake-on-LAN and wake from deep standby are impossible. A page can power a TV on only through attached hardware (Web Serial CEC `Image View On`, IR dongles or bridges), the cloud (SmartThings `switch.on`), or while the TV's network stack is still awake (e.g. Roku `PowerOn` with Fast TV Start; Samsung `KEY_POWER` in the short standby window, a toggle). A Cast session start can also wake a TV through CEC as a side effect.
- **OS gates also apply to browsers:**
  - macOS 15+ local network privacy applies to Chrome, Firefox and Edge. Safari, WKWebView and SFSafariViewController are exempt.
  - On Android 17, WebViews inherit the host app's permission, so browsers that target SDK 37 will probably need ACCESS_LOCAL_NETWORK before any LAN page loads, including a hub-served UI (inference).
  - Sources: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy and https://developer.android.com/privacy-and-security/local-network-permission

## 4. Browser feasibility matrix

"Direct" means the page itself opens the connection to the TV. The last column is model C: the hub does the work; caveats there are native-side limits that apply to every browser.

| Protocol | Public HTTPS, Chromium 147+ | Public HTTPS, Firefox 153+ | Public HTTPS, Safari / any iOS browser | LAN-served http page, direct | Via watchme hub (any browser) |
|---|---|---|---|---|---|
| Samsung Tizen remote wss:8002 | steps: LNA prompt plus certificate click-through repeated about weekly. TV acceptance of a foreign Origin rests on weak evidence. Some 2026 firmware times out. | steps: permanent host:port certificate exception plus LNA prompt (wss is not mixed content). TV Origin acceptance unverified. | unverified: no LNA, wss certificate exception untested | steps: certificate click-through still needed | works (some 2026 firmware refuses pairing) |
| Samsung REST /api/v2 (8001/8002) | steps: http IP literal after LNA grant. `ACAO: *` was seen only in a 2018 capture. | https:8002 after a certificate exception only (unverified) | https:8002 after an exception (unverified) | works if CORS is still open (unverified) | works |
| Samsung UPnP DMR, WoL, TCP 55000, 2014-15 encrypted, Frame art uploads | blocked | blocked | blocked | blocked | works |
| SmartThings cloud (Samsung) | steps: CORS `*` verified 2026-10-21 on `api.smartthings.com` (incl. `/oauth/token`); `auth-global.api.smartthings.com/oauth/token` rejects CORS. Auth needs a bring-your-own OAuth app secret, a 24 h PAT, or a token-exchange backend. Paid tiers pending. | steps (same; cloud HTTPS is neither LNA-gated nor mixed content) | steps (same) | steps (same) | works (hub holds the tokens; needs internet) |
| LG webOS SSAP wss:3001 | unverified and fragile: needs the Origin:null `data:` iframe trick (an MIT original exists), LNA delegation to an opaque-origin frame (unverified), the weekly certificate step and an unsigned manifest | unverified and fragile (same, with Firefox's permanent certificate exception) | unverified | unverified and fragile (Origin:null trick plus certificate step) | works (unsigned manifest; one webOS 26 model still rejects it) |
| LG Network IP Control TCP 9761, LG WoL | blocked | blocked | blocked | blocked | works (hidden-menu keycode setup) |
| Android TV Remote v2 (mTLS) | blocked | blocked | blocked | blocked | works (launch by package broken since Aug 2026; deep links only) |
| ADB (5555 / wireless debugging) | blocked (WebUSB works only over a USB cable) | blocked | blocked | blocked | works, opt-in (Fire OS and Android TV with developer mode; not Vega) |
| Google Cast CASTV2, raw | blocked | blocked | blocked | blocked | works |
| **Google Cast Web Sender SDK** | **works**: user picks the device in Chrome's dialog. Media only. | no | AirPlay via Remote Playback only (media) | blocked (needs a secure context; `http://localhost` is fine) | n/a (hub uses CASTV2) |
| Roku ECP HTTP 8060 | write-only: no-cors POST to an IP literal after the LNA prompt, and only if "Control by mobile apps" is Enabled | blocked (mixed content) | blocked | write-only | works (full, reads state; needs "Control by mobile apps" = Enabled) |
| Roku private ecp-2 WebSocket | not recommended (requires a key extracted from Roku's app) | - | - | - | not recommended |
| Fire TV app API HTTPS 8080 | blocked: custom headers force a preflight, there is no CORS evidence, and no-cors drops the headers | blocked | blocked | blocked | works (undocumented; DIAL wake on 8009 first) |
| Fire TV ADB | blocked | blocked | blocked | blocked | Fire OS only (not Vega) |
| Fire TV Matter Casting | blocked | blocked | blocked | blocked | blocked without CSA attestation |
| Apple TV Companion / AirPlay 2 remote control | blocked | blocked | blocked (AirPlay media casting via Remote Playback is possible) | blocked | works with caveats: pyatv 0.18.0 pairing broken on tvOS 26.3-27; play_url broken on tvOS 26 |
| Vizio SmartCast HTTPS 7345 | unverified: needs a preflight answer for PUT plus the AUTH header, and a weekly certificate step | unverified | unverified | unverified | works (Walmart-account gating and firmware hardening possible) |
| Sony REST/IRCC HTTP 80 | steps: PSK mode only if the firmware answers the preflight; write-only with Auth=None | blocked (http mixed content) | blocked | steps (CORS varies by firmware) | works |
| Sony Simple IP Control TCP 20060 | blocked | blocked | blocked | blocked | works (no authentication) |
| Philips JointSpace v6 (HTTPS 1926, digest) | blocked | blocked | blocked | blocked | works (app and source endpoints return 403 on Titan) |
| VIDAA MQTT 36669 | blocked | blocked | blocked | blocked | works with a user-supplied vendor client certificate; tokens lost on deep standby |
| VIDAA UPnP DMR 38400 | blocked | blocked | blocked | blocked | works (volume, mute, transport, URL cast) |
| Titan MQTT 8883 | blocked | blocked | blocked | blocked | works, verified on 1 model |
| Panasonic SOAP, Sharp 10002, Samsung MDC, NEC 7142, DIAL, UPnP/DLNA | blocked | blocked | blocked | blocked | works |
| HDMI-CEC | steps: Web Serial to a Pulse-Eight USB-CEC adapter attached to the browsing computer (includes power-on) | steps: 151+ desktop, add-on gate | no | blocked (not a secure context) | works (hub on HDMI) |
| IR bridges (ESPHome / Tasmota) | steps: ESPHome needs the origin in `allowed_origins` (2026.7+); Tasmota is write-only no-cors | blocked (https to http) | blocked | steps | works |
| Web Bluetooth to a watchme BLE bridge (ESP32 emitting IR/CEC/HID) | steps: user picks the device; central role only; custom hardware | no | no | blocked (not a secure context) | n/a (hub uses native Bluetooth) |
| Bluetooth HID keyboard emulation | blocked: Web Bluetooth is central-only and HID is blocklisted | blocked | blocked | blocked | hub BlueZ peripheral (unverified per TV); Android app |
| SSDP / mDNS discovery, Wake-on-LAN | blocked | blocked | blocked | blocked | works |

**Practical reading.**
- http/ws to the LAN from a public HTTPS page is Chromium-only: Roku (write-only), Sony (some firmware), HTTP IR bridges.
- Self-signed wss (Samsung) works in Chromium and Firefox after certificate steps, with firmware risk; Safari is unverified. LG SSAP is unverified and fragile everywhere.
- Cloud HTTPS (SmartThings) works in every browser, with bring-your-own credentials.
- Casting: Cast Web Sender in Chromium; AirPlay via Remote Playback in Safari.
- Attached hardware from a secure context: Web Serial CEC/IR (desktop Chromium, Firefox 151+) and Web Bluetooth bridges (Chromium).
- On the developer's LAN, no browser-direct remote-control path reaches the Fire TV or the Apple device. If 192.168.1.40 is an Apple TV, Safari could AirPlay a media URL to it.

## 5. Capability matrix

Columns: Off = power_off, On = power_on, PSt = power_state, Vol = volume, Mute = mute, Nav = dpad_navigation, Sys = system_keys, Text = text_input, Apps = app_list, Launch = app_launch, Input = input_switch, Chan = channel, Media = media_transport, NowP = now_playing, Ptr = pointer, Toast = notification_toast, Shot = screenshot, Cast = cast_media_url.

| Protocol | Off | On | PSt | Vol | Mute | Nav | Sys | Text | Apps | Launch | Input | Chan | Media | NowP | Ptr | Toast | Shot | Cast |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Samsung Tizen WS (wss 8002 / ws 8001) | Y | P | P | P | Y | Y | Y | P | P | P | P | Y | P | N | P | N | N | P |
| Samsung REST /api/v2 | N | N | P | N | N | N | N | P | P | Y | N | N | N | P | N | N | N | N |
| Samsung UPnP DMR (9197) | N | N | P | Y | Y | N | N | N | N | N | P | N | P | P | N | N | N | P |
| Samsung TCP 55000 (2010-13) | Y | N | P | P | Y | Y | Y | N | N | N | P | Y | P | N | N | ? | N | P |
| Samsung encrypted (2014 H / 2015 J) | Y | N | P | P | Y | Y | Y | ? | ? | ? | P | Y | P | N | N | ? | N | P |
| SmartThings cloud (Samsung) | Y | P | P | Y | Y | P | P | N | ? | Y | Y | Y | P | P | N | N | N | N |
| LG webOS SSAP (wss 3001) | Y | P | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | P | P | Y | Y | P | P |
| LG Network IP Control (TCP 9761) | Y | P | P | Y | Y | Y | Y | N | N | Y | Y | P | P | P | N | N | N | N |
| Android TV Remote v2 | Y | P | Y | P | Y | Y | Y | P | N | P | P | Y | P | P | N | N | N | N |
| ADB (Fire OS / Android TV) | Y | P | Y | Y | Y | Y | Y | P | Y | Y | P | P | Y | P | P | P | Y | P |
| Google Cast CASTV2 (native) | N | P | P | Y | Y | N | N | N | N | P | N | N | Y | P | N | P | N | Y |
| Cast Web Sender (browser) | N | P | N | Y | Y | N | N | N | N | P | N | N | Y | P | N | P | N | Y |
| Roku ECP | Y | P | Y | P | P | Y | Y | Y | Y | Y | Y | Y | P | P | N | N | N | P |
| Fire TV app API (HTTPS 8080) | Y | P | N | P | P | Y | Y | P | Y | Y | N | N | P | ? | N | N | N | N |
| Matter Casting (Fire TV player) | P | P | P | P | ? | P | P | N | N | Y | ? | ? | Y | P | N | N | N | Y |
| Apple TV Companion | Y | Y | Y | P | ? | Y | Y | Y | Y | Y | N | P | P | N | P | N | N | N |
| Apple TV AirPlay 2 / MRP | P | P | P | Y | ? | Y | Y | N | P | N | N | N | Y | Y | N | N | N | P |
| Vizio SmartCast REST | Y | P | Y | Y | Y | Y | Y | P | P | Y | Y | Y | P | P | N | N | N | P |
| VIDAA MQTT (36669) | Y | P | P | Y | Y | Y | Y | P | Y | Y | Y | Y | P | P | ? | P | ? | P |
| VIDAA UPnP DMR (38400) | N | N | P | Y | Y | N | N | N | N | N | N | N | P | P | N | N | N | P |
| Philips JointSpace v6 (Android TV) | Y | P | Y | Y | Y | Y | Y | P | Y | Y | P | Y | P | P | N | N | N | P |
| Titan OS MQTT (8883) | Y | P | P | P | P | Y | Y | Y | Y | Y | P | P | P | P | N | ? | N | ? |
| Sony REST + IRCC | Y | P | Y | Y | Y | Y | Y | P | Y | Y | Y | P | P | P | N | N | N | P |
| Sony Simple IP Control (TCP 20060) | Y | P | Y | Y | Y | Y | Y | N | N | N | Y | P | P | N | N | N | N | N |
| Panasonic Viera SOAP (55000) | P | P | P | Y | Y | Y | Y | ? | Y | Y | P | P | P | N | ? | N | N | P |
| Sharp AQUOS (TCP 10002) | Y | P | Y | Y | Y | P | P | N | N | N | Y | Y | P | P | N | N | N | N |
| HomeKit TV service (e.g. Xumo TVs) | Y | Y | Y | N | N | ? | ? | N | N | N | Y | N | ? | N | N | N | N | N |
| HDMI-CEC (hub on HDMI) | Y | Y | Y | P | P | P | P | N | N | N | P | P | P | N | N | P | N | N |
| DIAL | P | P | N | N | N | N | N | N | N | P | N | N | N | P | N | N | N | P |
| UPnP/DLNA renderer (generic) | N | N | N | Y | Y | N | N | N | N | N | N | N | P | P | N | N | N | Y |
| Matter video player (controller path) | Y | P | Y | P | P | Y | Y | N | P | P | P | P | Y | P | N | P | N | P |
| Consumer IR | P | P | N | Y | Y | Y | Y | N | N | P | P | Y | P | N | N | N | N | N |
| Bluetooth HID (Android phone or hub BlueZ) | P | ? | N | P | P | Y | P | Y | N | N | N | P | P | N | P | N | N | N |
| Wake-on-LAN | N | P | N | N | N | N | N | N | N | N | N | N | N | N | N | N | N | N |

Notes that change how the matrix should be read:

**Samsung**
- Volume over the WebSocket is relative only.
- WebSocket app list and launch stopped working on roughly 2021+ models; use REST to launch.
- There is no local direct HDMI selection.
- KEY_POWER is a toggle, and KEY_POWERON had no visible effect on a 2025 Q8F (HA #187048), so there is no discrete local power-on.

**LG**
- The ratings assume an unsigned manifest that lists every permission, including CONTROL_MOUSE_AND_KEYBOARD.
- Direct `settings/setSystemSettings` writes return 401 with an unsigned key.
- Screenshot via `executeOneShot` is unverified with an unsigned key.
- `system/turnOff` within about a minute of a remote switch-off turns the TV back on (lgtv2 #15, 2018).

**Android TV**
- Since mid-August 2026, app launch works only through deep links. A Play Store change broke `market://launch?id=`.
- Volume is relative only. The TV pushes the level, but no library sets an absolute value.

**Roku**
- Since Roku OS 14.1, keypresses need "Control by mobile apps" set to Enabled. Limited mode blocks keypress, `query/apps` and `query/media-player`.
- Volume, mute, input and channel keys apply to Roku TVs; players get them through CEC.

**Fire TV**
- Volume and mute are relative CEC steps confirmed only on Vega (Fire TV Stick 4K Select).
- One Fire OS 8 receiver reported volume unsupported.

**Apple TV**
- These are the ratings of pyatv's protocol support.
- Pairing currently fails on tvOS 26.3-27 with pyatv 0.18.0.

**Cast**
- Volume and mute set the receiver or session volume. Whether that changes the TV's panel volume depends on the device.

**Bluetooth HID**
- Only an LG G5 (webOS 25) with an Android phone is confirmed. A Linux/Pi BlueZ peripheral is unverified per TV.

**Wake-on-LAN**
- Requires the TV's network-standby setting.
- Results differ by model between Ethernet and Wi-Fi.

## 6. Platforms

### 6.1 Samsung (Tizen 2016-2026; earlier generations)

| Model years | Local path | Ports | Pairing |
|---|---|---|---|
| 2010-2013 (C/D/E/F) | Raw TCP remote | 55000 | On-screen Allow |
| 2014 H, 2015 J | Encrypted "SmartView2": socket.io plus AES with a custom Rijndael | 8080 pairing, 8000 control | PIN |
| 2016-2017 | WebSocket remote, no token | ws 8001 | Allow on some models |
| 2018-2026 (Tizen 4.0-10.0) | WebSocket remote with token (`TokenAuthSupport=true`) | wss 8002 | Allow prompt, then token |
| 2016+ | REST `/api/v2/`: device info, PowerState, app status and launch | http 8001 / https 8002 | None (imeInput needs the token) |
| Tizen | UPnP DMR RenderingControl / AVTransport | http 9197 | None |
| 2016+ | Wake-on-LAN ("Power On with Mobile") | udp 9/7 | None |
| Frame | Art channel `com.samsung.art-app` plus a raw D2D TCP socket for uploads | wss 8002 + dynamic | Same token |
| 2017+ | SmartThings cloud REST | 443 | OAuth / PAT |

**Remote channel.**
- URL: `wss://IP:8002/api/v2/channels/samsung.remote.control?name=<b64>&token=<t>`. The first connect shows an Allow prompt, and the token arrives in `ms.channel.connect`.
- Keys are sent as `ms.remote.control`. Text uses `SendInputString`, which works only while the on-screen keyboard is open. Pointer uses `ProcessMouseDevice`.
- The user must enable IP Remote and should set Access Notification to "First time only".
- The TV refuses WebSocket connections from other subnets or VLANs.
- Sources: https://github.com/xchwarze/samsung-tv-ws-api, https://github.com/tavicu/homebridge-samsung-tizen/blob/master/src/protocols/websocket.ts, https://www.home-assistant.io/integrations/samsungtv/

**Power.**
- KEY_POWER is a toggle.
- Power-on works only:
  - within about a minute of standby,
  - via Wake-on-LAN, which is model-dependent (some models wake only over Ethernet, others only over Wi-Fi), or
  - via SmartThings.
- Frame TVs go to Art Mode instead of turning off, so a real off needs SmartThings (homebridge #741).
- PowerState is unreliable at the edges:
  - The TV still answers for about 17-20 s after turning off.
  - A Frame reports `standby` while in Art Mode.
  - A 2025 Q8F stayed `standby` after a KEY_POWER wake (HA #187048).
- Model power as a state machine.
- Home Assistant 2026.10 removed implicit WoL (https://github.com/home-assistant/core/pull/182771).

**Feature gaps.**
- WebSocket app list and launch are gone on roughly 2021+ models. REST `POST /api/v2/applications/{id}` still works (https://github.com/xchwarze/samsung-tv-ws-api/issues/117).
- Absolute volume needs UPnP or SmartThings.
- There is no local HDMI selection (https://www.openhab.org/addons/bindings/samsungtv/).

**TLS.**
- Self-signed "SmartViewSDK Root CA G2" with no SAN.
- Identical validity dates across devices suggest a certificate shared across the fleet (inference). TLS therefore does not authenticate an individual TV.

**2026 risks.**
- Firmware T-RSPDWWC-0090-2115 (Odyssey G8 monitor) and 0090-2130.0 (2024 98" DU9) answer `ms.channel.timeOut` immediately, with no popup. The HA code owner calls it a glitch with no client fix; the samsungtvws maintainer suspects it is deliberate. More reports followed on 2026-10-15. Sources: https://github.com/xchwarze/samsung-tv-ws-api/issues/184, https://github.com/home-assistant/core/issues/179510

**SmartThings.**
- Covers power on/off, absolute volume, mute, HDMI select, channels, app launch, and d-pad via `samsungvd.remoteControl`.
- CORS is open (`ACAO: *`, observed 2026-10-21 on `api.smartthings.com`, including `OPTIONS` and `POST /oauth/token`).
- From a browser, the token exchange must use `https://api.smartthings.com/oauth/token` with HTTP Basic and the user's own client secret. `/v1/oauth/token` is the documented path, but its CORS was not separately tested. `auth-global.api.smartthings.com/oauth/token` answered the preflight with 403 and no CORS headers.
- PATs created after 2024-12-30 last 24 h.
- The OAuth token endpoint requires HTTP Basic client authentication with the secret; PKCE is not documented. Refresh tokens last 30 days and rotate on use.
- Install cap: a shared OAuth app may be capped at 20 installs (2026 reports; staff cite 500). With the client-secret requirement, this is a reason for each user to bring their own app rather than watchme shipping one.
- **Paid API tiers** were announced 2026-06-23 ($4.99/month individual; free access phases out from October 2026). As of 2026-10-20 no plan could be purchased.
- Sources: https://community.smartthings.com/t/a-new-enhanced-smartthings-api-experience/309947, https://developer.smartthings.com/docs/service-integrations/oauth

**Browser precedent.** https://github.com/dobrou/dobrou.github.io/blob/master/tv/remote.html (May 2025) opens wss:8002 directly from GitHub Pages. This is weak evidence that the TV accepts a foreign Origin.

**For watchme.**
- Port from homebridge-samsung-tizen (MIT, v6.1.0, 2026-10-16).
- samsungtvws (LGPL-3.0) is reference only.
- So is ha-samsungtv-smart's `api/samsungws.py`, which carries an LGPL-2.1+ header despite the Apache-2.0 repo.
- Dart's `tizen_api` (BSD-3, 2024) is thin.

**Market.** 270M Tizen TVs at end-2023 (https://news.samsung.com/global/interview-transition-to-tizen-how-a-talented-team-of-developers-laid-the-foundation-for-ai-tv). Tizen is licensed to RCA, Loewe and others; whether those sets expose 8001/8002 is unknown.

### 6.2 LG (webOS)

**SSAP over WebSocket.**
- Use `wss://TV:3001`. The legacy ws:3000 is refused, resets, or hangs for minutes on firmware since about January 2023. Use short timeouts and connect wss first (https://github.com/home-assistant-libs/aiowebostv/issues/744).
- Handshake:
  1. `hello`
  2. On webOS 25+ (firmware 33.20.66+), `ssap://system/getSystemInfo`
  3. `register` with a permissions manifest
  4. PROMPT (or PIN via `ssap://pairing/setPin`), which returns a `client-key`
- A second WebSocket from `getPointerInputSocket` carries buttons and pointer events.
- Internal `luna://` services are reachable only through the `createAlert` onclose hack. webOS 24+ ignores `closeAlert`, so dismiss the alert with ENTER after about 300 ms.
- Sources: https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/endpoints.py, https://github.com/grzegorz914/homebridge-lgwebos-tv/blob/main/CHANGELOG.md

**2026 manifest blacklist.**
- Firmware 43.00.92 (April 2026, C2), 43.21.60/71 (August 2026) and webOS 26 answer the widely copied LG-signed manifest with `403 Pairing rejected: blacklisted certificate detected` and show no prompt. Enforcement is build-dependent: a C6 on 43.11.73 still accepted it in July.
- A custom signed block registers, but the pointer socket then returns 401 (https://github.com/JPersson77/LGTVCompanion/issues/351).
- **Fix:** an unsigned manifest that lists every permission in the outer list. This shipped in aiowebostv 0.9.2 / HA 2026.8.3 and LGTVCompanion 5.7.0.
- Still lost after the fix:
  - `getCurrentSWInformation` (401)
  - direct `ssap://settings/setSystemSettings` (401, also on older C3/CX/C5/G5 once unsigned; https://github.com/home-assistant/core/issues/180025)
  - The luna settingsservice route via alert still works.
- One OLED42C6PCA still rejects unsigned registration (https://github.com/home-assistant/core/issues/172703, unresolved).
- **Do not ship any LG-signed manifest**, neither the classic one nor the "LG Mobile" one extracted from the ThinQ app.

**TLS.** The leaf `CN=LGE TV SSG` key was identical on three sampled TVs (2018-2023). Pinning proves only "an LG TV", so use trust-on-first-use.

**Discovery and power.**
- SSDP `urn:lge-com:service:webos-second-screen:1`. AirPlay-capable LG TVs also advertise `_airplay._tcp`.
- MACs for WoL come from `connectionmanager/getinfo`.
- WoL needs "Turn on via Wi-Fi" (older menus) or Support > IP control settings > Wake on LAN (2025+). Some Wi-Fi sets also need Quickstart+ or Always Ready. A TV may not rejoin Wi-Fi after a router reboot.
- `system/turnOff` sent within about a minute of a remote switch-off turns the TV back on (lgtv2 #15, 2018), so check `getPowerState` first.

**Network IP Control (TCP 9761).**
- Setup: All Settings, focus Connection, type 82888 on the remote, then generate an 8-character keycode.
- Messages are AES-encrypted with a key derived by PBKDF2-SHA256 (16384 iterations).
- Covers power off and state, absolute volume, mute, keys, input, APP_LAUNCH and picture settings.
- It is independent of the SSAP manifest, and was reported working on a 2026 C6 with webOS 26.
- MIT reference: https://github.com/WesSouza/lgtv-ip-control

**Other paths.**
- Google Cast is built into many LG TVs; the exact model list is unverified.
- ThinQ Connect does **not** cover TVs (https://github.com/thinq-connect/pythinqconnect).
- Under the Re:New program, 2022-2024 sets are upgraded to webOS 26-28 with no downgrade, so firmware breaks reach old TVs too.
- A September 2026 security report (Malwarebytes) suggests more lock-downs are coming.

**Browser.** Unverified and fragile, not settled either way.
- SSAP rejects normal web origins with close code 1008 "invalid origin" (2023 evidence on ws:3000; unverified on wss:3001 and webOS 25/26).
- The only known workaround is an Origin-null `data:` iframe proxy. The MIT original (Informatic/webos-ssap-web) can be reimplemented cleanly, so licensing is not the blocker; the AGPL-3.0 throwaway96 fork must not be copied and still hard-codes the blacklisted manifest.
- The real blockers:
  - Chrome's `local-network` permission must be delegated to an opaque-origin iframe (`allow="local-network"`); whether Chrome honours that is unverified.
  - The Origin check itself is unverified on wss:3001 and webOS 25/26.
  - The certificate step repeats weekly in Chrome.
  - Pairing needs an unsigned manifest.
- This is a hardware-test item (§13).

**For watchme.**
- Port from aiowebostv (Apache-2.0).
- lgtv2, bscpylgtv and LGTVCompanion (MIT) are good references.
- Dart `webos_remote` (MIT) still sends the signed manifest and skips `getSystemInfo`, so it is likely broken on webOS 25/26.

**Market.** LG claims 260M webOS devices including monitors (2025). webOS Hub has about 200+ licensee brands (2022); whether they expose SSAP is unknown. Home Assistant's webostv integration has about 65K reported installs.

### 6.3 Android TV / Google TV

**Remote Service protocol v2** (the Google TV phone-remote protocol).
- Pairing on TCP 6467, control on TCP 6466, both mutual TLS. The client presents a self-signed **RSA** certificate.
- The TV shows a 6-hex-digit code. The secret is SHA-256 over:
  1. the client modulus,
  2. the client exponent,
  3. the server modulus,
  4. the server exponent,
  5. the last 4 hex digits of the code.

  The first byte of the hash must equal the first 2 hex digits.
- Messages are varint-prefixed protobuf. Discovery uses mDNS `_androidtvremote2._tcp`. No developer mode is needed.
- The TV pushes `is_on`, `current_app` (needs IME) and volume level, max and muted.
- Missing:
  - app list
  - absolute volume set
  - playback state
  - pointer
- Netflix ignores injected keys.
- Requires Remote Service 5.0 or later (2021). Some boxes still speak v1.
- Sources: https://github.com/tronikos/androidtvremote2, https://www.home-assistant.io/integrations/androidtv_remote/

**Mid-August 2026 break.** A Google Play Store update broke launching apps by package (`market://launch?id=`). Only apps with their own deep links still launch (https://github.com/tronikos/androidtvremote2/issues/46).

**Google Cast.**
- Native path (CASTV2): TLS on 8009 with 4-byte length-prefixed protobuf and JSON namespaces. No pairing. The receiver certificate is self-signed and short-lived (4 days or less), so do not pin it (https://chromium.googlesource.com/openscreen/+/refs/heads/main/cast/sender/channel/cast_auth_util.cc).
- Browser path (Web Sender SDK): needs HTTPS, works only in Chromium, and the user picks the device. Covers media URL, transport and session volume/mute only (https://developers.google.com/cast/docs/web_sender).

**ADB.**
- Classic port 5555, or Android 11+ wireless debugging (SPAKE2 pairing plus TLS). Android 13 for TV was developer-only, so on consumer TVs wireless debugging means Android TV 14+.
- CVE-2026-0073 is a critical RCE: a wireless-ADB authentication bypass on Android 14-16 (https://source.android.com/docs/security/bulletin/2026/2026-05-01).
- On Chromecast with Google TV running Android 14, TCP 5555 is reportedly off by default and resets on reboot.
- Treat ADB as an opt-in advanced feature. Pure-Dart client: flutter_adb (BSD-3).

**Power.** Android TV 14 energy modes:
- Low cuts the network in standby.
- Optimized keeps Cast over Wi-Fi only.
- Increased keeps everything.

So network power-on is not guaranteed (https://9to5google.com/2024/05/15/android-14-for-tvs/).

**Not viable.**
- Google Home APIs: Android/iOS SDKs only, and the developer console was "not yet available for registration" as of 2026-09-23.
- Matter Casting: not shipped on Google TV.
- Anymote: deprecated.

**For watchme.**
- Port from androidtvremote2 (Apache-2.0) and the AOSP pairing reference (Apache-2.0).
- Pure-Dart proof: https://github.com/amolood/Universal-Remote (MIT). It uses `SecurityContext.useCertificateChainBytes`, `SecureSocket` and `peerCertificate`, and walks the ASN.1 with asn1lib because the basic_utils parser throws on some TV certificates.

**Market.**
- 220M monthly active Android TV OS devices (May 2024).
- Omdia 2025: Android/Google TV 42% of global TV OS shipments.
- Under 10% of North America (Omdia, April 2026).

### 6.4 Roku

**ECP.** Plain HTTP on 8060, discovered via SSDP `ST: roku:ecp`. Documented by Roku (https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md).
- Commands: `keypress/<Key>`, `Lit_<char>` text, and `launch/<id>?contentId=` deep links.
- Queries: `query/device-info` (power-mode), `query/apps`, `query/active-app`, `query/media-player`, tv-channels.
- Roku TV extras: input keys (HDMI1-4, Tuner).
- `PowerOn` is undocumented but widely used. It works only while the network is awake: the network shuts down about 10 minutes after off unless Fast TV Start is on. Otherwise use WoL, with mixed results.

**Access gate (Roku OS 14.1+).** Settings > System > Advanced system settings > Control by mobile apps (some firmware adds a "Network access" submenu).

| Mode | What it allows |
|---|---|
| Limited (effective default per field reports) | Answers `device-info` and `active-app`. Returns 403 with body "ECP command not allowed in Limited mode." for keypress, `query/apps` and `query/media-player`. Launch is disputed. |
| Enabled | Full control from the same local network |
| Permissive | Also accepts commands across subnets |

Other access rules:
- ECP accepts only private source IPs.
- The **Host header must be an IP literal**; hostnames get 403.
- Sources: https://support.roku.com/article/217288467, https://github.com/home-assistant/core/issues/131969

**Browser.** ECP has never sent CORS headers, so a page can only send no-cors POSTs:
- Chromium: from HTTPS after the LNA prompt.
- Any browser: from a LAN-served http page.

Either way the page cannot read state.

**Paths to avoid or route around.**
- The private `ws://IP:8060/ecp-session` (subprotocol `ecp-2`) used by Roku's own apps needs a key extracted from the Android app. **Do not implement.**
- Casting: "Play on Roku" was locked down in Roku OS 11.5. Use the Media Assistant receiver channel instead (Apache-2.0, store id 782875).

**Policy and corporate.**
- Roku's ECP doc states "ECP commands may not be sent from 3rd-party platforms (for example, mobile applications)". Enforceability against an open-source remote is unclear; get a legal review.
- Fox-Roku merger: stockholders approved it on 2026-10-14, with closing expected H1 2027.

**For watchme.**
- References: python-rokuecp (MIT) and node-roku-client (Apache-2.0).
- Simulator: brs-desktop (MIT, https://github.com/lvcabral/brs-desktop) emulates ECP, SSDP and ecp-session, but not Limited mode or the Host check.
- No Dart package exists; the protocol is trivial to implement.

**Market.** US leader: 28% of CTV OS usage (Parks, April 2026) and 36% of North American ad share-of-voice (Pixalate, Q1 2026).

### 6.5 Amazon Fire TV (Fire OS and Vega OS)

**Mobile-app remote API ("Lightning").** Reverse-engineered; works on Fire OS 6-8 and on the Vega OS Fire TV Stick 4K Select.
1. Wake with `POST http://IP:8009/apps/FireTVRemote` (DIAL, expect 201). Port 8080 does not listen while the device sleeps, so a client must send this before every probe or session.
2. Call HTTPS on 8080 (self-signed): `POST /v1/FireTV/pin/display`, then `/pin/verify` returns a token.
3. Send every later request with the header `X-Api-Key: 0987654321` (a static value from the app, not a secret) and `X-Client-Token`.

Endpoints and behavior:
- `?action=dpad_*|select|home|back|menu|sleep|power`
- `/v1/FireTV/keyboard`
- `/v1/FireTV/appsV2`
- `/v1/FireTV/app/<package>`
- `/v1/media?action=play|scan`
- `volume_up` / `volume_down` / `mute` are forwarded over HDMI-CEC, confirmed on Vega only.
- Voice uses WSS on 9090, which accepts an unauthenticated upgrade.
- Discovery: `_amzn-wplay._tcp` (records contain `amzn.dmgr:`) and SSDP/DIAL (`urn:dial-multiscreen-org:service:dial:1`, manufacturer Amazon, model `AFT*`). LibreControl's 2026-10-19 hardware test found a stick via SSDP/DIAL and saw no `_amzn-fireTv._tcp` advertisement, so clients need both matchers.
- Sources: https://community.home-assistant.io/t/rest-commands-for-fire-tv/901314, https://github.com/LibreControl/fire-tv, https://github.com/LibreControl/fire-tv/blob/main/docs/protocol.md, https://github.com/hms-homelab/hms-firetv, https://github.com/redimpulz/firetv-cec-volume

**ADB.** Fire OS only. Vega has no ADB or sideloading; its developer mode gives a VDA shell that needs an Amazon developer account.

**Matter Casting.**
- Supported on Fire OS 7+ and Vega (Matter 1.5).
- Clients use User Directed Commissioning with an 8-digit passcode.
- Fire TV validates the client's DAC against DCL roots, and content apps allowlist client vendor and product IDs. An uncertified open-source client is likely blocked.
- Source: https://developer.amazon.com/docs/fire-tv/overview-of-matter-casting.html

**Other.**
- Amazon's developer forum says there are no public remote-control APIs.
- The Fling SDK has reached end of standard support.

**Market.**
- Fire TV holds 19% of North American ad share-of-voice (Pixalate, Q1 2026).
- Omdia counts Fire TV plus Walmart's Vizio platform at 27% of North American TV OS units in 2025, forecast to reach 47% by 2029.
- Fire TV devices sold: 250M+ (unverified).

### 6.6 Apple TV

**Protocols.**
- **Companion link:** `_companion-link._tcp`, HAP-style SRP-6a pairing with a PIN on screen, ChaCha20-Poly1305, OPACK payloads. Covers power on/off and state, keys, keyboard text, app list and launch, touch gestures.
- **AirPlay 2 with tunnelled MRP** (tvOS 15+): volume, transport, now-playing metadata, `play_url`.
- Source: https://pyatv.dev/documentation/supported_features/

**State of the reference library.** pyatv 0.18.0 (MIT, 2026-06-19) does **not** work cleanly on current tvOS:
- Companion pairing shows no PIN or fails at M4 on tvOS 26.3-27.0 (https://github.com/postlund/pyatv/issues/2837). A reported workaround is to open Settings > AirPlay and HomeKit first.
- AirPlay pairing needs an `X-Apple-Client-Name` header on tvOS 27 (fix in unmerged PR #2894).
- `play_url` returns HTTP 500 on tvOS 26 (fix in unmerged PR #2846).
- The maintainer cites limited time.

**Browser.** No remote-control path. Safari (including iOS) can AirPlay a media URL to an Apple TV through the Remote Playback API; that is media only.

**Dart building blocks.** pointycastle (SRP6) and cryptography (Ed25519, X25519, ChaCha20-Poly1305, HKDF). OPACK, TLV8, plist and MRP must be written.

**HomeKit.** A native iOS build can use the public HomeKit TV services (HMServiceTypeTelevision and RemoteKey, iOS 18+) for HomeKit TVs. AirPlay-only TVs may not appear as HomeKit accessories.

**Market.** 13% of North American ad share-of-voice.

### 6.7 Vizio (SmartCast / VIZIO OS)

**Protocol.**
- HTTPS on 7345 (port 9000 on older firmware). Self-signed certificate, CN `BG2.prod.vizio.com`.
- Pairing: `PUT /pairing/start` shows a 4-digit PIN; `/pairing/pair` returns a token, sent as the literal header `AUTH: <token>`. The token is **unscoped**: it also unlocks settings, network configuration and a system-webview URL launch.
- Discovery: `_viziocast._tcp`.
- Features: key codesets (power 11/x, volume 5/x, nav 3/x and so on), absolute volume readback, inputs, app launch.
- `state_extended` is available on roughly 2022+ firmware.
- Power-on works only in Quick Start mode; Eco mode disables the network.
- The app list comes from a cloud catalog (scfs.vizio.com), so it needs internet.
- Sources: https://github.com/raman325/vizaio/blob/main/docs/android-app-findings.md, https://github.com/exiva/Vizio_SmartCast_API

**Status (2026).**
- Walmart owns Vizio. The OS was renamed VIZIO OS, and onn TVs moved to it in November 2025.
- Walmart accounts are required on some new TVs (March 2026).
- The local API still exists on onn VIZIO OS 1.8, but October 2026 security research (https://github.com/vindeckyy/smartcast-backdoor) means firmware hardening is likely.

**Browser.** Provisional. Every call is a PUT, which cannot be sent no-cors. A 2021 advisory called the CORS policy "open" on 2017 firmware. Test on owned hardware.

**For watchme.** Port from vizaio (MIT, 0.7.0), which Home Assistant now uses instead of pyvizio.

### 6.8 Hisense / Toshiba / Loewe (VIDAA, becoming "V Home OS")

**MQTT path.**
- MQTT 3.1.1 over TLS to a broker running on the TV, port 36669.
- Modern models need **mutual TLS with a client certificate from the official app**. The server certificate chains to a private `RemoteCA`.
- Auth tiers vary by model year. Modern TVs use a PIN with a dynamic challenge, then tokens: access 48 h, refresh 30 days.
- Tokens are held in TV RAM, so deep standby wipes them and forces re-pairing.
- Credentials are timestamp-derived, and the broker rejects clocks more than 120 s apart; libraries read the TV clock from the UPnP `Date` header.
- Topics follow `/remoteapp/tv/{remote_service|ui_service|platform_service}/<client_id>/actions/...`.
- Sources: https://github.com/stevene1919/hisense_vidaa/blob/main/docs/protocol_architecture.md, https://github.com/warrenrees/pyvidaa

**UPnP/DLNA path.** HTTP on 38400 (18400 on some hardware), unauthenticated. Covers RenderingControl volume/mute and AVTransport play/pause/seek/URL. This is the easiest first step.

**Legal.** Some MIT repos bundle the vendor client certificates (vidaa-control, ioBroker.vidaa), and Hisense rejects older ones ("app obsolete"). **watchme must not ship them**; use bring-your-own certificate.

**Brands.** The same protocol is documented for Toshiba, Loewe, Schneider and other VIDAA sets (single source). European Toshiba TVs are Vestel-built and may run VIDAA, Vestel/Android or Fire TV. US Toshiba TVs are Fire TV.

**Market.** About 6% of global shipments (Omdia 2025). In Europe, VIDAA is forecast to overtake webOS in 2026.

### 6.9 Philips (TP Vision): JointSpace and Titan OS

**JointSpace v6.**
- HTTPS on 1926. The certificate is a SHA-1-signed TP Vision private CA chain (leaf `restfultv.tpvision.com`); pin its fingerprint.
- PIN pairing: `pair/request`, then `pair/grant` with HMAC-SHA1 over a shared key from the Philips app, then HTTP Digest auth.
- Discovery: `_philipstv_s_rpc._tcp`.
- Rich on Android TVs (2016-2025): absolute volume, apps, channels, keys.
- Older non-Android sets use v1/v5 on HTTP 1925 with no auth (legacy).
- Sources: https://github.com/danielperna84/ha-philipsjs, https://github.com/eslavnov/pylips

**Titan OS** (all 2026 Philips TVs; https://heise.de/-11223309).
- JointSpace still answers on Titan, but app and source endpoints return 403/405, and the TV reports no volume or channel state.
- A reverse-engineered **MQTT v5 over TLS on 8883** channel provides PIN pairing (HMAC-SHA256), keys, keyboard and deep-link app launch. App list goes through Titan's cloud.
- It has been verified on **one** model, the 2024 55PML9019 (https://github.com/bedirhanyildirim/philips-titan-os-55pml9019-remote/blob/main/docs/TITAN_OS_API.md).
- AirPlay is available only on 4K Philips chassis from 2025.

**North America.** Philips TVs there were Funai-licensed Roku or Android sets that do not speak JointSpace (low confidence).

**Matter.** Philips/TPV TVs hold Matter Basic and Casting Video Player certifications.

### 6.10 Sony BRAVIA

**REST and IRCC.**
- REST JSON-RPC on HTTP 80 at `/sony/{system,audio,avContent,appControl,...}`, plus IRCC (SOAP `X_SendIRCC`).
- Auth is either the `X-Auth-PSK` header or PIN pairing with a cookie. Home Assistant recommends PSK.
- Discovery: SSDP `urn:schemas-sony-com:service:ScalarWebAPI:1`.
- Sources: https://pro-bravia.sony.net/remote-display-control/rest-api/structure/, https://github.com/Drafteed/pybravia

**Simple IP Control.** TCP 20060, fixed 24-byte frames, with power, volume, mute and input push notifications. No authentication.

**BRAVIA Connect gRPC.** 2023+ models; dynamic port advertised over mDNS; needs a Sony account. Reverse-engineered and tested on one model.

**Browser.**
- Sony's own sample `display_control.html` sends cross-origin XHR with a text/plain body, so browser-direct use is intended.
- With **Authentication=None** (offered in a 2020 consumer menu; reportedly dropped on newer models), calls are CORS-simple and therefore write-only.
- With **PSK**, a preflight is required. Firmware variance here is documented only by one new single-author repo (weak source).

**Other notes.**
- Most current BRAVIAs are Google TV, so Remote v2 and Cast also apply.
- An EU RED-DA HTTPS-only variant is documented for Professional Displays.
- `getScreenshot` is localhost-only.
- TV business moves to the TCL-majority BRAVIA Inc. joint venture from April 2027.

### 6.11 Other consumer brands

**Panasonic.**
- Viera SOAP/UPnP on HTTP 55000. Encrypted PIN pairing arrived around 2019.
- Covers keys, apps and RenderingControl volume. Legacy: 2024 flagships run Fire TV, and the 2026 EU range is split across Fire TV, Google TV and TiVo.
- Reference: panasonic-viera (MIT).

**Sharp.**
- AQUOS IP control on TCP 10002 (ASCII). Legacy only.
- Current Sharp-branded TVs run TiVo OS, Roku or Google TV.

**TiVo OS** (Vestel, Sharp, Panasonic and others). No public or reverse-engineered local API was found. A Vestel SmartCenter DIAL-based protocol may apply (unverified; mock-tested only).

**Xumo TVs** (Comcast/Charter). HomeKit for power and input only, no volume. AirPlay also supported. The official apps use an undocumented protocol.

### 6.12 Commercial displays (reference only)

| Protocol | Transport | Notes |
|---|---|---|
| Samsung MDC | TCP 1515 | Optional TLS plus 4-digit PIN |
| LG IP Control / RS-232C-over-IP | TCP 9761 | See 6.2 |
| NEC / Sharp-NEC | TCP 7142 | Official MIT Python SDK |

All are raw TCP, so they need native code or the hub.

### 6.13 Cross-vendor standards and transports

**HDMI-CEC.**
- Needs a host on the TV's HDMI bus:
  - Raspberry Pi: `/dev/cecN` via the vc4 driver.
  - Pulse-Eight USB-CEC adapter: CDC-ACM, VID 0x2548.
  - Some DisplayPort-AUX adapters.
- Standby, Image View On and power status are the most universal power path. Navigation and volume handling vary by vendor.
- The browser path is Web Serial to a Pulse-Eight adapter (secure context only). It includes power-on through Image View On.
- libcec is GPL-2.0+ or commercial, so keep it out of process. cec_linux (Rust, MIT) shows a permissive approach.
- Sources: https://docs.kernel.org/admin-guide/media/cec.html, https://github.com/Pulse-Eight/libcec

**DIAL.** SSDP plus HTTP. Servers enforce per-app Origin allowlists and return 403 even to preflights; Amazon forbids `http:` origins. Can only launch registered apps. Optional `WAKEUP` header and a `system` sleep action (https://github.com/Netflix/dial-reference/blob/master/server/dial_server.c). Fire TV uses DIAL on 8009 to start its remote service.

**UPnP/DLNA MediaRenderer.** SOAP requires `SOAPAction` and `text/xml`, so a preflight is always needed. Provides absolute volume and mute, plus URL casting for its own sessions. Legacy, but useful on Samsung and VIDAA.

**Matter.**
- Video-player device types: Basic 0x0028 and Casting 0x0023. Clusters include OnOff, KeypadInput, MediaPlayback, ContentLauncher LaunchURL, MediaInput, Channel and Messages.
- Few TVs expose them: Philips/TPV, Hisense and Fire TV. LG, Samsung and Google TV act as controllers or hubs.
- The controller path is multi-admin into watchme's own fabric via matter.js (Apache-2.0). Home Assistant has an open draft PR (https://github.com/home-assistant/core/pull/186532). There is no Dart Matter stack.

**Consumer IR.**
- Phone blasters: Android only, via ConsumerIrManager.
- Broadlink: UDP with AES.
- ESPHome: since 2026.7, cross-origin requests return 403 unless the origin is in `allowed_origins`.
- Tasmota: sends CORS headers only in custom USE_CORS builds.
- Code sets: Flipper-IRDB (CC0) fits Apache-2.0. irdb has a custom licence.

**Bluetooth HID.**
- An Android phone can act as a BLE or Classic HID keyboard (`BluetoothHidDevice`, API 28+); this has been tested on an LG G5 (webOS 25).
- A Linux or Raspberry Pi hub can act as a BLE (HOGP) or Classic HID keyboard/remote through BlueZ (`package:bluez`, MPL-2.0, Dart; bleno, MIT, Node). That gives Bluetooth control to every hub client, iPhones included. Unverified per TV.
- Web Bluetooth (Chromium, central only, secure context) can drive a custom ESP32 BLE bridge that emits IR, CEC or BLE HID.
- iOS cannot act as a HID peripheral, and Web Bluetooth blocklists the HID service, so neither an iPhone app nor a page can be a Bluetooth remote.
- LG's "Turn on via Bluetooth" (ThinQ, Android only) uses an undocumented BLE protocol (open question).

**Wake-on-LAN.** UDP broadcast magic packet.
- iOS needs the multicast entitlement for broadcast; macOS does not.
- The Dart `wake_on_lan` package is GPL-3.0; reimplement it in about 20 lines.

**Cloud APIs.**

| API | Status |
|---|---|
| SmartThings | See 6.1 |
| Google Home APIs | Native SDKs only, registration closed |
| HomeKit | Native iOS only |
| Alexa | No third-party controller API |
| LG ThinQ | No TVs |

## 7. Native platform requirements

**iOS** (TN3179, revised 2026-10-06).
- Any LAN TCP or UDP needs Local Network permission and `NSLocalNetworkUsageDescription`.
- Bonjour browsing via NWBrowser (bonsoir/nsd) needs only `NSBonjourServices` entries. Candidate types:
  - `_androidtvremote2._tcp`, `_googlecast._tcp`, `_airplay._tcp`
  - `_companion-link._tcp`, `_viziocast._tcp`, `_philipstv_s_rpc._tcp`
  - `_amzn-wplay._tcp`, `_hap._tcp`, `_secure-mqtt._tcp`, `_matterd._udp`
- **UDP multicast and broadcast** (SSDP, raw mDNS, broadcast WoL) also need the restricted `com.apple.developer.networking.multicast` entitlement. Unicast WoL to a known IP does not.
- The entitlement is granted per team and can be requested before the app exists (enter N/A for the App Store URL).
- `_airplay._tcp` also finds AirPlay-capable Samsung and LG TVs.
- Reported entitlement turnaround ranges from about a week to about 30 days (2020-2023 data).
- No BLE HID peripheral; no IR.
- `SecurityContext` client certificates on iOS: only PKCS12 via `usePrivateKey`. Unproven on device for Android TV v2.

**Android.**
- Receiving multicast needs a `MulticastLock`.
- Android 16 makes local network protection opt-in. Android 17 enforces `ACCESS_LOCAL_NETWORK` (NEARBY_DEVICES group) for apps targeting SDK 37. It blocks TCP, UDP, mDNS and SSDP.
- WebViews inherit the host app's permission, and the doc gives browser-specific guidance, so on Android 17 browsers that target SDK 37 will probably need the grant before a LAN page (including a hub-served UI) works (inference).
- The NsdManager system picker exempts the addresses it returns, but covers mDNS only.
- Also: a cleartext network-security config for LAN http, `BluetoothHidDevice` (API 28+), and `ConsumerIrManager` (`TRANSMIT_IR`).

**macOS 15+.**
- Local network prompt; no multicast entitlement.
- Sandboxed apps need `com.apple.security.network.client` (and `.server` to host).
- launchd daemons are exempt from the prompt; launchd agents are not.

**Linux hub.**
- `dart compile exe --target-os=linux --target-arch=arm64` (Dart 3.8+). Packages with build hooks need `dart build`.
- bonsoir and nsd are Flutter-only, so use `multicast_dns` or Avahi over D-Bus. Coexistence with avahi-daemon on port 5353 is untested.
- CEC via `cec-ctl`.
- Bluetooth HID peripheral via BlueZ over D-Bus (`package:bluez`, MPL-2.0) or a helper process.

## 8. Dart/Flutter implementation feasibility

**`dart:io` covers everything needed:**
- `RawDatagramSocket` for SSDP, WoL and `joinMulticast`.
- `SecureSocket` with `SecurityContext.useCertificateChainBytes` / `usePrivateKeyBytes`, `onBadCertificate` and `peerCertificate` for mTLS (Android TV).
- `WebSocket.connect(customClient: HttpClient()..badCertificateCallback=...)` for self-signed wss on Samsung 8002 and LG 3001. It adds no Origin header, which also sidesteps LG's Origin check.
- `HttpClientDigestCredentials` for Philips.
- `Socket` plus pointycastle AES/PBKDF2 for LG IP Control.

**Flutter web gets none of this.** It has exactly the browser's limits. By default it also loads CanvasKit/skwasm and fallback fonts from Google's CDNs; an offline LAN build needs `--no-web-resources-cdn` and bundled fonts.

| Need | Package | License | Version (date) |
|---|---|---|---|
| Protobuf | protobuf / protoc_plugin | BSD-3 | 6.1.0 / 25.1.0 (2026-09-11) |
| RSA, ASN.1, SRP6, AES, PBKDF2 | pointycastle | MIT | 4.0.0 (2025-02-19) |
| Certificate generation | basic_utils | MIT | 5.8.2 (2025-02-23) |
| ASN.1 walking | asn1lib | BSD-2 | 1.6.5 |
| Ed25519, X25519, ChaCha20-Poly1305, HKDF | cryptography | Apache-2.0 | 2.9.0 (2025-11-21) |
| mDNS (raw sockets; works in the pure-Dart hub) | multicast_dns | BSD-3 | 0.3.3+1 (2026-06-09) |
| Bonjour via NWBrowser (Flutter) | bonsoir / nsd | MIT | 7.1.5 / 5.0.1 |
| WebSocket | web_socket_channel | BSD-3 | 3.0.3 |
| HTTP | http | BSD-3 | 1.6.0 |
| Hub server | shelf / shelf_router / shelf_static / shelf_web_socket | BSD-3 / Apache-2.0 / BSD-3 / BSD-3 | 1.4.3 / 1.1.5 / 1.2.0 / 3.0.0 |
| UPnP/DLNA | upnp_client | MIT | 1.5.0 (2026-08-24) |
| Cast (pure Dart) | dart_cast | MIT | 0.7.4 (2026-08-16) |
| Cast (native SDK wrapper, mobile) | flutter_chrome_cast | BSD-3 | 2.0.0 |
| ADB (pure Dart, incl. SPAKE2/STLS) | flutter_adb | BSD-3 | 1.0.0 (2026-03-20) |
| BLE (avoid flutter_blue_plus) | universal_ble / flutter_blue_ultra / bluetooth_low_energy | BSD-3 / BSD-3 / MIT | 3.1.2 / 2.2.0 / 6.2.1 |
| BLE peripheral advertising | flutter_ble_peripheral | BSD-3 | 3.1.0 |
| BlueZ D-Bus client (hub HID peripheral) | bluez | MPL-2.0 (ASF Category B: unmodified dependency only) | 0.9.0 (2026-10-13) |
| Serial (desktop / Android) | flutter_libserialport / usb_serial | MIT / BSD-3 | 0.6.0 / 0.5.2 |
| Android multicast lock | flutter_multicast_lock | MIT | 1.2.1 |
| MQTT (VIDAA / Titan) | mqtt_client / mqtt5_client | license not verified in research | - |

**Existing Dart TV packages are thin or broken:**
- webos_remote: signed manifest.
- tizen_api: 2024, thin.
- `androidtvremote`: discontinued.
- android_remote_pro: template README.
- `bravia`: 2021.
- Nothing for Roku, Vizio, Philips, Apple TV or LG IP Control.

**Reference Flutter apps:** amolood/Universal-Remote (MIT) and mazen-salah/Smart-TV-Remote-Control (MIT).

## 9. Libraries and licences

**Rules for an Apache-2.0 project** (https://www.apache.org/legal/resolved.html):

| ASF category | Licences | What watchme may do |
|---|---|---|
| A | Apache, MIT, BSD, ISC | Port the code, keeping notices |
| B | MPL, EPL | Use as unmodified binary dependencies only; read for reference |
| X | GPL, LGPL, AGPL | Read only. Never copy. |

Repos with no licence must not be copied. Libraries vendoring extracted vendor secrets must not be copied either.

| Library | Lang | Licence | Last activity | watchme use |
|---|---|---|---|---|
| homebridge-samsung-tizen | TS | MIT | v6.1.0 2026-10-16 | Samsung port basis |
| samsung-tv-remote (Badisi) | TS | MIT | v3.0.12 2026-09-18 | Samsung reference |
| samsungtvws | Python | LGPL-3.0 | v3.0.6 2026-09-11 | Read only |
| NickWaterton samsung-tv-ws-api | Python | LGPL-3.0 | 2026-04-06 | Read only (Frame art) |
| ha-samsungtv-smart | Python | Apache-2.0 repo; `api/samsungws.py` is LGPL-2.1+ | 2026-05-26 | Read only for that file |
| openHAB samsungtv | Java | EPL-2.0 | 2026-09 | Read only |
| tizen_api | Dart | BSD-3 | 1.0.11 2024-11 | Thin; not a dependency |
| async-upnp-client | Python | Apache-2.0 | 0.49.0 2026-10-11 | UPnP reference |
| smartthings-core-sdk | TS | Apache-2.0 | 2026-09-02 | SmartThings reference |
| homebridge-smartthings-tv | TS | MIT | 2026-10-21 | SmartThings TV capability reference |
| aiowebostv | Python | Apache-2.0 | 0.10.0 2026-08-28 | LG port basis |
| bscpylgtv | Python | MIT | 0.5.5 2026-09-30 | LG reference (luna, screenshot) |
| lgtv2 | JS | MIT | 2.1.0 2026-10-14 | LG reference (WoL, certificate pins) |
| LGTVCompanion | C++ | MIT | 5.7.0 2026-08-17 | LG reference (2026 permissions) |
| homebridge-lgwebos-tv / homebridge-webos-tv | JS | MIT | 4.10.0 / 2.5.0 (2026) | LG reference; do not copy the "LG Mobile" signed manifest |
| Connect SDK (Android Core) | Java | Apache-2.0 | 2026-01 | LG reference (official) |
| webos_remote | Dart | MIT | 1.0.0 2026-08-05 | Reference; broken on webOS 26 |
| webos-ssap-web (Informatic original) | JS | MIT | 2023-01 | Origin:null iframe reference; reimplement cleanly |
| webos-ssap-web (throwaway96 fork) | JS | AGPL-3.0 | 2024-07 | Do not copy |
| lgtv-ip-control | TS | MIT | v4.4.0 2025-12-27 | LG IP Control port basis |
| androidtvremote2 | Python | Apache-2.0 | 0.3.2 2026-09-01 | Android TV port basis |
| google-tv-pairing-protocol (AOSP) | Java | Apache-2.0 | 2017 | Pairing reference |
| @kud/androidtv-remote | TS | MIT | 0.1.2 2026-07-10 | Reference |
| Universal-Remote (amolood) | Dart | MIT | 2026-06-08 | Dart Android TV v2 reference |
| pychromecast | Python | MIT | 14.0.10; pushed 2026-10-20 | Cast reference |
| go-chromecast | Go | Apache-2.0 | 2026-10-12 | Cast reference |
| Open Screen | C++ | BSD-3 | 2026-10-21 | Cast spec-grade reference |
| dart_cast | Dart | MIT | 0.7.4 2026-08-16 | Candidate dependency / reference |
| flutter_adb | Dart | BSD-3 | 1.0.0 2026-03-20 | Candidate dependency (advanced ADB) |
| Tango (@yume-chan/adb) | TS | MIT | 2.6.4 2026-09-02 | Reference |
| adb_shell / python-androidtv | Python | Apache-2.0 / MIT | 2024 | Reference (shell command catalogue) |
| libadb-android | Java | GPL-3.0+ OR Apache-2.0 (LGPL dependency) | 2026-06 | Read only |
| python-rokuecp | Python | MIT | 0.19.5 2025-06-14 | Roku reference |
| node-roku-client | TS | Apache-2.0 (GitHub shows NOASSERTION) | v6.0.0 2026-02-12 | Roku reference |
| brs-engine / brs-desktop | TS | MIT | 2026-10 | Roku simulator for tests |
| Media-Assistant | BrightScript | Apache-2.0 | 2026-08-26 | Roku cast receiver to target |
| Roam | Swift | PolyForm-Noncommercial | 2026-10-20 | Do not copy |
| LibreControl/fire-tv | TS | MIT | 2026-10-19 | Fire TV reference |
| hms-firetv | C++ | MIT | 2026-09-29 | Fire TV endpoint reference |
| firetv-cec-volume | C++/sh | MIT | 2026-10-16 | Vega volume evidence |
| Netflix dial-reference | C | BSD-2 | 2021 | DIAL reference |
| connectedhomeip tv-casting-app | C++/Java/ObjC | Apache-2.0 | 2026-10-21 | Matter Casting reference |
| matter.js / matterjs-server | TS | Apache-2.0 | 0.18.0 / 1.5.2 (2026-10) | Matter driver host |
| pyatv | Python | MIT | 0.18.0 2026-06-19 | Apple TV reference / sidecar |
| node-pyatv | TS | MIT | 10.0.1 2026-07-24 | Wraps the pyatv CLI |
| aiohomekit / HAP-NodeJS | Python / TS | Apache-2.0 | 2026-10-20 | HomeKit reference |
| hap-controller-node | TS | MPL-2.0 | 2026-06-15 | Read / binary dependency only |
| vizaio | Python | MIT | 0.7.0 2026-09-07 | Vizio port basis |
| pyvizio | Python | MIT | 0.1.64 2026-01-16 | Vizio reference |
| hisense_vidaa | Python | MIT | 2026-10-20 | VIDAA reference |
| pyvidaa | Python | MIT | 2026-08-05 | VIDAA reference |
| vidaa-control / ioBroker.vidaa | Python / JS | MIT (bundles vendor certificates) | 2026 | Read only; never copy the certificates |
| ha-philipsjs | Python | MIT | 3.3.0 2026-10-14 | Philips port basis |
| pylips | Python | MIT | 2026-05 (docs) | Philips endpoint reference |
| ha-philips-titanos | Python | Apache-2.0 | 2026-10-20 | Titan reference |
| philips-titan-os-55pml9019-remote | Swift + docs | MIT | 2026-10-20 | Titan MQTT reference |
| pybravia | Python | MIT | 0.5.3 2026-08-24 | Sony port basis |
| bravia-http-remote | JS + Python | MIT | v1.4.0 2026-10-14 | Sony browser evidence (weak) |
| panasonic-viera | Python | MIT | 0.4.6 2026-09-14 | Panasonic reference |
| sharp_aquos_rc | Python | MIT | 2017 code | Sharp reference |
| samsung-mdc | Python | BSD-3 | v1.18.0 2026-07-27 | MDC reference |
| nec-pd-sdk | Python | MIT | 2023-08 | NEC reference |
| libcec | C++ | GPL-2.0+ / commercial | 8.1.7 2026-09-02 | Out of process only |
| cec_linux | Rust | MIT | 0.2.2 2026-02-26 | CEC uAPI reference |
| pycec | Python | MIT | 2026-04 | CEC TCP bridge reference |
| peer-dial | JS | LGPL-3.0 | 2025-03 | Read only |
| upnp_client | Dart | MIT | 1.5.0 2026-08-24 | Candidate dependency |
| python-broadlink | Python | MIT | 0.19.0 2024 | Broadlink reference |
| Flipper-IRDB | data | CC0-1.0 | 2026-04-12 | IR code source |
| irdb | data | Custom (notice, notify, free units) | 2026-01 | Avoid unless conditions are acceptable |
| IRremoteESP8266 | C++ | LGPL-2.1 | 2026-08 | Separate firmware only |
| ESPHome / Tasmota | C++ | GPL-3.0 (ESPHome Python part is MIT) | 2026-10 | External bridges only |
| bluez (Dart) | Dart | MPL-2.0 | 0.9.0 2026-10-13 | Hub HID peripheral; unmodified, labelled dependency |
| bleno | JS | MIT | 2025-02-05 | Linux BLE peripheral reference |
| BLE-HID-Peripheral-for-Android | Java | Apache-2.0 | 2026-09-23 | BT HID reference |
| bluetooth-tv-remote (GoldenGuts) | Java/Swift | GPL-3.0 | 2026-10-15 | Read only |
| wake_on_lan (Dart) | Dart | GPL-3.0 | 2023 | Do not use |
| flutter_blue_plus | Dart | FlutterBluePlus License v1.6: paid for any for-profit organisation, relicensing banned, build-time telemetry | 2.3.14 2026-10-03 | Do not use |

## 10. Market share

Metrics differ: installed-base usage, unit shipments and ad share-of-voice are not comparable. Most figures come via press coverage.

| Source | Scope | Figures |
|---|---|---|
| Parks Associates (reported 2026-04-23) | US broadband households, CTV OS usage | Roku 28%, Tizen 23% |
| Pixalate Q1 2026 | North America open-programmatic CTV ad share-of-voice | Roku 36%, Fire TV 19%, Samsung 15%, Apple TV 13% |
| Kagan / S&P (via LinkedIn; weak) | US smart TV OS | Roku 25, Fire TV 17, Tizen 14, Android TV 14, webOS 9, Vizio 7, tvOS 4, Xumo 2, other 8 |
| Omdia (2026-01-26) | North America TV OS units | Retailer-owned OSes (Walmart Vizio "CastOS" + Fire TV): 27% in 2025, forecast 47% by 2029 |
| Omdia (via 9to5Google, April 2026) | North America | Google TV under 10% |
| Omdia 2025 (via LG report) | Global TV OS shipments | Android/Google TV 42%, Tizen 17%, VIDAA 6%, Fire TV 4% |
| Omdia (via FlatpanelsHD / 9to5Google, April 2026) | Europe smart TV shipments | Google TV just under 33% (2024), under 31% (2026); Tizen under 25%; VIDAA overtakes webOS in 2026; Titan, TiVo, Fire TV and Roku each about 5% or less |
| TechInsights Q4 2024 (page now 403; unverified) | Global shipments | Android/Google TV over 24%, Tizen 16.9%, webOS 11.8%, Roku 9% |

Installed base:

| Platform | Figure | Status |
|---|---|---|
| Samsung Tizen | 270M TVs, end-2023 | Verified |
| LG webOS | 260M devices incl. monitors and more than 10M partner TVs, 2025 | Verified |
| Android TV OS | 220M monthly active devices, May 2024 | Verified |
| Fire TV | 250M+ sold | Unverified |
| Roku | About 100M households, July 2026 letter | Secondary source |

**Implication.**
- No single local standard covers a majority of TVs.
- In the US, Roku, Samsung, Fire TV and Vizio dominate. Elsewhere, Android/Google TV, Samsung, LG and VIDAA do.
- HDMI-CEC and IR are the only universal channels, and both need local hardware.

## 11. Developer LAN observations (passive, 2026-10-20)

**Amazon Fire TV at 192.168.1.7.**
- `_matterd._udp` is Matter commissioner discovery, so the device is a Matter Casting player. That points to Fire OS 7+ or Vega.
- `amzn.dmgr` is the WhisperPlay token that tools use to identify Fire TVs, so the Fire TV app remote stack (8009 DIAL wake, 8080 HTTPS, 9090 voice) should be present.
- These records cannot distinguish Fire OS from Vega. Check under Settings > My Fire TV > About. Both expose the 8080 API; only Fire OS offers ADB.
- Some sticks are discoverable only through SSDP/DIAL, so an SSDP scan should also see it once the firewall question below is settled.
- **No browser-direct remote-control path reaches this device.**

**Apple device at 192.168.1.40.**
- It advertises `_remotepairing._tcp`, whose meaning the research did not cover (unverified).
- An Apple TV would normally also advertise `_airplay._tcp` (model AppleTV*) and `_companion-link._tcp`, per pyatv's discovery types. Neither was seen, so this may be an iPhone, iPad or Mac (inference).
- Passive capture may be incomplete.
- No browser-direct remote-control path reaches it. If it is an Apple TV, Safari could AirPlay a media URL to it through Remote Playback.

**SSDP.**
- M-SEARCH got no replies. Check the host firewall (replies arrive as unicast UDP to an ephemeral port) before concluding that no SSDP devices exist.
- No Samsung, LG, Roku, Android TV or Vizio services were seen.

**Rule.** Do not probe devices the developer does not own.

## 12. Verifier corrections that change decisions

**Browsers**
1. **Chrome gates WebSockets under LNA since 147** (2026-04-07). Several drafts said WebSockets were not gated.
2. **Firefox has LNA prompts (153+) but no mixed-content relaxation.** http:// and ws:// to the LAN from HTTPS pages stay blocked, so that transport is Chromium-only.
3. **Self-signed wss and cloud HTTPS are not mixed content.** Samsung wss works in Firefox after a permanent certificate exception plus the LNA prompt, and SmartThings works in every browser. "Browser-direct is Chromium-only" is true only for http/ws to the LAN.
4. **Chrome's certificate-error bypass lasts 7 days** and is per host. Browser-direct wss needs weekly re-onboarding.
5. **Safari self-signed wss is unverified, not proven broken.** The old evidence predates WebKit's current WebSocket stack.
6. **Cast Web Sender is "works with user steps".** The user picks the device, it needs HTTPS, and it does not work on iOS Chrome. Safari offers AirPlay through Remote Playback instead.
7. **node-forge cannot do modern TLS** (TLS 1.0/1.1 only). In-page TLS over a relay is not a shortcut.
8. **ESPHome 2026.7 enforces an origin allowlist.** IR bridges need configuration before a web UI can call them.
9. **Pages have a few power-on paths.** Web Serial CEC or IR, SmartThings, or a TV whose network is still awake. Wake-on-LAN and wake from deep standby remain impossible.
10. **Chrome's temporary LNA opt-out policy:** chromestatus lists removal at 156, but the policy definition on Chromium main still supports it and says removal after M163 (verified 2026-10-21).

**Platforms**
11. **SmartThings is not a dependable free fallback.** Paid tiers were announced 2026-06-23, OAuth needs the client secret, and PATs last 24 h.
12. **SmartThings from a browser must use `api.smartthings.com/oauth/token`.** `auth-global.api.smartthings.com` rejects CORS preflights. A shared app may be capped at 20 installs.
13. **LG 2026:** a custom signed manifest also breaks the pointer socket (and with it d-pad and keys). The unsigned fix loses direct settings writes even on older TVs. One webOS 26 model still fails.
14. **LG's browser path is blocked by unverified LNA delegation, not by licensing.** The Origin:null iframe exists in an MIT original; the AGPL fork is only one implementation.
15. **Android 13 for TV was developer-only.** Wireless ADB on consumer TVs means Android TV 14+. CVE-2026-0073 affects Android 14-16.
16. **Roku 403s on web requests came from hostname Host headers, not Origin.** Limited mode is the effective default since 14.1.
17. **pyatv does not work cleanly on tvOS 26/27.** Apple TV support carries maintenance risk.
18. **Fire TV volume and mute exist** through the 8080 API, as CEC steps confirmed on Vega only.
19. **Fire TV discovery and wake:** a stick may advertise only via SSDP/DIAL, and :8080 does not listen until the DIAL wake on :8009.
20. **VIDAA has an unauthenticated UPnP DMR on 38400.** Some MIT repos bundle vendor client certificates; do not copy them.
21. **LG IP Control can launch apps** and is a real fallback independent of the SSAP manifest.
22. **Sony `getScreenshot` is localhost-only.** It is not a LAN feature.

**Native platforms**
23. **The iOS multicast entitlement is also required for UDP broadcast,** which includes Wake-on-LAN. It is not required on macOS.
24. **Android 17 enforces ACCESS_LOCAL_NETWORK** for apps targeting SDK 37. Browsers are likely affected too.

**Licensing**
25. **ha-samsungtv-smart contains LGPL code.** flutter_blue_plus is no longer open source in practice.
26. **Several homebridge plugins listed as active are stale:** homebridge-roku (2021), homebridge-roku-tv (2020), homebridge-bravia-tvos (2022), homebridge-vizio (2022).

## 13. Open questions and hardware tests

**Browser behavior.** Test on owned hardware only.
- Do Samsung 2018/2021/2024+ sets accept a foreign Origin on wss:8002?
- Do Samsung 2020-2026 firmwares still send `ACAO: *` on `/api/v2/`?
- Does Safari 27 honour a manually accepted certificate for wss?
- Does Chromium 147+ exempt `ws://<private-IP>` from mixed content after the LNA grant? There is vendor evidence only.
- Does Firefox treat private-IP literals like `.local`? Bug 2081728 tested `.local` only.
- Does Vizio 7345 answer a CORS preflight for PUT plus AUTH?
- Does LG still enforce the Origin check on wss:3001 and on webOS 25/26?
- Does Chrome honour `allow="local-network"` delegation to a `data:` or sandboxed opaque-origin iframe, so the LG Origin:null proxy can open wss:3001?
- On Android 17, will Chrome require the OS local-network grant before any LAN page works, including the hub-served UI?
- Does the Flutter web `--wasm` build run acceptably on a non-secure, non-cross-origin-isolated http origin, or must the hub ship the CanvasKit JS target?

**Vendor behavior.**
- Is the Samsung 2026 `ms.channel.timeOut` lock-down deliberate, and is it spreading?
- Can LG's unsigned manifest keep pointer and IME access, and why does one C6 still fail?
- Does Android TV accept a client-sent absolute volume? Which models honour `KEYCODE_WAKEUP` as a discrete power-on?
- Will Google restore launch-by-package?
- Does the Fire TV 8080 API support volume on Fire OS, and will Amazon rotate the static key?
- Will a test-attested Matter Casting client be accepted by a retail Fire TV?
- Does Roku's "3rd-party platforms" ECP clause bind external controllers?
- What are SmartThings' final pricing and install caps?
- Will pyatv merge its tvOS 26/27 fixes?
- Does `executeOneShot` (LG screenshot) work with an unsigned key?
- Which TV OSes accept a Bluetooth HID keyboard from an Android phone or a Linux BlueZ peripheral (Android/Google TV, Fire TV, Tizen, webOS, Roku), and can a bonded HID device wake the TV? What protocol does LG's "Turn on via Bluetooth" use?

**Platform.**
- Do `dart:io` client certificates work on iOS hardware?
- What is the real 2026 turnaround for the iOS multicast entitlement?
- Do `multicast_dns` and avahi-daemon coexist on a Raspberry Pi hub?
- Can a BlueZ HID peripheral (BLE HOGP or Classic) on a Pi pair reliably with TVs, alongside the hub's other Bluetooth use?
- Do Roku and Sony advertise `_airplay._tcp`? If so, entitlement-free iOS discovery would cover them.

**Developer LAN.**
- Is the Fire TV on Fire OS or Vega?
- Is 192.168.1.40 an Apple TV?
- Is the host firewall dropping SSDP replies?

## 14. Key sources

**Browsers and OS**
- Chrome LNA: https://developer.chrome.com/blog/local-network-access ; https://chromestatus.com/feature/5152728072060928 ; https://chromestatus.com/feature/5197681148428288
- Chrome LNA opt-out policy definition: https://chromium.googlesource.com/chromium/src/+/main/components/policy/resources/templates/policy_definitions/LocalNetworkAccessSettings/LocalNetworkAccessRestrictionsTemporaryOptOut.yaml
- WICG LNA spec: https://wicg.github.io/local-network-access/
- Firefox: https://bugzilla.mozilla.org/show_bug.cgi?id=2081728 ; https://www.firefox.com/en-US/firefox/153.0/releasenotes/
- WebKit: https://bugs.webkit.org/show_bug.cgi?id=171934 ; https://github.com/WebKit/WebKit/blob/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
- Web Bluetooth GATT blocklist: https://github.com/WebBluetoothCG/registries/blob/master/gatt_blocklist.txt
- Apple TN3179: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Android local network permission: https://developer.android.com/privacy-and-security/local-network-permission
- Fetch spec (CORS-safelisted): https://fetch.spec.whatwg.org/#cors-safelisted-request-header

**Samsung**
- https://github.com/xchwarze/samsung-tv-ws-api
- https://github.com/tavicu/homebridge-samsung-tizen
- https://image-us.samsung.com/SamsungUS/samsungbusiness/tv-ci-resources/Samsung-IP-Control.pdf
- https://developer.smartthings.com/docs/service-integrations/oauth

**LG**
- https://github.com/home-assistant-libs/aiowebostv
- https://github.com/home-assistant/core/issues/172703
- https://github.com/JPersson77/LGTVCompanion/issues/351
- https://github.com/WesSouza/lgtv-ip-control
- https://github.com/Informatic/webos-ssap-web

**Android TV and Cast**
- https://github.com/tronikos/androidtvremote2
- https://developers.google.com/cast/docs/web_sender
- https://github.com/home-assistant-libs/pychromecast

**Roku**
- https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md
- https://support.roku.com/article/217288467
- https://github.com/lvcabral/brs-desktop

**Fire TV**
- https://community.home-assistant.io/t/rest-commands-for-fire-tv/901314
- https://github.com/LibreControl/fire-tv ; https://github.com/LibreControl/fire-tv/blob/main/docs/protocol.md
- https://developer.amazon.com/docs/fire-tv/overview-of-matter-casting.html

**Apple TV:** https://pyatv.dev/documentation/protocols/ ; https://github.com/postlund/pyatv/issues/2837

**Vizio:** https://github.com/raman325/vizaio

**VIDAA:** https://github.com/stevene1919/hisense_vidaa

**Philips:** https://github.com/danielperna84/ha-philipsjs ; https://github.com/bedirhanyildirim/philips-titan-os-55pml9019-remote

**Sony:** https://pro-bravia.sony.net/remote-display-control/rest-api/guide/ ; https://github.com/Drafteed/pybravia

**Cross-vendor:** https://docs.kernel.org/admin-guide/media/cec.html ; https://github.com/Netflix/dial-reference ; https://github.com/project-chip/connectedhomeip/tree/master/examples/tv-casting-app ; https://github.com/matter-js/matter.js ; https://github.com/GoldenGuts/bluetooth-tv-remote ; https://pub.dev/packages/bluez

**Dart:** https://api.dart.dev/dart-io/SecurityContext-class.html ; https://dart.dev/tools/dart-compile ; https://github.com/amolood/Universal-Remote

**Licensing:** https://www.apache.org/legal/resolved.html
