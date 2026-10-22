import 'package:flutter/material.dart' hide ConnectionState;
import 'package:watchme_core/watchme_core.dart';

import 'src/app.dart';
import 'src/bootstrap.dart';
import 'src/demo/demo_client.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final WatchmeClient client;
  try {
    client = await createClient();
  } on Object catch (error) {
    // Without a client there is nothing to show but why.
    runApp(StartupErrorApp(error: error));
    return;
  }
  runApp(
    WatchmeApp(
      client: client,
      demo: client is DemoWatchmeClient,
      scanOnStart: true,
    ),
  );
}

/// Shown when the engine cannot start, e.g. its state directory is not
/// writable.
class StartupErrorApp extends StatelessWidget {
  /// Creates the error screen for [error].
  const StartupErrorApp({super.key, required this.error});

  /// What went wrong.
  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'watchme',
    debugShowCheckedModeBanner: false,
    theme: watchmeTheme(Brightness.light),
    darkTheme: watchmeTheme(Brightness.dark),
    home: Scaffold(
      appBar: AppBar(title: const Text('watchme')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'watchme could not start',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            SelectableText(
              error is WatchmeError
                  ? (error as WatchmeError).message
                  : error.toString(),
            ),
            const SizedBox(height: 12),
            const Text(
              'Run with --dart-define=WATCHME_DEMO=true to try the app on '
              'simulated TVs.',
            ),
          ],
        ),
      ),
    ),
  );
}
