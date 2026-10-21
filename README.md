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
- **Engine:**
  - merges every way a device was found (SSDP, mDNS, manual add) into one device, keyed by MAC, stable id, then IP;
  - routes each command to the best driver and falls back to the next one;
  - power orchestration that never sends a power toggle on a guess;
  - Wake-on-LAN;
  - file-backed credential and device stores.
- **Flutter app (Linux desktop first):** a device list with scanning and add-by-IP, pairing screens, and a remote with keyboard shortcuts. It also has a demo mode with simulated TVs.

**Simulated or untested:**

- **Real TVs.** Nothing has been tested against a real TV yet. The only contact with real hardware was a passive mDNS listing: it found a Fire TV stick and the Fire TV matcher accepted it. Both protocol simulators follow the published or community-documented behaviour; where real behaviour is unknown, the simulator source says so.
- **The Fire TV API is reverse-engineered.** It is not an official Amazon API and may change with a firmware update.
- **Other platforms.**
  - Android, iOS, macOS and Windows builds exist but are untested.
  - Android discovery needs a multicast lock that M0 does not take yet.
  - iOS discovery needs Apple's multicast entitlement. Until Apple grants it, iOS devices are added by IP.
  - The platform notes are in the [plist and manifest comments](apps/watchme).
- **Not built yet:** the hub, the web UI, and every other TV brand. They are planned in the [architecture document](docs/architecture/overview.md#9-milestones).

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
  watchme_testkit/         Fake transports and clock, matchers, and the Roku and
                           Fire TV simulators (bin/sim.dart)
  drivers/
    watchme_driver_roku/   Roku External Control Protocol
    watchme_driver_firetv/ Fire TV DIAL wake + remote API
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

**Simulators.** They run on loopback and print their ports. The Fire TV simulator also prints the PIN when a client starts pairing.

```sh
dart run watchme_testkit:sim roku                         # ECP on 127.0.0.1:8060
dart run watchme_testkit:sim firetv --host 127.0.0.2      # DIAL :8009, API :8080
dart run watchme_testkit:sim roku --port 0 --ssdp-port 0  # free ports, unicast SSDP
dart run watchme_testkit:sim --help
```

With the default ports, add `127.0.0.1` (Roku) or `127.0.0.2` (Fire TV) in the app's "Add by IP" dialog. Give each simulator its own address: watchme treats one address as one device.

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
| Everything else | — | Planned | — | See the [milestones](docs/architecture/overview.md#9-milestones). |

## Security notes

- **TLS: trust on first use.** Fire TV uses a per-device self-signed certificate. watchme accepts it once, while you are entering the PIN shown on the TV, and records its SHA-256. Every later connection requires that same certificate. A changed certificate fails with "does not match the pin" and the token is never sent; pair again only if you trust the change. TLS verification is never disabled globally.
- **Credentials.** Pairing tokens go straight from the driver to the credential store. The UI never receives them.
  - On desktop they are stored in plain JSON in `credentials.json`, mode `0600` (a directory watchme creates itself is made `0700`). Writes are atomic.
  - A corrupt file is moved aside, not silently discarded.
  - Encryption at rest through the OS keystore is planned.
- **Power.** watchme never sends a power toggle on a guess. It prefers discrete on/off commands and Wake-on-LAN. It sends a toggle only when two independent sources agree on the TV's current state; otherwise it asks you. A background reconnect never wakes a TV you turned off.
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
