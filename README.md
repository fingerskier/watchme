# watchme

watchme controls smart TVs on your home network: find them, pair once, then use a remote with a d-pad, volume, text entry, an app launcher and power. One pure-Dart engine speaks each TV's own protocol. The same engine runs inside the Flutter app now and will run inside a small LAN hub that serves a web UI later.

Licence: Apache-2.0. The project is early (milestone M0) and has not yet been used with real TVs. See [Status](#status-m0).

## Status (M0)

**Works, and is tested end to end against protocol simulators on loopback:**

- **Roku (ECP):** discovery over SSDP or adding a device by IP. Supported commands:
  - keys, including press-and-hold;
  - text input;
  - the app list, and app launch with deep-link parameters;
  - TV inputs and channels;
  - discrete power on and off;
  - reading the foreground app and playback state.

  watchme detects "Control by mobile apps = Limited" and reports it with the TV's own words.
- **Fire TV (remote API):**
  - adding a device by IP even while it sleeps;
  - a DIAL wake before every session;
  - 4-digit PIN pairing that pins the TV's certificate on first use (TOFU);
  - keys and holds, text into the on-screen keyboard, the app list and app launch;
  - play/pause and scan, relative volume and mute over HDMI-CEC, and sleep/wake.

  A revoked token surfaces as "pair again".
- **VIZIO (SmartCast API):**
  - adding a TV by IP or finding it over mDNS (`_viziocast._tcp`), on port 7345 or, for firmware older than 4.0, 9000;
  - 4-digit PIN pairing that pins the TV's certificate on first use; pairing again replaces the TV's old token instead of adding one;
  - keys, absolute volume and mute with readback, inputs, channels on sets with a tuner, discrete play and pause, text into a focused field, and Netflix, YouTube and SmartCast Home from a built-in launch table;
  - discrete power on and off, and the TV's own power report once paired.
- **Panasonic VIERA (network remote control):**
  - adding a TV by IP or finding it over SSDP;
  - plain sets (2011-2017) need no pairing; sets from 2018 on pair with a 4-digit PIN, and their commands are encrypted;
  - keys, absolute volume and mute with readback (no pairing needed for these, even on encrypted sets), the app list and app launch, HDMI and TV inputs, channel digits, media keys and text;
  - power through the TV's only power command, a toggle: watchme sends it only when you confirm the TV's state. For power-on it prefers Wake-on-LAN, but only once it knows the TV's MAC address, which it cannot read from the TV yet.
- **Sharp AQUOS (IP control):**
  - adding a TV by IP or finding it over SSDP;
  - an optional login (login ID and password) collected when you pair, and, with your consent, the TV setting that lets it be switched on over the network;
  - keys, absolute volume and mute with readback on the 0-60 or 0-100 scale the model uses, inputs, direct channel tuning, the Netflix key, and discrete power on and off with the TV's own power report.
- **Engine:**
  - merges every way a device was found (SSDP, mDNS, manual add) into one device, keyed by MAC, stable id, then IP;
  - routes each command to the best driver and falls back to the next one, but never repeats a command that may already have reached the TV;
  - power orchestration that never sends a power toggle on a guess: the Power key asks "Is the TV on right now?" unless two sources agree on the TV's state, or the TV itself reports it and a discrete on/off command can act on it (a Roku, VIZIO or Sharp TV alone);
  - contacts local-network addresses only;
  - Wake-on-LAN;
  - file-backed credential and device stores.
- **Flutter app (Linux desktop first):** a device list with scanning and add-by-IP, pairing screens, and a remote with keyboard shortcuts. It also has a demo mode with simulated TVs.

**Simulated or untested:**

- **Real TVs.** Nothing has been tested against a real TV yet. The only contact with real hardware was a passive mDNS listing: it found a Fire TV stick and the Fire TV matcher accepted it. The protocol simulators follow the published or community-documented behaviour; where real behaviour is unknown, the simulator source says so.
- **Reverse-engineered protocols.** The Fire TV API and the Panasonic VIERA remote control are not official APIs, and the VIZIO SmartCast API is documented only by independent clients. Any of them may change with a firmware update.
- **Panasonic power state.** A VIERA reports its screen state only through UPnP eventing, which watchme does not receive yet, so its power state is a guess and its Power key always asks.
- **Other platforms.**
  - Android, iOS, macOS and Windows builds exist but are untested.
  - Android discovery needs a multicast lock that M0 does not take yet.
  - iOS discovery needs Apple's multicast entitlement. Until Apple grants it, iOS devices are added by IP.
  - The platform notes are in the [plist and manifest comments](apps/watchme).
- **Not built yet:** the hub, the web UI, and the other TV brands (Samsung, LG, Android TV, Sony and more). They are planned in the [architecture document](docs/architecture/overview.md#9-milestones).

## Why a Flutter app first, not a web app

A browser page cannot discover TVs, send Wake-on-LAN or open the raw sockets most TV protocols need, and on most browsers it cannot reach plain-HTTP LAN devices at all. So watchme starts with a Flutter app that embeds the engine. A web UI comes later, served by a LAN hub that runs the same engine. The evidence is in [docs/research/tv-control-landscape.md](docs/research/tv-control-landscape.md); the design is in [docs/architecture/overview.md](docs/architecture/overview.md).

## Repository layout

```
packages/
  watchme_core/            Pure-Dart, web-safe contract: capabilities, commands, state,
                           events, transport interfaces, drivers, pairing, credentials
  watchme_io/              dart:io transports: HTTP(S) with TLS pinning, WebSocket, TCP,
                           UDP, SSDP and mDNS discovery, Wake-on-LAN, file stores
  watchme_engine/          Device registry and identity merge, discovery and pairing
                           orchestration, capability router, power orchestrator,
                           InProcessClient
  watchme_testkit/         Fake transports and clock, matchers, and the Roku, Fire TV,
                           VIZIO, Panasonic and Sharp simulators (bin/sim.dart)
  drivers/
    watchme_driver_roku/      Roku External Control Protocol
    watchme_driver_firetv/    Fire TV DIAL wake + remote API
    watchme_driver_vizio/     VIZIO SmartCast API (HTTPS, PIN pairing)
    watchme_driver_panasonic/ Panasonic VIERA network remote control (UPnP/SOAP)
    watchme_driver_sharp/     Sharp AQUOS IP control (TCP text protocol)
  watchme_e2e/             End-to-end tests: engine + real io + drivers vs simulators
apps/
  watchme/                 Flutter app (Linux desktop first)
docs/
  research/                Platform research
  architecture/            Architecture and milestones
```

The repository is a Dart [pub workspace](https://dart.dev/tools/pub/workspaces): one `pubspec.lock` at the root, and every package uses `resolution: workspace`. `watchme_core`, `watchme_engine` and the drivers never import `dart:io` or Flutter. CI proves this by compiling them to JavaScript.

## Developer quickstart

Requirements: Flutter 3.47.7 (stable, bundles Dart 3.13.5). On Linux, the desktop build also needs `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`.

```sh
flutter pub get                      # resolves the whole workspace, from the repo root
dart analyze --fatal-infos           # analyzes every package and the app

(cd packages/watchme_core && dart test)   # likewise for every package under packages/
(cd packages/watchme_e2e && dart test)    # the whole system against the simulators
(cd apps/watchme && flutter test)
```

**Simulators.** They run on loopback and print their ports. The Fire TV, VIZIO and Panasonic simulators also print the PIN when a client starts pairing.

```sh
dart run watchme_testkit:sim roku                         # ECP on 127.0.0.1:8060
dart run watchme_testkit:sim firetv --host 127.0.0.2      # DIAL :8009, API :8080
dart run watchme_testkit:sim vizio --host 127.0.0.3       # HTTPS API :7345
dart run watchme_testkit:sim panasonic --host 127.0.0.4 --encrypted   # :55000, PIN pairing
dart run watchme_testkit:sim sharp --host 127.0.0.5 --login admin --password secret
dart run watchme_testkit:sim roku --port 0 --ssdp-port 0  # free ports, unicast SSDP
dart run watchme_testkit:sim --help
```

With the default ports, add `127.0.0.1` (Roku), `127.0.0.2` (Fire TV) and so on in the app's "Add by IP" dialog. Give each simulator its own address: watchme treats one address as one device. The app reaches loopback only for addresses you type; its scan never takes a loopback address from the network, so it does not list the simulators.

**Run the app.**

```sh
cd apps/watchme
flutter run -d linux                                   # the real engine
flutter run -d linux --dart-define=WATCHME_DEMO=true   # simulated TVs, no network
```

The app keeps `credentials.json` and `devices.json` in its application-support directory; on Linux that is `~/.local/share/dev.watchme.watchme/`.

**Discovery and host firewalls.** SSDP replies arrive as unicast UDP from each TV to a random port. A host firewall with a default-deny input policy, such as ufw's default, drops them, so scans find nothing over SSDP even though the TVs answer. mDNS and add-by-IP are not affected. To let SSDP replies in, allow UDP from your LAN, e.g. `sudo ufw allow from 192.168.1.0/24 proto udp`.

## Supported devices

| Platform | Driver | Status | Pairing | Notes |
|---|---|---|---|---|
| Roku TVs and players | `roku.ecp` (Roku ECP, documented) | Implemented, simulator-tested | None | Needs "Control by mobile apps = Enabled" on Roku OS 14.1+ (the default, Limited, refuses keys). Players reach TV power and volume only through HDMI-CEC. |
| Amazon Fire TV | `firetv.lightning` (remote API, reverse-engineered) | Implemented, simulator-tested | 4-digit PIN on the TV | Wakes the stick through DIAL. Volume and mute go over HDMI-CEC and are confirmed only on some models. No discrete play/pause. |
| VIZIO SmartCast and VIZIO OS TVs (2016 on, including onn VIZIO OS sets) | `vizio.smartcast` (SmartCast API, community-documented) | Implemented, simulator-tested | 4-digit PIN on the TV | Port 7345, or 9000 on firmware older than 4.0 (the firmware decides, not the model year; watchme tries both). Power-on over the network needs Power Mode = Quick Start; in Eco mode the TV leaves the network and only Wake-on-LAN, best-effort, can wake it. Sound bars and Crave speakers are not supported yet. Pre-2016 VIA / Internet Apps sets have no API. |
| Panasonic VIERA, 2011-2023 (`TC-`, `TX-`, `TH-` models) | `panasonic.viera` (network remote control, reverse-engineered) | Implemented, simulator-tested | None on 2011-2017 sets; a 4-digit PIN on 2018 and later sets (F series on) | Needs Menu > Network > TV Remote App Settings > TV Remote = On (VIERA Remote on 2012-2014 sets), and watchme on the TV's own subnet: the TV answers 403 to any other. The letter after the screen size gives the year (C 2015, D 2016, E 2017, F 2018 ...). Power is a toggle, and many 2011-2015 sets cannot be switched on over the network. A US VIERA is a pre-2017 `TC-...U` set. 2024 and later Panasonic TVs run Fire TV, Google TV, TiVo OS or Roku and are not covered by this driver. |
| Sharp AQUOS, Sharp-built (US `LC-...U` 2010-2014, US 4T-B 2021, EU 2011-2013, JP) | `sharp.aquos` (IP control, from Sharp's manuals) | Implemented, simulator-tested | Optional: the login ID and password set on the TV | Turn on AQUOS Remote Control (IP Control) in the TV's network menu; the port is 10002 unless you changed it. US 2010-2014 sets switch on over the network only with the power-on command setting (RSPW, which raises standby power; watchme asks before changing it), 2014, 4T-B and JP sets with Quick Start Mode; EU sets cannot be switched on over the network. 2015 sets answer no queries (keys and power only). Hisense-built 2016-2019 sets (`LC-xxN/P/Q...U`) and Sharp Roku, Google TV, TiVo and Xumo TVs are not covered. |
| Everything else | — | Planned | — | See the [milestones](docs/architecture/overview.md#9-milestones). |

## Security notes

- **TLS: trust on first use.** Fire TV and VIZIO use self-signed certificates (a VIZIO's is the same on every set, so its pairing token is the real secret). watchme accepts the certificate once, while you are entering the PIN shown on the TV, and records its SHA-256. Every later connection requires that same certificate. A changed certificate fails with "does not match the pin" and the token is never sent; pair again only if you trust the change. TLS verification is never disabled globally.
- **No encryption on some protocols.** Panasonic's plain sets, and every Sharp TV, take commands in clear text, and a Sharp login is sent in clear text too. Anyone on the network can send the same commands; a Sharp login only keeps out clients that do not know it.
- **Credentials.** Pairing tokens, keys and logins go straight from the driver to the credential store. The UI never receives them, and no error message carries one: secrets and secret-bearing fields in a TV's answer are redacted, however the TV escaped them.
  - On desktop they are stored in plain JSON in `credentials.json`, mode `0600` (a directory watchme creates itself is made `0700`). Writes are atomic.
  - A corrupt file is moved aside, not silently discarded.
  - Encryption at rest through the OS keystore is planned.
- **Power.** watchme never sends a power toggle on a guess. It prefers discrete on/off commands and Wake-on-LAN. It sends a toggle only when two independent sources agree on the TV's current state, or when you have just told it what the TV shows; otherwise it asks you. The Power key follows the same rule, with one relaxation: when the TV itself reports its state (a Roku TV's `power-mode`) and a discrete on or off command exists, that one report is enough to pick the discrete command, because a discrete command repeated changes nothing. An inferred state (a Fire TV's or a Panasonic's) never is, nor is a streaming player's report of its own power (a Roku stick's), and a single report never sends a toggle. Within 20 seconds of the last power command the Power key always asks (30 seconds for a Panasonic, which may drop a toggle or a Wake-on-LAN packet that soon after switching). Power commands to one TV run one at a time, and a hold of the Power key is refused.
- **Waking.** Only a command you send can wake a TV. Background reconnects, refreshes and polling never do: a TV that drops off the network shows as disconnected, with its last known state marked as such, until it answers again.
- **Local network only.** The engine and the network stack contact private (RFC 1918), link-local and unique-local IPv6 addresses only. Public addresses, `100.64.0.0/10` (carrier-grade NAT and VPN overlays such as Tailscale) and reserved ranges are refused before anything is sent, for manual adds, discovery replies and every connection. A host name is resolved by watchme itself, every address it resolves to is checked, and the connection goes to the checked address. The desktop app also allows loopback (`127.0.0.1`), for the simulators; the planned hub will not.
- **No repeats.** A command that may already have reached the TV (a timeout, or a volume run cut short after some steps) is never retried or sent through another driver. Forgetting a TV or quitting the app stops a command in progress before its next request.
- **Probes are passive.** Probes only read device state. Discovery and add-by-IP never wake, pair with or change a device; only connecting to a paired device or pairing does.
- **Device text is kept.** Errors keep the TV's own words (for example Roku's "ECP command not allowed in Limited mode."), so you can see what the TV said.

## Contributing

- Run `dart format`, `dart analyze --fatal-infos` and the tests of every package you touch before sending a change. CI runs all of them and builds the Linux app.
- Drivers and `watchme_core` must stay pure Dart: no `dart:io`, `package:web` or Flutter imports. Drivers talk only to the `Transports` interfaces and are tested against `FakeTransports` and the simulators.
- Never point tests at real devices. Hardware tests, when they arrive, are opt-in and run only against devices you own.
- **Licensing.**
  - Port code only from Apache-2.0, MIT or BSD sources, and record each one in [THIRD_PARTY.md](THIRD_PARTY.md).
  - GPL, LGPL and AGPL code may be read for reference only.
  - New dependencies must be Apache, MIT or BSD licensed.
  - Do not add `flutter_blue_plus`; its licence requires a paid licence for for-profit organisations.

## Licence

Copyright 2026 the watchme authors. Licensed under the [Apache License, Version 2.0](LICENSE); see also [NOTICE](NOTICE) and [THIRD_PARTY.md](THIRD_PARTY.md).
