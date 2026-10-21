import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

/// [ProcessRunner] on `dart:io` processes (desktop and hub; e.g.
/// `cec-ctl`). Output is decoded as UTF-8, replacing malformed bytes.
///
/// Errors: a missing or non-executable program fails with
/// [WatchmeErrorCode.unsupported]; [run] past its timeout kills the process
/// and fails with [WatchmeErrorCode.timeout].
final class IoProcessRunner implements ProcessRunner {
  /// Creates a runner. [environment] is added to the inherited one.
  const IoProcessRunner({this.environment, this.workingDirectory});

  /// Extra environment variables.
  final Map<String, String>? environment;

  /// Working directory for started processes.
  final String? workingDirectory;

  @override
  Future<ProcessRunResult> run(
    String exe,
    List<String> args, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final process = await _start(exe, args);
    process.stdin.close().ignore();
    final stdout = process.stdout.transform(_utf8).join();
    final stderr = process.stderr.transform(_utf8).join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessRunResult(
        exitCode,
        stdout: await stdout,
        stderr: await stderr,
      );
    } on TimeoutException {
      await _terminate(process);
      throw WatchmeError.timeout(
        '$exe did not finish within ${timeout.inMilliseconds} ms',
      );
    }
  }

  @override
  Future<LineProcess> start(String exe, List<String> args) async =>
      _IoLineProcess(await _start(exe, args));

  Future<Process> _start(String exe, List<String> args) async {
    try {
      return await Process.start(
        exe,
        args,
        environment: environment,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      throw WatchmeError.unsupported('Cannot run $exe: ${e.message}', cause: e);
    }
  }
}

final _utf8 = const Utf8Decoder(allowMalformed: true);

Future<void> _terminate(Process process) async {
  process.kill();
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
}

final class _IoLineProcess implements LineProcess {
  _IoLineProcess(this._process) {
    // Drain both pipes at once so a chatty stream the caller ignores cannot
    // fill its pipe and block the process; lines are buffered until heard.
    _process.stdout
        .transform(_utf8)
        .transform(const LineSplitter())
        .listen(_stdout.add, onDone: _stdout.close);
    _process.stderr
        .transform(_utf8)
        .transform(const LineSplitter())
        .listen(_stderr.add, onDone: _stderr.close);
  }

  final Process _process;
  final StreamController<String> _stdout = StreamController();
  final StreamController<String> _stderr = StreamController();

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  void writeLine(String line) => _process.stdin.writeln(line);

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> kill() => _terminate(_process);
}
