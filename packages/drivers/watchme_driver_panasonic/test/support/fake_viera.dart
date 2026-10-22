import 'dart:async';

import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/src/crypto.dart';
import 'package:watchme_driver_panasonic/src/soap.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

/// The app id and keyword the fake TV knows (the brief's vectors).
const String fakeAppId = 'AQIDBAUGBwgJCg==';
const String fakeKeyword = 'ICEiIyQlJicoKSorLC0uLw==';

/// The fake TV's address and port.
const String fakeHost = '10.0.0.5';
const int fakePort = 55000;

/// A scripted VIERA on a [FakeNetworkStack], for answers the loopback
/// simulator never gives (a TV echoing secrets in a fault, say). SOAP calls
/// are dispatched on the `SOAPACTION` header's action; for
/// `X_EncryptedCommand` the inner action is decrypted with [fakeKeyword].
final class FakeViera {
  FakeViera({this.encrypted = true}) {
    network.onHttp('GET', '/nrc/sdd_0.xml', (_) {
      return HttpResult.text(
        200,
        encrypted
            ? '<scpd><name>X_GetEncryptSessionId</name></scpd>'
            : '<scpd><name>X_SendKey</name></scpd>',
      );
    }, host: fakeHost);
    network.onHttp('GET', '/nrc/ddd.xml', (_) {
      return HttpResult.text(
        200,
        '<root><device><deviceType>urn:panasonic-com:device:'
        'p00RemoteController:1</deviceType><modelNumber>TX-55GZ1500'
        '</modelNumber><UDN>uuid:4D454931-0200-1090-8001-80C755B86C63</UDN>'
        '</device></root>',
      );
    }, host: fakeHost);
    network.onHttp('GET', '/pac/ddd.xml', (_) {
      return pacOn
          ? HttpResult.text(200, '<deviceType>p00ProAVController</deviceType>')
          : HttpResult(400);
    }, host: fakeHost);
    network.onHttp('POST', RegExp(r'^/(nrc|dmr|pac)/control_0$'), (call) {
      final action = call
          .header('SOAPACTION')!
          .split('#')
          .last
          .replaceAll('"', '');
      var name = action;
      if (action == 'X_EncryptedCommand') {
        final blob = xmlLeaf(call.bodyText!, 'X_EncInfo')!;
        final inner = vieraOpen(sessionKeys, blob).text;
        name = RegExp(r'<u:(\w+) ').firstMatch(inner)!.group(1)!;
        innerActions.add(name);
      }
      actions.add(name);
      final handler = handlers[name];
      if (handler != null) return handler(call);
      return switch (name) {
        'X_GetEncryptSessionId' => answer(
          name,
          '<X_EncResult>${vieraSeal(sessionKeys, '<X_SessionId>77</X_SessionId>')}'
          '</X_EncResult>',
        ),
        'GetVolume' => answer(name, '<CurrentVolume>10</CurrentVolume>'),
        'GetMute' => answer(name, '<CurrentMute>0</CurrentMute>'),
        'X_GetAppInfo' => encryptedAnswer(name, '<X_AppInfo></X_AppInfo>'),
        _ when action == 'X_EncryptedCommand' => encryptedAnswer(name, ''),
        _ => answer(name, ''),
      };
    }, host: fakeHost);
  }

  /// Whether NRC commands are encrypted.
  final bool encrypted;

  /// The network the fake TV is on.
  final FakeNetworkStack network = FakeNetworkStack();

  /// Whether the Pro AV description answers (the TV is known on).
  bool pacOn = false;

  /// Per-action overrides (inner actions for encrypted commands).
  final Map<String, FutureOr<HttpResult> Function(HttpCall call)> handlers = {};

  /// Every SOAP action (inner ones for encrypted commands), in order.
  final List<String> actions = [];

  /// Inner actions of encrypted commands, in order.
  final List<String> innerActions = [];

  /// Session keys from [fakeKeyword].
  final VieraKeys sessionKeys = VieraKeys.forSession(fakeKeyword);

  /// The endpoint of the fake TV.
  Endpoint get endpoint => const Endpoint(fakeHost);

  /// Transports over [network].
  FakeTransports get transports => FakeTransports(network: network);

  /// A stored pairing for the fake TV.
  SharedSecretCredential get credential => SharedSecretCredential(
    driverId: 'panasonic.viera',
    deviceId: 'tv',
    createdAt: DateTime.utc(2026),
    username: fakeAppId,
    secret: fakeKeyword,
  );

  /// A plain SOAP answer to [action] with [args].
  static HttpResult answer(String action, String args) => HttpResult.text(
    200,
    '<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope><s:Body>'
    '<u:${action}Response xmlns:u="x">$args</u:${action}Response>'
    '</s:Body></s:Envelope>\n',
  );

  /// An encrypted answer to the inner [action] with [args].
  HttpResult encryptedAnswer(String action, String args) => answer(
    'X_EncryptedCommand',
    '<X_EncResult>${vieraSeal(sessionKeys, '<u:${action}Response xmlns:u="x">$args</u:${action}Response>')}'
        '</X_EncResult>',
  );

  /// A UPnP fault with [code] and [description].
  static HttpResult fault(int code, String description) => HttpResult.text(
    500,
    '<?xml version="1.0"?><s:Envelope><s:Body><s:Fault><detail><UPnPError>'
    '<errorCode>$code</errorCode><errorDescription>$description'
    '</errorDescription></UPnPError></detail></s:Fault></s:Body>'
    '</s:Envelope>',
  );
}

/// Pairing keys for scripting a TV's `X_AuthResult` in tests.
final class VieraKeysForTest {
  VieraKeysForTest.pairing(String challenge)
    : _keys = VieraKeys.forPairing(challenge);

  final VieraKeys _keys;

  /// [payload] sealed as the TV would send it.
  String seal(String payload) => vieraSeal(_keys, payload);
}
