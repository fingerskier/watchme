# watchme architecture proposal

Status: accepted for M0, 2026-10-21. Companion to [`docs/research/tv-control-landscape.md`](../research/tv-control-landscape.md). Licence: Apache-2.0.

M0 implements a subset of this document: `watchme_core`, `watchme_io`, `watchme_engine`, `watchme_testkit` (fakes, the Roku and Fire TV simulators and `dart run watchme_testkit:sim`), the Roku and Fire TV drivers, `watchme_e2e` (the engine, real `dart:io` transports and both drivers against the simulators on loopback), and the Flutter app on the in-process engine. Everything else here is the plan, not the code. Where the M0 code departs from the sketches below, the code is authoritative; §2.9 lists the differences.

## 0. Decisions in one screen

| Decision | Choice | Why |
|---|---|---|
| First surface | **Flutter app with the engine in-process** (Linux desktop first, then Android/iOS). The hub-served web UI follows in M1 on the same engine. | The owner's rule: "begin with a web app if a web app can control a TV, otherwise the Flutter app." The research shows a browser page cannot: browser-direct control covers only a few protocols, varies by browser and transport, cannot discover TVs or send Wake-on-LAN, and reaches neither device on the dev LAN. A web UI is still possible once a small LAN hub speaks the protocols natively (§5.1); that hub is a thin shell over the same engine the app embeds, so nothing built first is thrown away. |
| Protocol core language | **Dart**, pure packages behind transport interfaces | One implementation serves the Flutter app (in-process), the hub (`dart compile exe`) and the web build (shared models and optional browser-direct drivers). `dart:io` covers mTLS, raw TCP, UDP, multicast and self-signed WSS (proven for Android TV Remote v2 by a Flutter app). |
| Transports | A `Transports` bundle: network, serial, BLE central, HID peripheral, IR emitter, subprocess | CEC (`cec-ctl`), Bluetooth HID, IR and USB/Web Serial dongles are real drivers and must be expressible, testable and gateable like network drivers. |
| UI toolkit | Flutter for all surfaces; web build first, built to run with no internet | One UI codebase for web, desktop and mobile. The API is plain JSON/WebSocket, so a lightweight TS/HTML UI can replace the web build if Flutter web proves too heavy on cheap phones or on a non-secure http origin. |
| Hub | Dart CLI (shelf) on Linux x64/arm64 (Raspberry Pi), or embedded in the desktop app; on the TVs' subnet with a stable address | Same engine as the apps. Cross-compiles to arm64 (Dart 3.8+). |
| Bluetooth | Hub BLE/Classic HID peripheral via BlueZ (for every client), Android in-process HID, optional ESP32 BLE bridge | The README lists Bluetooth as a headline feature. iOS and browsers cannot act as HID peripherals. |
| Non-Dart code | Out-of-process "driver hosts" only (e.g. matter.js, a temporary pyatv sidecar) speaking a JSON-RPC driver protocol | Keeps the core single-language while allowing ecosystems Dart lacks (Matter). |
| Drivers | Per protocol, composable per device; capabilities declared statically and refined at runtime; every driver backend tagged with the targets it runs on | Firmware churn (LG 2026 manifest blacklist, Samsung 2026 timeouts, Roku Limited mode) means static tables lie. |

## 1. Layers

```
+------------------------------------------------------------------------+
| Surfaces                                                               |
|  Web UI (Flutter web)   Flutter app: Android / iOS / macOS / Win / Linux|
|  CLI (dev tool)         Optional direct-mode web build (public HTTPS)  |
+---------------+-----------------------------------+--------------------+
                | WatchmeClient (interface in core)  |
        HubClient (HTTP + WebSocket)          InProcessClient
                |                                    |
+---------------v------------------+                 |
| watchme_hub (shelf)              |                 |
|  static web UI, /api/v1, /ws     |                 |
|  client auth, Host/Origin checks |                 |
+---------------+------------------+                 |
                +---------------> watchme_engine <----+
                                  - device registry + identity merge
                                  - discovery orchestration
                                  - pairing orchestration (one owner per pairing)
                                  - capability router + fallbacks
                                  - power orchestrator (state machine)
                                         |
                    drivers (one package per protocol family, backends target-tagged)
                                         |
  Transports: NetworkStack | SerialPortProvider | BleCentral | HidPeripheral | IrEmitter | ProcessRunner
  + DiscoveryProvider | CredentialStore | Clock                               (interfaces, core)
                                         |
  io impl (dart:io, libserialport, cec-ctl)    platform impls (Android/iOS plugin, BlueZ on the hub)
  browser impl (package:web: fetch/WS, Web Serial, Web Bluetooth)    fakes + simulators (testkit)
```

Rule: **drivers never import `dart:io`, `package:web` or a Flutter plugin.** They talk only to the `Transports` interfaces. That keeps them unit-testable against fakes, and lets the same driver compile for the web, where the engine enables it only if the browser's transports provide the features it declares. Backends whose transport exists on one platform only (CEC via `cec-ctl`, Android IR, BlueZ HID) are still written against the interfaces; they are tagged by target so CI and the engine know where they can run (§2.6, §4).

## 2. Core abstractions (sketches)

All sketches live in `watchme_core`: pure Dart, web-safe, JSON-serialisable DTOs.

### 2.1 Capabilities

The research uses 18 capability ids. The model keeps them and adds qualifiers that the UI and the router both need.

```dart
enum Capability {
  powerOff, powerOn, powerState, volume, mute, dpadNavigation, systemKeys,
  textInput, appList, appLaunch, inputSwitch, channel, mediaTransport,
  nowPlaying, pointer, notificationToast, screenshot, castMediaUrl,
}

enum Support { yes, partial, no, unknown }

enum CapFlag {
  relativeOnly,        // volume up/down only (Samsung WS, Roku, Android TV)
  writeOnly,           // no readback (browser no-cors, IR)
  toggleOnly,          // KEY_POWER-style toggles: router needs agreed state first (§2.8)
  needsNetworkStandby, // power-on works only while the TV NIC stays up
  needsKeyboardOpen,   // text works only while the TV IME is active
  sessionScoped,       // affects only media we started (Cast, DLNA)
  takesOverScreen,     // launching a receiver interrupts viewing
  cloud,               // needs internet: vendor cloud, cloud-hosted catalog or receiver app
                       // (SmartThings, Titan app list, Vizio app catalog, Cast receivers)
  undocumented,        // reverse-engineered; may break on a firmware update
  userSetupRequired,   // hidden menu, developer mode, "Control by mobile apps"...
}

final class CapabilitySupport {
  const CapabilitySupport(this.capability, this.level, {this.flags = const {}, this.note});
  final Capability capability;
  final Support level;
  final Set<CapFlag> flags;
  final String? note; // human text, e.g. "deep links only since Aug 2026 Play Store change"
}
```

### 2.2 Keys and commands

