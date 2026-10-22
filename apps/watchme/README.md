# watchme app

The Flutter app: a device list (scan, add by IP, pair, forget) and a remote, on the in-process watchme engine.

```sh
flutter run -d linux                                   # real engine: SSDP/mDNS discovery, Roku + Fire TV
flutter run -d linux --dart-define=WATCHME_DEMO=true   # simulated TVs, no network
flutter test
```

- `lib/src/bootstrap.dart` builds the client: `IoTransports`, `SsdpDiscovery` and `MdnsDiscovery`, the Roku and Fire TV drivers, and file stores in the platform's application-support directory, wrapped in `InProcessClient`.
- The engine and the network stack contact only local-network addresses, plus loopback (`lib/src/destination_policy.dart`). Loopback is allowed because the simulators listen on 127.0.0.1 and the in-process app runs in the user's own trust domain. Discovery stays strictly LAN-only. The M1 hub must not allow loopback.
- When watchme cannot tell whether the TV is on, a power command asks "Is the TV on right now?" and sends the user's answer as `SetPower(..., userConfirmed: true)`. The remote's Power key is a toggle intent (`PressKey(RemoteKey.power)`), so its question offers both "turn it off" and "turn it on". Power on and Power off stay discrete: their question offers what the button says or "It's already on/off", which sends nothing. The question is asked only while the remote is the page in front. The engine's Power key asks only when it cannot settle the TV's state: two agreeing sources settle it, and so does one source the TV reports itself (a Roku TV's `power-mode`; a Roku player's describes the player, so it does not count) when a discrete on/off command can act on it. The demo client follows the engine: the demo Roku reports its state, so its Power key sends the discrete off or on (and asks within 20 seconds of the last power command); the demo Fire TV can only infer its state, so its Power key always asks.
- Platform requirements are documented where they are declared:
  - local-network usage and Bonjour service types in `macos/Runner/Info.plist` and `ios/Runner/Info.plist`;
  - network entitlements in `macos/Runner/*.entitlements`;
  - the pending iOS multicast entitlement in `ios/Runner/Runner.entitlements`;
  - network and multicast permissions in `android/app/src/main/AndroidManifest.xml`.

See the [repository README](../../README.md) for the project, the simulators and the security notes.
