import 'package:flutter/material.dart' hide ConnectionState;
import 'package:watchme_core/watchme_core.dart';

import 'devices/devices_screen.dart';
import 'devices_controller.dart';
import 'theme.dart';

/// The watchme app: a device list, pairing and a remote, all driven by one
/// [WatchmeClient].
///
/// The app does not close [client]; whoever created it owns it.
class WatchmeApp extends StatefulWidget {
  /// Creates the app around [client].
  const WatchmeApp({
    super.key,
    required this.client,
    this.demo = false,
    this.scanOnStart = false,
    this.themeMode = ThemeMode.system,
  });

  /// What every screen talks to.
  final WatchmeClient client;

  /// Whether [client] simulates TVs; the Devices screen then says so.
  final bool demo;

  /// Whether to start a scan as soon as the Devices screen appears.
  final bool scanOnStart;

  /// Light, dark, or follow the system.
  final ThemeMode themeMode;

  @override
  State<WatchmeApp> createState() => _WatchmeAppState();
}

class _WatchmeAppState extends State<WatchmeApp> {
  late DevicesController _controller = DevicesController(widget.client);

  @override
  void didUpdateWidget(WatchmeApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _controller.dispose();
      _controller = DevicesController(widget.client);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WatchmeScope(
    controller: _controller,
    child: MaterialApp(
      title: 'watchme',
      debugShowCheckedModeBanner: false,
      theme: watchmeTheme(Brightness.light),
      darkTheme: watchmeTheme(Brightness.dark),
      themeMode: widget.themeMode,
      home: DevicesScreen(demo: widget.demo, scanOnStart: widget.scanOnStart),
    ),
  );
}