```dart
enum RemoteKey {
  up, down, left, right, select, back, home, menu, info, guide, exit, settings, search,
  volumeUp, volumeDown, mute, channelUp, channelDown, previousChannel,
  digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9,
  red, green, yellow, blue,
  play, pause, playPause, stop, rewind, fastForward, next, previous, record,
  power, powerOn, powerOff, input, inputHdmi1, inputHdmi2, inputHdmi3, inputHdmi4,
  inputTuner, captions,
}
enum KeyAction { click, down, up } // down/up give hold and long-press where supported

sealed class Command { const Command(); }
final class PressKey extends Command   { const PressKey(this.key, [this.action = KeyAction.click]); final RemoteKey key; final KeyAction action; }
final class SetPower extends Command   { const SetPower(this.on); final bool on; }
final class SetVolume extends Command  { const SetVolume(this.level); final int level; }   // 0..100
final class StepVolume extends Command { const StepVolume(this.steps); final int steps; }  // +/- n
final class SetMute extends Command    { const SetMute(this.muted); final bool? muted; }   // null = toggle
final class LaunchApp extends Command  { const LaunchApp(this.appId, {this.deepLink}); final String appId; final Uri? deepLink; }
final class SelectInput extends Command{ const SelectInput(this.inputId); final String inputId; }
final class TuneChannel extends Command{ const TuneChannel(this.channel); final String channel; }
final class TypeText extends Command   { const TypeText(this.text, {this.replace = false}); final String text; final bool replace; }
final class Media extends Command      { const Media(this.action, {this.seekTo}); final MediaAction action; final Duration? seekTo; }
final class MovePointer extends Command{ const MovePointer(this.dx, this.dy, {this.click = false}); final int dx, dy; final bool click; }
final class ShowToast extends Command  { const ShowToast(this.message); final String message; }
final class CastUrl extends Command    { const CastUrl(this.url, {this.mimeType, this.title}); final Uri url; final String? mimeType; final String? title; }
final class TakeScreenshot extends Command { const TakeScreenshot(); }

sealed class CommandResult {}
final class Confirmed extends CommandResult {}                      // device acknowledged / state changed
final class SentUnconfirmed extends CommandResult {}                // write-only path
final class Unsupported extends CommandResult { Unsupported(this.reason); final String reason; } // incl. 'needs confirmation'
final class Failed extends CommandResult { Failed(this.error, {this.rawDeviceMessage}); final WatchmeError error; final String? rawDeviceMessage; }
```

Each driver maps `RemoteKey` to its own codes: Samsung `KEY_*`, Roku key names, Android keycodes, Sony IRCC codes, Titan Linux input codes, CEC UI codes, HID usages, IR codes, Fire TV actions. A key with no mapping makes the driver report `Unsupported`; it never fails silently.

### 2.3 State and events

```dart
enum PowerMode { on, screenOff, artMode, standby, off, unknown }
enum Confidence { reported, inferred, stale }

final class Observed<T> {
  const Observed(this.value, this.source, this.at, this.confidence);
  final T value; final String source; final DateTime at; final Confidence confidence;
}

final class DeviceState {
  final Observed<PowerMode>? power;
  final Observed<int>? volume;      final Observed<bool>? muted;
  final Observed<String>? input;    final Observed<String>? foregroundApp;
  final Observed<NowPlaying>? nowPlaying;
  final Map<String, ConnectionState> connections; // per driver session
  // ...
}

sealed class DeviceEvent {}
final class StateChanged extends DeviceEvent { /* DeviceState diff */ }
final class ConnectionChanged extends DeviceEvent { /* driver, state, error */ }
final class CapabilitiesChanged extends DeviceEvent { /* runtime probe changed them */ }
final class ReauthRequired extends DeviceEvent { /* LG 403, Samsung unauthorized, Fire TV 401, VIDAA tokens wiped by deep standby */ }
```

