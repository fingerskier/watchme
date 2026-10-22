import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';

/// Short waits for tests against the loopback simulator, which answers in
/// microseconds.
const SharpTimings fastTimings = SharpTimings(
  connect: Duration(seconds: 2),
  promptWait: Duration(milliseconds: 150),
  promptWaitWithLogin: Duration(milliseconds: 300),
  loginStep: Duration(milliseconds: 600),
  loginAnswer: Duration(milliseconds: 600),
  loginQuiet: Duration(milliseconds: 80),
  unterminatedQuiet: Duration(milliseconds: 80),
  reply: Duration(milliseconds: 600),
  powerReply: Duration(milliseconds: 900),
  probeReply: Duration(milliseconds: 600),
  probeBudget: Duration(seconds: 3),
  reconnectGap: Duration(milliseconds: 20),
  idleClose: Duration(seconds: 30),
  powerOnSettle: Duration(milliseconds: 600),
  powerOffSettle: Duration(milliseconds: 300),
  bootRetryInterval: Duration(milliseconds: 40),
);

/// [fastTimings] with some waits replaced.
SharpTimings fastWith({
  Duration? reply,
  Duration? reconnectGap,
  Duration? idleClose,
  Duration? powerOnSettle,
  Duration? powerOffSettle,
}) => SharpTimings(
  connect: fastTimings.connect,
  promptWait: fastTimings.promptWait,
  promptWaitWithLogin: fastTimings.promptWaitWithLogin,
  loginStep: fastTimings.loginStep,
  loginAnswer: fastTimings.loginAnswer,
  loginQuiet: fastTimings.loginQuiet,
  unterminatedQuiet: fastTimings.unterminatedQuiet,
  reply: reply ?? fastTimings.reply,
  powerReply: fastTimings.powerReply,
  probeReply: fastTimings.probeReply,
  probeBudget: fastTimings.probeBudget,
  reconnectGap: reconnectGap ?? fastTimings.reconnectGap,
  idleClose: idleClose ?? fastTimings.idleClose,
  powerOnSettle: powerOnSettle ?? fastTimings.powerOnSettle,
  powerOffSettle: powerOffSettle ?? fastTimings.powerOffSettle,
  bootRetryInterval: fastTimings.bootRetryInterval,
);
