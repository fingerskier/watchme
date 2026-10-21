# watchme app

The Flutter app: a device list (scan, add by IP, pair, forget) and a remote, on the in-process watchme engine.

```sh
flutter run -d linux                                   # real engine: SSDP/mDNS discovery, Roku + Fire TV
flutter run -d linux --dart-define=WATCHME_DEMO=true   # simulated TVs, no network
flutter test
```

- `lib/src/bootstrap.dart` builds the client: `IoTransports`, `SsdpDiscovery` and `MdnsDiscovery`, the Roku and Fire TV drivers, and file stores in the platform's application-support directory, wrapped in `InProcessClient`.
- Platform requirements are documented where they are declared:
  - local-network usage and Bonjour service types in `macos/Runner/Info.plist` and `ios/Runner/Info.plist`;
  - network entitlements in `macos/Runner/*.entitlements`;
  - the pending iOS multicast entitlement in `ios/Runner/Runner.entitlements`;
  - network and multicast permissions in `android/app/src/main/AndroidManifest.xml`.

See the [repository README](../../README.md) for the project, the simulators and the security notes.