Power is a small state machine that merges several sources, because single sources are unreliable at the edges:
- Samsung answers for about 17-20 s after turning off; after a KEY_POWER wake its PowerState stayed `standby` for 23 minutes (HA #187048).
- Frame TVs report standby while in Art Mode.
- Android TV `is_on` is pushed.
- Roku `power-mode` reads Ready in standby.
- LG `getPowerState` exists, but the TV stops answering in deep standby, and `turnOff` within about a minute of a remote switch-off turns the TV back on (lgtv2 #15).

### 2.4 Transports

The I/O abstraction is a bundle of transports, not only a network stack. Every driver dependency on the outside world goes through one of these interfaces.

```dart
enum TransportFeature {
  // network
  httpReadCrossOrigin, httpWriteOnly, customHeaders, nonSimpleMethods,
  webSocket, webSocketHeaders, tlsAcceptSelfSigned, tlsClientCertificate,
  tlsPeerCertificate, rawTcp, udpUnicast, udpBroadcast, multicast,
  // attached hardware and platform
  serialPort,     // libserialport / usb_serial natively; Web Serial in a secure-context page
  bleCentral,     // native BLE; Web Bluetooth (Chromium, secure context)
  hidPeripheral,  // Android BluetoothHidDevice or BLE HOGP; BlueZ on a Linux hub
  irTransmit,     // Android ConsumerIrManager
  subprocess,     // hub and desktop only (cec-ctl)
  // environment
  internet,       // WAN reachable; gates cloud drivers and CapFlag.cloud capabilities
}

final class TlsPolicy {
  const TlsPolicy({this.allowSelfSigned = false, this.pins = const {}, this.trustOnFirstUse = false});
  final bool allowSelfSigned;
  final Set<String> pins;        // SHA-256 of leaf or CA, hex
  final bool trustOnFirstUse;    // pin is recorded at pairing, enforced afterwards
}

abstract interface class Transports {
  Set<TransportFeature> get features;
  NetworkStack? get network;
  SerialPortProvider? get serial;
  BleCentral? get ble;
  HidPeripheral? get hid;
  IrEmitter? get ir;
  ProcessRunner? get process;
}

abstract interface class NetworkStack {
  Future<HttpResult> http(HttpCall call, {TlsPolicy tls});
  Future<MessageSocket> webSocket(Uri uri, {List<String> protocols, Map<String, String> headers, TlsPolicy tls});
  Future<ByteSocket> tcp(String host, int port, {TlsPolicy? tls, ClientIdentity? identity}); // ByteSocket exposes peerCertificateDer
  Future<void> sendDatagram(String host, int port, List<int> bytes, {bool broadcast});
  Stream<Datagram> multicastQuery(String group, int port, List<int> query, Duration window);
}

abstract interface class SerialPortProvider {
  Future<List<SerialPortInfo>> list();                        // browser: previously granted ports only
  Future<SerialPortInfo?> request({List<UsbFilter> filters}); // browser: port picker after a user gesture
  Future<ByteSocket> open(SerialPortInfo port, {int baudRate});
}

abstract interface class BleCentral {
  Future<BleDevice?> request({List<String> services});        // browser: chooser; native: scan
  Future<GattConnection> connect(BleDevice device);
}

abstract interface class HidPeripheral {
  Set<HidTransport> get transports;                           // classic, bleHogp
  Stream<HidHostEvent> advertise(HidProfile profile);         // keyboard + consumer control + mouse
  Future<void> send(HidReport report);
}

abstract interface class IrEmitter {
  List<IntRange> get carrierFrequencies;
  Future<void> transmit(int carrierHz, List<int> pattern);
}

abstract interface class ProcessRunner {
  Future<ProcessResult> run(String exe, List<String> args, {Duration timeout});
  Future<LineProcess> start(String exe, List<String> args);   // long-running, e.g. cec-ctl --monitor
}
```

Implementations:
- `IoTransports` (hub, desktop): every network feature; serial through libserialport (Flutter desktop: flutter_libserialport; CLI hub: an FFI binding, package choice open); `ProcessRunner` for `cec-ctl`; on a Linux hub, `HidPeripheral` through BlueZ (`watchme_bluez`). On iOS, multicast and broadcast need Apple's multicast entitlement.
- `FlutterTransports` (mobile): network through `dart:io`. Android adds `hidPeripheral` (`BluetoothHidDevice`/HOGP), `irTransmit` (ConsumerIrManager, emitter phones only), `serialPort` (usb_serial) and `bleCentral`. iOS adds `bleCentral` only: no HID peripheral and no IR.
- `BrowserTransports` (optional direct mode, §5.8): detected at runtime. It can offer `httpWriteOnly` (no-cors) and `webSocket` toward the LAN in Chromium after the LNA grant, `webSocket` to self-signed wss after the user's certificate step, `httpReadCrossOrigin` for CORS-open hosts (SmartThings), `serialPort` (Web Serial), `bleCentral` (Web Bluetooth) and `internet`. Where feature detection is impossible (whether this browser exempts private-IP http/ws from mixed content), the stack probes once and records the result. It never offers raw TCP, UDP, client certificates, programmatic self-signed acceptance, HID peripheral, IR or subprocess. The user's certificate click-through is modelled as an `OpenUrlFirst` pairing step, not as a feature.
- `FakeTransports` (testkit): scripted exchanges for every interface.

### 2.5 Discovery

```dart
abstract interface class DiscoveryProvider {
  String get id;                     // 'ssdp', 'mdns', 'bonjour', 'manual', 'subnet-probe', 'smartthings'
  Set<TransportFeature> get requires;
  Stream<DiscoveryHit> scan(Duration window);
}

final class DiscoveryHit {
  final String host; final int? port; final String provider;
  final String? serviceType;          // SSDP ST or mDNS type
  final Map<String, String> attributes; // TXT records, SSDP headers, device-info fields
  final String? mac; final String? stableId; // USN uuid, serial, TV uuid
}
```

Drivers declare matchers, and the engine merges hits into one physical device keyed by MAC or stable id, not by IP. Known matchers:
- Roku `roku:ecp`
- Samsung `urn:samsung.com:device:RemoteControlReceiver:1`
- LG `urn:lge-com:service:webos-second-screen:1`
- Sony `urn:schemas-sony-com:service:ScalarWebAPI:1`
- Android TV `_androidtvremote2._tcp`
- Cast `_googlecast._tcp`
- Fire TV: `_amzn-wplay._tcp` with `amzn.dmgr`, **and** SSDP/DIAL `urn:dial-multiscreen-org:service:dial:1` with manufacturer Amazon and model `AFT*`. LibreControl's 2026-10-19 hardware test found a stick only through SSDP/DIAL, with no `_amzn-fireTv._tcp` advertisement.
- DIAL (generic) `urn:dial-multiscreen-org:service:dial:1`
- ADB wireless debugging `_adb-tls-connect._tcp` / `_adb-tls-pairing._tcp`
- Vizio `_viziocast._tcp`
- Philips `_philipstv_s_rpc._tcp`
- Apple `_companion-link._tcp` / `_airplay._tcp`; HomeKit `_hap._tcp` (iOS platform driver only)
- Titan `_secure-mqtt._tcp`
- AirPlay-capable Samsung/LG `_airplay._tcp` with manufacturer TXT
- IR bridges: ESPHome `_esphomelib._tcp`; Broadlink UDP broadcast hello

Discovery attributes. SSDP hits carry every reply header (lower-cased) plus the UPnP description fields. mDNS hits carry the TXT entries verbatim plus `mdns.instance`, `mdns.target` and `mdns.service` (the normalised service type). Probes see only the endpoint's attributes, not the hit, so `mdns.service` is how a probe tells which DNS-SD service found the device. One real Fire TV stick was observed on a passive mDNS listing (2026-10-21):
- It advertised only `_amzn-wplay._tcp`.
- Its instance label was an opaque `amzn.dmgr:<id>:...` token.
- Its TXT `n` held the user's name for the device, and `u` held the same 32-hex-digit id.

Provider variants:
- On iOS, `bonjour` (NWBrowser via bonsoir/nsd) avoids the multicast entitlement.
- `subnet-probe` does unicast probing of known ports across a /24. It is the entitlement-free fallback and the only discovery available to the browser.

### 2.6 Drivers

```dart
enum Stability { documented, communityStandard, reverseEngineered, privateVendorSecret }
enum DriverTarget { webSafe, native, hubOnly, androidOnly, iosOnly }

final class DriverBackend {
  final String id;                         // 'cec.serial', 'cec.linux', 'irbridge.esphome', 'irbridge.broadlink'
  final Set<TransportFeature> requires;    // gates where the backend can run (incl. browser-direct mode)
  final Set<DriverTarget> targets;         // CI compiles webSafe backends to JS; others are excluded and tagged
}

final class DriverDescriptor {
  final String id;                         // 'roku.ecp', 'samsung.tizen', 'firetv.lightning', 'androidtv.remote2'
  final String vendor, protocol;
  final List<CapabilitySupport> ceiling;   // the most the protocol can do
  final List<DriverBackend> backends;
  final List<DiscoveryMatcher> matchers;
  final Stability stability;
  final List<SetupStep> userSetup;         // 'Roku: Control by mobile apps = Enabled', 'LG: hidden menu 82888'
  final String provenance;                 // 'ported from aiowebostv (Apache-2.0)'
}

abstract interface class Driver {
  DriverDescriptor get descriptor;
  Future<ProbeResult> probe(Endpoint ep, Transports t);         // narrows the ceiling for this device
  PairingFlow? startPairing(Endpoint ep, Transports t);         // null = no pairing
  Future<DriverSession> connect(Endpoint ep, Transports t, Credential? cred);
}

abstract interface class DriverSession {
  List<CapabilitySupport> get capabilities;  // runtime, per device and firmware
  Stream<DeviceEvent> get events;
  Future<CommandResult> execute(Command command);
  Future<void> close();
}
```

Target examples:
- `webSafe`: Roku, Samsung WebSocket/REST, Sony REST, SmartThings, CEC over a Pulse-Eight serial port (clean-room framing; libcec is GPL), ESPHome/Tasmota IR bridges.
- `native`: Android TV Remote v2, Fire TV, ADB, CASTV2, LG SSAP (until the browser Origin:null path is verified), LG IP Control, Apple TV, VIDAA, Philips, Broadlink.
- `hubOnly`: CEC through `cec-ctl`, BlueZ HID peripheral.
- `androidOnly`: in-process Bluetooth HID, IR emitter. `iosOnly`: HomeKit TV services.

**How drivers declare capabilities.**

1. The static `ceiling` is what the protocol can ever do. These descriptors generate the capability matrix in the docs, and a test fails if the doc drifts from them.
2. `probe()` narrows the ceiling per device. Examples:
   - Samsung reads `/api/v2/` (`TokenAuthSupport`, `FrameTVSupport`, presence of `PowerState`).
   - Roku reads `device-info` and probes a gated endpoint for the body `ECP command not allowed in Limited mode`.
   - LG reads `hello` and `getSystemInfo`, then the registration result. With an unsigned key, `setSystemSettings` is marked unavailable.
   - Fire TV reads `GET /v1/FireTV/status` on :8080 without a token (a 401 still proves the API). While the device sleeps :8080 does not listen, so the probe falls back to the DIAL application status, `GET /apps/FireTVRemote` on :8009, which reports state without launching anything. A discovery advertisement only identifies the device; if neither port answers, the probe fails as unreachable. The probe never wakes the device. The wake, `POST /apps/FireTVRemote` (expect 201), is sent only by pairing, by `connect()` before every session, and by a session whose command found :8080 closed (the stick fell asleep under it), which then resends the command once. `SetPower(false)` and `refresh()` never wake it.
3. The live session can emit `CapabilitiesChanged`, for example when a pointer socket returns 401.

**Composition.** One TV usually has several sessions, and the engine routes each command to the best one. Typical sets:
- Samsung: Tizen WebSocket + REST + UPnP RenderingControl + WoL + optional SmartThings; Frame Art channel later.
- LG: SSAP + IP Control + WoL + Cast.
- Android TV: Remote v2 + Cast + optional ADB.
- Fire TV: DIAL wake + Lightning API + optional ADB (Fire OS only) + optional CEC through the hub.
- Sony: REST + IRCC + Simple IP Control (pushed state).
- Any TV: optional CEC, IR bridge and Bluetooth HID sessions as fallbacks.

### 2.7 Pairing and credentials

```dart
sealed class PairingStep {}
final class Instruct extends PairingStep { Instruct(this.text, {this.helpUrl}); final String text; final Uri? helpUrl; }
final class AcceptOnTv extends PairingStep { AcceptOnTv(this.timeout); final Duration timeout; }   // Samsung / LG / Sharp prompt
final class EnterCode extends PairingStep {                                                       // ATV 6 hex, Fire TV / Vizio 4 digits,
  EnterCode(this.label, this.length, this.alphabet); final String label; final int length; final CodeAlphabet alphabet; } // Apple PIN, LG keycode 8 chars
final class OpenUrlFirst extends PairingStep { OpenUrlFirst(this.url, this.why); final Uri url; final String why; } // browser-direct cert step
final class NeedsUserMaterial extends PairingStep { NeedsUserMaterial(this.kind, this.help); final MaterialKind kind; final Uri help; } // VIDAA cert, SmartThings app
final class Paired extends PairingStep { Paired(this.credential); final Credential credential; }
final class PairingFailed extends PairingStep { PairingFailed(this.error, this.rawDeviceMessage); final WatchmeError error; final String? rawDeviceMessage; }

abstract interface class PairingFlow {
  Stream<PairingStep> get steps;
  void submit(String value);
  Future<void> cancel();
}

sealed class Credential { String get driverId; String get deviceId; DateTime get createdAt; String? get peerCertSha256; DateTime? get expiresAt; }
// TokenCredential                  - Samsung token, LG client-key, Vizio AUTH, Fire TV client token,
//                                    VIDAA access (48 h) / refresh (30 d) tokens
// ClientCertCredential             - Android TV RSA cert + key generated by watchme (pairing secret depends on its modulus/exponent)
// UserSuppliedClientCertCredential - VIDAA vendor client cert + key that the user imports; never shipped by watchme
// KeyPairCredential                - Apple HAP Ed25519 long-term keys; ADB RSA key
// SharedSecretCredential           - Sony PSK, LG IP Control keycode, Philips digest user/key, Titan MQTT username/password
// CloudOAuthCredential             - SmartThings access + rotating refresh token, plus the user's own client id/secret
// MatterFabricCredential           - watchme's fabric root CA, NOC and IPK (controller path)

abstract interface class CredentialStore {
  Future<Credential?> read(String deviceId, String driverId);
  Future<void> write(Credential credential);
  Future<void> delete(String deviceId, {String? driverId});
}
```

Pairing must surface the TV's raw error text instead of a generic failure. Known cases:
- LG `403 Pairing rejected: blacklisted certificate detected`.
- Samsung `ms.channel.timeOut` / `ms.channel.unauthorized`.
- Roku Limited-mode 403 body.
- Fire TV 401/403 token revoked.

VIDAA driver notes:
- **Clock sync.** Credentials are timestamp-derived and the broker rejects clocks more than 120 s apart, so the driver reads the TV clock from the `Date` header of its UPnP server (38400/18400) and derives credentials from that, not from the host clock.
- **Token lifetimes.** Access tokens last 48 h and refresh tokens 30 days; refresh before expiry.
- **Deep standby.** Tokens live in TV RAM, so a deep standby or power cut wipes them. The driver maps the resulting rc 4/134 to `ReauthRequired` and re-runs the PIN flow, rather than reporting a generic failure.

**Who owns a pairing.** Each (device, driver) pairing has one owner: the hub when a hub is attached, otherwise the in-process engine. Mobile and desktop clients that know a hub route through it by default, and pair in-process only in standalone mode. This avoids duplicate on-TV approvals, a second LG client-key, a second Android TV client certificate, and Samsung re-prompts on TVs left at "every time". If a user deliberately pairs both, the UI shows them as separate pairings.

### 2.8 Engine and client interface

```dart
abstract interface class WatchmeEngine {
  Stream<List<Device>> get devices;
  Future<void> discover(Duration window);
  Future<Device> addManual(String host);
  PairingFlow pair(String deviceId, String driverId);
  Future<CommandResult> send(String deviceId, Command command);
  Stream<DeviceEvent> events(String deviceId);
  Map<Capability, CapabilitySupport> capabilitiesOf(String deviceId); // merged across sessions
}

/// What the UI talks to. Same interface in every surface.
abstract interface class WatchmeClient {
  Stream<List<DeviceView>> watchDevices();
  Future<void> scan();
  Future<PairingHandle> pair(String deviceId, String driverId);
  Future<CommandResult> send(String deviceId, Command command);
}
// InProcessClient wraps a WatchmeEngine (mobile, desktop). HubClient speaks /api/v1 + /ws (web, or mobile attached to a hub).
```

**CapabilityRouter.** It ranks candidate sessions for a command by:
1. Support level.
2. Flags: state feedback beats write-only; local beats cloud; documented beats reverse-engineered; absolute beats relative; discrete beats toggle.
3. Session health and latency.

It then falls back down the list. Volume is the canonical example: absolute via UPnP or SSAP, then relative keys, then CEC, then HID consumer keys, then IR.

**PowerOrchestrator.** Its rule: never send a toggle on a guess.
- *Power-on chain*, discrete commands only:
  1. A reachable session with a discrete power-on: Roku `PowerOn`, Android TV `KEYCODE_WAKEUP` (only where the probe shows it works), LG `system/turnOn` (screen-off state only), Sony `setPowerStatus(true)` or SSIP power on, Vizio key 11/1, Philips `powerstate On`, Apple TV Companion `turn_on`, Matter `OnOff.On`.
  2. Wake-on-LAN to every cached MAC (broadcast where allowed, plus unicast to the last IP). Then wait for the device to reappear (REST, SSDP alive, mDNS) and repeat step 1 if the device has a discrete command. There is no power-key retry.
  3. CEC `Image View On` via the hub (or via Web Serial in browser-direct mode).
  4. Cloud, if configured (SmartThings `switch.on`).
  5. A discrete IR power-on code, if an IR bridge is configured and the brand has one.
- *Toggles* (`KEY_POWER`, `KEYCODE_POWER`, IR power toggles) are sent only when at least two independent sources agree on the current state. For "turn on", that means e.g. SSDP byebye or no answer, REST `PowerState` = standby, and more than 20 s since the last off. Otherwise the command returns `Unsupported('needs confirmation')` and the UI asks the user. Why:
  - Samsung keeps answering for 17-20 s after off; after a KEY_POWER wake its PowerState stayed `standby`; KEY_POWERON had no visible effect (HA #187048). A stale belief can turn a TV off again.
  - LG `turnOff` within about a minute of a remote switch-off turns the TV back on (lgtv2 #15).
- *Power-off:* prefer discrete off (CEC Standby, Roku PowerOff, Vizio 11/0, Sony `setPowerStatus(false)`, SmartThings `switch.off`, LG `turnOff` only when `getPowerState` says Active). Toggles follow the same two-source rule.

### 2.9 Where M0 code differs from these sketches

The code in `packages/watchme_core` is the contract. The deliberate differences:

- **Driver.**
  - `Driver.startPairing(endpoint, transports, PairingContext)` takes a third argument, because credentials need the engine's device id.
  - `DriverSession` adds `driverId`, `state` and `refresh()`.
  - `DriverDescriptor` adds `ports` (default per port name) and `requiresPairing`.
  - Ports are always resolved through `Endpoint.port(name, default)`. Roku uses `ecp` (8060); Fire TV uses `dial` (8009) and `api` (8080).
- **Discovery.**
  - `DiscoveryProvider.scan(window, {serviceTypes})` takes the service types the drivers' matchers need.
  - `DiscoveryMatcher` adds `portName`.
  - `DiscoveryAttr.mdnsService` is an addition (§2.5).
- **Probes and transports.**
  - `ProbeResult.power` carries the power state a probe saw passively (Roku device-info `power-mode`; Fire TV API closed while DIAL answers means standby). The power orchestrator's evidence is passive: it refreshes open sessions and probes the rest, and never connects, because connecting can wake a TV. After Wake-on-LAN it reports `Confirmed` only on a fresh "on", since a Roku in standby still answers device-info.
  - `HttpCall.maxResponseBytes` lets a caller cap a body it does not trust (UPnP descriptions).
  - A connection lost after it was made is `timeout`, not `unreachable`: only `unreachable` means nothing was delivered.
- **Results and pairing.**
  - `Failed` and `PairingFailed` take only a `WatchmeError`; `rawDeviceMessage` lives on the error.
  - `Paired.credential` is null only in `Paired.redacted()`, which is what clients receive.
- **Commands and state.**
  - The `ListApps` command was added, and `Confirmed(payload:)` carries the app list or a screenshot.
  - `LaunchApp` adds `params` (Roku `contentId`/`mediaType`).
  - `RemoteKey` adds `backspace`, `enter`, `instantReplay` and `inputAv1`.
  - `DeviceState.foregroundApp` is `Observed<AppInfo>`.
- **Engine and client.**
  - `WatchmeEngine` works with `DeviceView`. It adds `start`, `currentDevices`, `forget`, `refresh`, `close` and `addManual(host, ports:)`.
  - `WatchmeClient` adds `addManual`, `forget`, `refresh` and `close`.
  - `refresh` of a device with no open session only probes passively: it never connects, because connecting can wake a TV (Fire TV). State therefore appears after the first command, or after polling once a session is open.
- **Pairing ownership (§2.7).** There is no hub in M0, so every pairing is owned by the in-process engine.

## 3. Language choice

| | Dart core (chosen) | TypeScript hub + Dart app |
|---|---|---|
| Protocol implementations | Once | Twice: TS in the hub, Dart in the app. The alternative is making the app depend on a hub, which breaks standalone mobile use. |
| Flutter mobile/desktop in-process | Yes | Only via a hub, or a Dart port anyway |
| mTLS, raw TCP, UDP, multicast | `dart:io` covers all of them. Android TV v2 pairing has been done in pure Dart (amolood/Universal-Remote, MIT). | Node covers all of them |
| Bluetooth HID peripheral | Android: Kotlin channel. Linux hub: BlueZ over D-Bus (`package:bluez`, MPL-2.0) or a helper process | Node: bleno (MIT) on Linux |
| Existing TV libraries | Thin on pub.dev; we port from Python/TS references | Richer: homebridge-samsung-tizen, lgtv2, lgtv-ip-control, @kud/androidtv-remote and matter.js are directly usable |
| Matter | No Dart stack | matter.js (Apache-2.0) |
| Web build | Pure-Dart drivers compile to JS for an optional browser-direct mode | TS drivers run natively in the browser |
| Toolchains to maintain | One | Two |

**Decision: Dart.** The escape hatch for ecosystems Dart lacks is an out-of-process **driver host protocol**: JSON-RPC over stdio or a local socket, carrying the same `DriverDescriptor`, `Command` and `DeviceEvent` DTOs. A Node process running matter.js, or temporarily pyatv for Apple TV, can plug into the hub as a remote driver. Mobile does not get those drivers until they are ported or wrapped with platform SDKs.

Known Dart gaps to plan for:
- **Discovery in the hub.** bonsoir and nsd are Flutter plugins, so the hub uses `multicast_dns` (raw sockets) or Avahi over D-Bus. Whether `multicast_dns` coexists with avahi-daemon on port 5353 is untested.
- **Serial in the CLI hub.** flutter_libserialport is a Flutter plugin; the pure-Dart hub needs a libserialport FFI binding (choice open).
- **Bluetooth HID on the hub.** `package:bluez` is MPL-2.0 (ASF Category B: use it unmodified as a dependency and label it). BlueZ HID-peripheral behaviour per TV is unverified.
- **X.509 parsing.** basic_utils' parser throws on some Android TV certificates; walk the ASN.1 with asn1lib instead.
- **Client certificates on iOS.** `SecurityContext` client certificates are not proven there; it supports only PKCS12 through `usePrivateKey`.
- **Apple TV crypto.** OPACK, TLV8 and the MRP protobufs have to be written. SRP6 (pointycastle) and Ed25519/X25519/ChaCha20-Poly1305/HKDF (cryptography, Apache-2.0) exist.

## 4. Repo layout

Use pub workspaces (Dart 3.6+) or melos.

```
watchme/
  packages/
    watchme_core/          # pure Dart, web-safe: capabilities, keys, commands, state, events,
                           # Transports interfaces (network, serial, BLE, HID, IR, process),
                           # DiscoveryProvider / CredentialStore interfaces, API DTOs
    watchme_io/            # dart:io network, SSDP, mDNS, WoL, TLS pinning/TOFU, subnet probe,
                           # libserialport serial, ProcessRunner
    watchme_bluez/         # Linux hub HidPeripheral over BlueZ D-Bus (hub-only)
    watchme_platform/      # Flutter plugin: Android HID + IR + MulticastLock + USB serial, Bonjour (bonsoir/nsd)
    watchme_web_transports/# (later) BrowserTransports via package:web (fetch/WS, Web Serial, Web Bluetooth)
                           # and BrowserCredentialStore
    watchme_engine/        # registry, identity merge, capability router, power orchestrator, pairing
    watchme_testkit/       # FakeTransports, transcript runner, protocol simulators (also runnable)
    drivers/
      watchme_driver_roku/        watchme_driver_firetv/       watchme_driver_dial/
      watchme_driver_cast/        watchme_driver_androidtv/    watchme_driver_adb/       (opt-in)
      watchme_driver_samsung/     (WebSocket, REST, UPnP; Frame Art later)
      watchme_driver_lg/          (SSAP + IP Control)          watchme_driver_vizio/
      watchme_driver_sony/        (REST, IRCC, Simple IP Control)
      watchme_driver_appletv/     watchme_driver_vidaa/        watchme_driver_philips/  (JointSpace + Titan)
      watchme_driver_wol/         watchme_driver_upnp/
      watchme_driver_cec/         (serial backend web-safe; cec-ctl backend hub-only)
      watchme_driver_irbridge/    (ESPHome, Tasmota, Broadlink)
      watchme_driver_hid/         (keyboard/remote over HidPeripheral)
      watchme_driver_homekit/     (iOS only)
      watchme_driver_smartthings/ (optional, cloud)
  apps/
    hub/                 # dart CLI: shelf server, serves apps/watchme build/web, /api/v1, /ws
    watchme/             # Flutter app: web (HubClient), Android, iOS, macOS, Windows, Linux
    tools/               # capture/redact tool, matrix generator, simulator launcher
  e2e/                   # Playwright cross-engine suite against hub + simulators
  docs/
    research/            # platform research (this synthesis)
    architecture/        # this document, ADRs
    drivers/             # per-driver notes, generated capability tables
  LICENSE (Apache-2.0)  NOTICE  THIRD_PARTY.md (provenance of every ported driver)
```

CI rules:
- Every driver backend declares its targets (a `watchme:` section in pubspec.yaml or a `driver.yaml`). CI fails if one is missing.
- `watchme_core`, `watchme_engine` and every backend tagged `webSafe` must compile with `dart compile js`, which proves they have no `dart:io` leak. Backends not tagged `webSafe` are excluded from that job, and a lint fails if a `webSafe` package imports `dart:io`, `package:flutter` or a platform package.
- A licence check rejects new dependencies outside Apache, MIT and BSD. MPL-2.0 (ASF Category B) is allowed only on an explicit allowlist (e.g. `package:bluez`), unmodified.
- The generated capability matrix must match the committed doc.
- The built web UI must make no off-origin requests (§5.3).

## 5. How each surface reuses the core

### 5.1 Web (first)

- The hub serves the Flutter web build at `http://<hub-lan-ip>:<port>/`, and the UI talks only to its own origin (`/api/v1`, `/ws`).
- In every browser this means no CORS, no mixed content and no browser Local Network Access prompt, because local-to-local same-origin requests are not gated. OS-level prompts still apply:
  - macOS 15+ asks once for Chrome, Firefox and Edge; Safari, WKWebView and SFSafariViewController are exempt.
  - On Android 17, browsers that target SDK 37 will probably need the user's local-network grant before any LAN page loads (inference; open question).
  - iOS Safari traffic is exempt from iOS local-network privacy. Chrome 154's HTTPS-by-default does not warn for private IPs.
- The hub prints, and shows in the desktop app, a URL plus a QR code with the IP literal. `.local` resolution is not reliable across clients (Android Chrome is unverified), so the IP literal is safer.
- Limitations: the page is not a secure context, so there is no service worker, no PWA install and no Web Serial or Web Bluetooth. Optional HTTPS for the hub comes later (see Security).
- Chrome has said it intends to extend LNA to local-to-local cross-origin requests. Keeping TV traffic server-side and the UI same-origin is immune to that change.

### 5.2 Hub placement and addressing

- **Same L2 subnet as the TVs.** Samsung refuses WebSocket connections across subnets or VLANs; Roku "Enabled" answers only same-network clients ("Permissive" is needed otherwise); SSDP, mDNS and broadcast WoL do not cross subnets. Phones on a guest Wi-Fi fail the same way.
- **Stable address.** A DHCP reservation, or a name the router resolves. The bookmarked/QR URL, the `Host` allowlist and the origin-bound HttpOnly cookie all depend on it.
- **When the address changes anyway,** the hub notices, adds the new address to its `Host` allowlist, prints and shows a new QR code, and clients re-pair with a short code (their old cookie belonged to the old origin). TV credentials on the hub are unaffected.

### 5.3 Offline / no-internet operation

Every core remote function must work with the WAN down, and the UI must not leak requests to third parties.
- Build the web UI with `flutter build web --no-web-resources-cdn`, so CanvasKit/skwasm ships with the app (reportedly about 30 MB across variants) instead of loading from Google's gstatic CDN; point `canvasKitBaseUrl` at the hub.
- Bundle fonts (Roboto and the Noto fallbacks the UI needs) as assets and set the engine's font-fallback base URL to the hub, so nothing is fetched from fonts.gstatic.com.
- CI loads the built `web/` in a headless browser with all off-origin traffic blocked, and fails on any off-origin request.
- Renderer check: multi-threaded skwasm needs `crossOriginIsolated`, which browsers grant only in secure contexts, so the plain-http hub page gets at best single-threaded rendering. Verify the `--wasm` build on a non-secure, non-isolated http origin, or ship the CanvasKit JS target. If neither performs on cheap phones, use the lightweight TS/HTML UI option.
- Features that need internet carry `CapFlag.cloud`, and their drivers declare `TransportFeature.internet`: SmartThings, the Titan app list (proxied through Titan's cloud), Vizio's cloud app catalog (scfs.vizio.com), and Cast receiver apps, including the Default Media Receiver. The UI greys them out when the hub has no WAN.

### 5.4 Desktop (Flutter desktop)

- Embeds the engine in-process through `InProcessClient`.
- "Host mode" starts the hub server inside the app, serving the web UI to the LAN and to `http://localhost`. Localhost is a secure context, so Web Serial to a USB-CEC adapter and Web Bluetooth become possible there.
- On macOS 15+ the app triggers the Local Network prompt but needs no multicast entitlement. A launchd daemon variant of the hub is exempt from the prompt.

### 5.5 Mobile (Flutter)

- Embeds the engine in-process, so it works without a hub and talks to TVs directly. When a hub is known, it routes through the hub by default and pairs in-process only in standalone mode (§2.7). The hub also provides hub-only drivers: CEC, IR bridges, BlueZ HID, always-on WoL and automations.
- Android: request ACCESS_LOCAL_NETWORK when targeting SDK 37; hold a MulticastLock for SSDP/mDNS receive. Android-only drivers: Bluetooth HID keyboard/remote (Kotlin `BluetoothHidDevice` or BLE HOGP channel) and the IR emitter (`ConsumerIrManager`).
- iOS: Bonjour discovery and unicast probing until Apple grants the multicast entitlement, which should be requested now (it is per team and can be filed before the app exists). Unicast WoL to the last-known IP needs no entitlement. No Bluetooth HID and no IR on iOS.

### 5.6 Hub host (Raspberry Pi or Linux box)

Runs the same engine and adds the CEC driver (`/dev/cecN` via `cec-ctl` as a subprocess; libcec is GPL, so keep it out of process), the SSDP NOTIFY listener, WoL, and the BlueZ Bluetooth HID peripheral.

### 5.7 Bluetooth

The README lists "connect to and control a smart TV over WiFi or Bluetooth" as a headline feature. What is possible:

| Path | Who can use it | Status |
|---|---|---|
| **Hub as a BLE (HOGP) or Classic HID keyboard/remote** via BlueZ (Pi built-in Bluetooth) | Every hub client, iPhones and browsers included | Recommended cross-client path. `package:bluez` (MPL-2.0) over D-Bus, or a small helper process. Unverified per TV; needs prototyping. |
| **Android phone in-process** via `BluetoothHidDevice` (API 28+, Classic) or a BLE HOGP GATT server | Android app only | Proven on an LG G5 (webOS 25) by a GPL-3.0 project we may only read. Needs a Kotlin channel. |
| **Web Bluetooth to a watchme ESP32 bridge** that emits IR, CEC or BLE HID | Chromium, secure context only (direct mode, or desktop at http://localhost) | Optional, later; requires custom hardware. |
| iPhone as HID peripheral | nobody | Impossible: iOS cannot publish the HID service, and iPhones have no IR. |
| Browser directly to the TV over Bluetooth | nobody | Impossible: Web Bluetooth is central-only and blocklists the HID service 0x1812. |

What HID gives: d-pad, Enter/Back/Home consumer keys, media keys, relative volume and mute where the TV maps consumer usages, real keyboard text input, and a mouse pointer on Android TV, Tizen and webOS. It gives no state and no app list, and power-on is unverified. Acceptance by TV OS needs a test matrix: webOS is confirmed on an LG G5; Android/Google TV, Fire TV, Tizen and Apple TV generally accept Bluetooth keyboards but are unverified here; Roku does not support generic HID (unverified). LG's "Turn on via Bluetooth" uses an undocumented BLE protocol (ThinQ, Android only); whether watchme can use it is an open question.

Proposed order: Android in-process HID in M2 with the Android app, hub BlueZ HID prototype in M3, ESP32 bridge in M4. The owner should confirm this (open question).

### 5.8 Optional later: browser-direct mode

- **Hosting.** A separate build served from a public HTTPS origin (e.g. the project's GitHub Pages). It needs a secure context for the LNA prompt, the Cast SDK, Web Serial and Web Bluetooth. That origin differs from `http://<hub-ip>`, so pairings and storage do not carry over; users pair again in direct mode.
- **Engine.** The web build instantiates the engine with `BrowserTransports`. Only backends whose `requires` set is satisfiable in the current browser are enabled. No new driver code is needed.

| Feature in direct mode | Chromium | Firefox | Safari / iOS |
|---|---|---|---|
| Roku ECP, Sony REST, HTTP IR bridges (ESPHome allowlisted, Tasmota): http to a private IP, write-only | 142+ after the LNA prompt | blocked (mixed content) | blocked |
| Samsung wss:8002 (self-signed) | after a certificate click-through (7 days) + LNA prompt | after a permanent host:port exception + LNA prompt | unverified |
| SmartThings (cloud HTTPS, CORS-open) | yes | yes | yes |
| Media casting | Cast Web Sender | no | AirPlay via Remote Playback |
| Web Serial: Pulse-Eight USB-CEC (incl. power-on), serial IR dongles | desktop 89+; Android 148+ where wired ports are exposed | 151+ desktop, add-on gate | no |
| Web Bluetooth: watchme ESP32 BLE bridge | yes (central only) | no | no |

- **Excluded from direct mode:** Vizio (unverified browser path, and its token is unscoped: it also unlocks settings and a system-webview URL launch, so it should not sit in browser storage), LG SSAP until the Origin:null iframe plus LNA delegation is verified, and everything that needs raw sockets (Android TV, Fire TV, Apple TV remote, VIDAA, Philips, Titan, LG IP Control).
- **Credentials: `BrowserCredentialStore`.**
  - IndexedDB, not localStorage.
  - Tokens wrapped with AES-GCM under a non-extractable WebCrypto key (HTTPS origins only). This is defence in depth only: page script, including injected script, can still use the key, so it does not protect against XSS.
  - The real protections are a strict CSP, Subresource Integrity on our own assets, and no third-party scripts except the Cast SDK, loaded only on the casting view.
  - Explicit UX: "this browser forgets pairings when site data is cleared or in a private window", with a quick re-pair flow.
  - SmartThings: a bring-your-own client secret pasted into the page is visible to that page's JavaScript; the pairing UI says so. The token exchange must use `https://api.smartthings.com/oauth/token` (CORS `*` verified 2026-10-21); `auth-global.api.smartthings.com/oauth/token` rejects CORS preflights.

## 6. Hub API (sketch)

```
GET    /api/v1/info                      version, features, hub id, current addresses and names
POST   /api/v1/clients/pair              {code} -> {token, role}    code shown on hub console / desktop app
GET    /api/v1/devices                   devices with merged capabilities + state
POST   /api/v1/devices                   {host} manual add (probe all drivers)
POST   /api/v1/discovery                 start scan; results stream on /ws
POST   /api/v1/devices/{id}/pairings     {driver} -> {pairingId}; steps stream on /ws
POST   /api/v1/pairings/{pid}/input      {value}
DELETE /api/v1/pairings/{pid}
POST   /api/v1/credentials/import        owner only: VIDAA client cert + key (PEM or PKCS12),
                                         SmartThings bring-your-own OAuth app (client id + secret)
POST   /api/v1/devices/{id}/commands     Command JSON -> CommandResult
GET    /api/v1/ws                        WebSocket: events, pairing steps, low-latency key commands
GET    /                                 static web UI
```

The DTOs are the `watchme_core` classes, so the hub, the Flutter client and the optional driver hosts share one schema. Key presses go over the WebSocket to avoid per-request overhead. `down`/`up` actions are supported so holds and repeats work. Imported material is stored like other credentials and is never returned by the API.

## 7. Security model

**Threats:**
- Other devices and users on the LAN.
- Public web pages attacking the hub through CSRF or DNS rebinding.
- Stolen credentials. TV tokens are unscoped bearer secrets: a Vizio token also unlocks settings and a webview URL launch; ADB is a full shell.
- Impersonated TVs. Samsung and LG TLS keys appear to be fleet-wide.
- Licensing contamination.

**Hub exposure.**
- Bind to the LAN interface. Reject requests whose `Host` is not one of this hub's current IP literals or a configured name; this defeats DNS rebinding. Address changes update the allowlist (§5.2).
- Require `Origin` to equal the hub origin on `/ws` and every state-changing request. Do not rely on browser LNA, which Safari lacks and which differs across browsers.
- Clients must pair with the hub. A short code shown on the hub console or desktop app, optionally also sent as a TV toast, is exchanged for a long-lived token. Tokens are stored hashed on the hub and are revocable. Rate-limit code attempts.
- Roles:
  - `owner`: pair TVs, import credential material, manage credentials and clients.
  - `remote`: send commands to approved devices.
- The web UI keeps its token in an HttpOnly, SameSite=Strict cookie and is served with a strict CSP. App clients use an `Authorization` header.
- v0 runs plain HTTP on the home LAN, which means hub tokens are readable by anyone sniffing the LAN; document this. Planned HTTPS options:
  - (a) ACME DNS-01 certificate for a user-owned name that resolves to the hub's LAN IP. Some routers' rebinding protection breaks this.
  - (b) A local CA installed on clients.
  - A self-signed click-through is not an option: Chrome refuses service workers on certificate-error pages.

**TV credentials.**
- Mobile and desktop store them in the OS keystore (Keychain, Keystore, libsecret, DPAPI) through a secure-storage plugin; verify that plugin's licence.
- The hub stores them in a file under the XDG state dir with mode 0600, optionally encrypted with a key from libsecret or a passphrase.
- In hub and in-process modes, credentials never leave the engine; hub web clients see device handles, never tokens. Browser-direct mode is the exception: the engine runs in the page, so its credentials live in `BrowserCredentialStore` with the limits described in §5.8.

**TLS to TVs.** Never disable verification globally. Each driver passes a `TlsPolicy`:
- TOFU: record the peer certificate SHA-256 at pairing (when the user is confirming on the TV screen anyway), then enforce host + fingerprint.
- Fleet-shared certificates (Samsung SmartViewSDK G2, LG "LGE TV SSG") prove only "a Samsung TV" or "an LG TV". The pairing token is the real secret.
- Cast certificates last at most 4 days, so never pin them.
- Android TV and Fire TV certificates are per device: TOFU.

**Risky features are opt-in, clearly labelled, and never default:**
- ADB. Note CVE-2026-0073, a wireless-ADB auth bypass on Android 14-16; recommend turning wireless debugging off when not in use.
- LG luna-via-createAlert.
- Vizio system-webview URL launch.
- Roku's private ecp-2 WebSocket (excluded entirely).
- The hub's Bluetooth HID peripheral: it pairs as a keyboard, so pairing is owner-only and the hub stops advertising once bonded.

**No vendor secrets shipped:**
- No LG-signed manifests (classic or "LG Mobile").
- No VIDAA client certificates; users import their own through `/api/v1/credentials/import`.
- No Roku ecp-2 key.
- The Fire TV `X-Api-Key` is a public static value, but the API is reverse-engineered; record this in the driver's `stability` and get a legal opinion.

**Cloud is off by default.** SmartThings uses a bring-your-own OAuth app, because the token endpoint needs the client secret and a shared watchme app may be capped at 20 installs. In hub and app modes the tokens live on the hub or device and handle the 30-day rotating refresh; in browser-direct mode they live in `BrowserCredentialStore`.

**Licensing.**
- Port only from Apache, MIT and BSD sources, keeping notices in `THIRD_PARTY.md`.
- MPL-2.0 (Category B) only as an unmodified, labelled dependency (e.g. `package:bluez`).
- LGPL, GPL and AGPL code is reference-only. Examples: samsungtvws, ha-samsungtv-smart `api/samsungws.py`, the throwaway96 webos-ssap-web fork (AGPL; the Informatic original is MIT), libcec, the Dart `wake_on_lan` package (GPL-3.0), and GoldenGuts' bluetooth-tv-remote (GPL-3.0).
- Avoid flutter_blue_plus: its custom licence requires a paid licence for every for-profit organisation.

## 8. Testing strategy

**1. Driver unit tests against `FakeTransports`.** Scripted transcripts (request, then expected bytes or JSON, then response) cover the happy path and every known failure. Write transcripts from protocol documentation and our own captures; do not copy them out of LGPL test suites. Required cases per driver:
- Roku: Limited-mode 403 body; Host must be an IP literal.
- Samsung: `ms.channel.timeOut`, `ms.channel.unauthorized`, token refresh.
- LG:
  - `403 blacklisted certificate` on the signed manifest; unsigned manifest succeeds.
  - Pointer socket 401.
  - `getSystemInfo` required before `register`.
  - Port 3000 hangs, then falls back to 3001.
- Android TV: pairing secret check byte; ping/pong keepalive; a server certificate that basic_utils cannot parse.
- Fire TV: DIAL 201 wake before every pairing and connect, never in a probe; PIN display/verify; 401 means re-pair; `{}` body yields 500.
- VIDAA: clock skew over 120 s rejected; token expiry; deep-standby wipe maps to `ReauthRequired`.
- CEC (serial backend) and IR bridge: framing and ESPHome 403 for a non-allowlisted origin.

**2. Protocol simulators.** Small Dart servers in `watchme_testkit`, runnable with `dart run watchme_testkit:sim <name>`, so drivers, the engine, the hub and the UI can all be exercised with no hardware. The first set:
- Roku ECP HTTP plus an SSDP responder.
- Fire TV Lightning: DIAL + HTTPS with a self-signed certificate.
- Samsung WebSocket + REST.
- LG SSAP + pointer socket.
- Android TV v2 with real mTLS and a real secret computation.
- Cast CASTV2.
- A WoL listener.

Before M3: Vizio (HTTPS 7345 with a self-signed certificate, PIN pairing and the `AUTH` header), Sony (REST with `X-Auth-PSK`, plus IRCC), and VIDAA UPnP (SOAP on 38400 with a `Date` header).

Simulators run on loopback in CI. The UI team can point the hub at them (a `--simulators` flag). brs-desktop (MIT) can serve as an independent, external Roku ECP/SSDP target in an optional CI job. It does not emulate Limited mode or the Host check, which our own simulator does.

**3. Contract suites.** One test suite per driver runs against both the simulator and, opt-in, real hardware: `--tags hardware` with `WATCHME_DEVICE_<driver>=<ip>`. Rules:
- Hardware tests never run in CI.
- They only touch devices the developer owns.
- They must leave the TV in its original power state.
- Bluetooth HID gets a per-TV acceptance matrix (hardware-only): pairing, d-pad, text, consumer keys, wake.

**4. Capture/replay.** `apps/tools/capture` records a real session through a logging transport, redacts tokens, keys and MACs, and emits a transcript fixture. Fixtures from the Fire TV on the dev LAN become regression tests.

**5. Engine tests** cover capability routing, fallback order, identity merge across IP changes, pairing ownership (a hub-attached client does not pair in-process), and the power state machine:
- No toggle is sent after WoL, or when only one source reports the state.
- Samsung answering for 20 s after off, PowerState stuck at `standby` after a wake (HA #187048), and LG `turnOff` toggling back on (lgtv2 #15) all end in `Unsupported('needs confirmation')` rather than a toggle.

**6. Hub tests.** shelf handler tests for auth, Host and Origin checks, pairing-code rate limiting, credential import (owner-only) and the WebSocket protocol, plus a DNS-rebinding test (a request with a foreign Host is rejected) and an address-change test.

**7. Browser tests.** A Playwright (Apache-2.0) suite runs Chromium, Firefox and WebKit against the hub plus simulators over `http://<ip>`:
- The HttpOnly SameSite=Strict cookie works on the http origin.
- Cross-origin POSTs (CSRF) and foreign `Host` headers (DNS rebinding) are rejected from a real browser.
- No request leaves the hub origin (§5.3).
- WebKit on Linux approximates Safari; iOS Safari still needs a manual device pass before each release.
- Later, the same suite runs the direct-mode build on an HTTPS test origin.

**8. UI tests.** Flutter widget and golden tests against a fake `WatchmeClient`.

**9. Robustness.** Fuzz frame parsers (Cast length-prefixed protobuf, Android TV varint framing, Samsung/LG JSON, CEC serial frames) with malformed input.

## 9. Milestones

- **M0, skeleton.** Core models; `Transports` (io and fake); engine; the Flutter app (Linux desktop first) on `InProcessClient`; the Roku ECP driver and simulator; the Fire TV driver and simulator (DIAL wake, PIN pairing, TOFU TLS); SSDP and mDNS discovery; Wake-on-LAN; manual add; file credential store. File the iOS multicast entitlement request now (team-level; "N/A" for the App Store URL).
- **M1, web UI.** Hub (`apps/hub`, shelf) serving a Flutter web build built for offline use; `HubClient`; client pairing; Host/Origin checks; Playwright skeleton; desktop "host mode".
- **M1, first real hardware.**
  - Fire TV: DIAL discovery and wake, Lightning driver against 192.168.1.7 (PIN pairing, TOFU TLS, credential store, keys, apps, text, volume/mute where supported).
  - Opt-in ADB if the Fire TV runs Fire OS.
  - WoL driver; mDNS discovery; pairing UX that surfaces raw errors; capture tool; power orchestrator safety rules.
- **M2, Flutter app.** Android and desktop with the in-process engine and "host mode" in desktop; Google Cast and Android TV Remote v2 drivers; Android in-process Bluetooth HID; pairing-ownership rule.
- **M3, breadth.**
  - Simulators for Vizio, Sony and VIDAA UPnP land first.
  - Samsung: WebSocket, REST, UPnP and WoL.
  - LG: SSAP with an unsigned manifest, plus IP Control.
  - Vizio, Sony (REST, IRCC, SSIP); iOS build; hub BlueZ HID prototype.
- **M4, extras.** Apple TV (pure Dart port or pyatv sidecar); VIDAA with UPnP, then MQTT with an imported certificate; Philips/Titan; CEC on a Pi; IR bridges (ESPHome, Tasmota, Broadlink) and the Android IR emitter; HomeKit (iOS); optional SmartThings; optional browser-direct mode; Matter controller via a matter.js driver host; ESP32 BLE bridge.
