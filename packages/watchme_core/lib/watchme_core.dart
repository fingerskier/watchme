/// The watchme core contract: capabilities, commands, results, state,
/// events, transport interfaces, discovery, drivers, pairing, credentials,
/// device records, and the engine and client interfaces.
///
/// Pure Dart and web-safe: nothing here imports `dart:io`, `package:web` or
/// Flutter. See `docs/architecture/overview.md` section 2.
library;

export 'src/capabilities.dart';
export 'src/clock.dart';
export 'src/commands.dart';
export 'src/credentials.dart';
export 'src/device_record.dart';
export 'src/discovery.dart';
export 'src/driver.dart';
export 'src/endpoint.dart';
export 'src/engine_api.dart';
export 'src/errors.dart';
export 'src/events.dart';
export 'src/pairing.dart';
export 'src/results.dart';
export 'src/state.dart';
export 'src/transports/destination.dart';
export 'src/transports/network.dart';
export 'src/transports/peripherals.dart';
export 'src/transports/tls.dart';
export 'src/transports/transports.dart';
export 'src/util/json.dart' show JsonMap;
export 'src/wol.dart';
