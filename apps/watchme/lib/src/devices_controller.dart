import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:watchme_core/watchme_core.dart';

/// The app-wide view of a [WatchmeClient]: the live device list and whether
/// a scan is running.
///
/// One controller lives for the whole app (see [WatchmeScope]) so every
/// screen reads the same list and a device's state updates everywhere at
/// once.
class DevicesController extends ChangeNotifier {
  /// Subscribes to [client]'s device list.
  DevicesController(this.client) {
    _subscription = client.watchDevices().listen(_onDevices, onError: _onError);
  }

  /// The client every screen talks to.
  final WatchmeClient client;

  late final StreamSubscription<List<DeviceView>> _subscription;
  List<DeviceView> _devices = const [];
  bool _loaded = false;
  bool _scanning = false;
  bool _disposed = false;
  Object? _error;

  /// The current device list.
  List<DeviceView> get devices => _devices;

  /// Whether the first device list has arrived.
  bool get loaded => _loaded;

  /// Whether a scan started through [scan] is still running.
  bool get scanning => _scanning;

  /// The last error from the device-list stream, cleared by the next list.
  Object? get error => _error;

  /// The device with [id], or null when it is not in the list.
  DeviceView? byId(String id) {
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// Runs discovery through the client. A second call while one is running
  /// returns at once. Errors from the client propagate to the caller.
  Future<void> scan() async {
    if (_scanning) return;
    _setScanning(true);
    try {
      await client.scan();
    } finally {
      _setScanning(false);
    }
  }

  void _setScanning(bool value) {
    _scanning = value;
    if (!_disposed) notifyListeners();
  }

  void _onDevices(List<DeviceView> devices) {
    _devices = List.unmodifiable(devices);
    _loaded = true;
    _error = null;
    notifyListeners();
  }

  void _onError(Object error) {
    _error = error;
    _loaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

/// Makes the app's [DevicesController] available to every route.
class WatchmeScope extends InheritedNotifier<DevicesController> {
  /// Provides [controller] to [child].
  const WatchmeScope({
    super.key,
    required DevicesController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller; the caller rebuilds when the device list changes.
  static DevicesController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WatchmeScope>();
    assert(scope != null, 'No WatchmeScope above this context');
    return scope!.notifier!;
  }

  /// The controller, without subscribing the caller to changes. Safe in
  /// callbacks and in `initState`.
  static DevicesController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<WatchmeScope>();
    assert(scope != null, 'No WatchmeScope above this context');
    return scope!.notifier!;
  }
}
