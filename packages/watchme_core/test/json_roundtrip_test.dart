import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

/// Encodes to a JSON string and back, as a process boundary would.
JsonMap wire(JsonMap json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

final t0 = DateTime.utc(2026, 10, 21, 12, 30);

void main() {
  group('Command', () {
    final commands = <Command>[
      const PressKey(RemoteKey.home),
      const PressKey(RemoteKey.volumeUp, KeyAction.down),
      const SetPower(true),
      const SetPower(false),
      const SetPower(true, userConfirmed: true),
      const SetPower(false, userConfirmed: true),
      const SetVolume(42),
      const StepVolume(-3),
      const SetMute(null),
      const SetMute(true),
      LaunchApp(
        '12',
        deepLink: Uri.parse('netflix://title/80057281'),
        params: const {'contentId': 'abc', 'mediaType': 'movie'},
      ),
      const LaunchApp('dev'),
      const ListApps(),
      const SelectInput('hdmi2'),
      const TuneChannel('7.1'),
      const TypeText('hello world', replace: true),
      const Media(MediaAction.seek, seekTo: Duration(minutes: 3, seconds: 7)),
      const Media(MediaAction.playPause),
      const MovePointer(-10, 25, click: true),
      const ShowToast('Dinner is ready'),
      CastUrl(
        Uri.parse('http://10.0.0.2/movie.mp4'),
        mimeType: 'video/mp4',
        title: 'Movie',
      ),
      const TakeScreenshot(),
    ];

    for (final command in commands) {
      test('round-trips $command', () {
        final decoded = Command.fromJson(wire(command.toJson()));
        expect(decoded, command);
        expect(decoded.hashCode, command.hashCode);
        expect(decoded.toJson()['type'], command.type);
      });
    }

    test('every command type is covered', () {
      expect(commands.map((c) => c.type).toSet(), hasLength(15));
    });

    test('capability follows the command and key', () {
      expect(
        const PressKey(RemoteKey.up).capability,
        Capability.dpadNavigation,
      );
      expect(
        const PressKey(RemoteKey.volumeDown).capability,
        Capability.volume,
      );
      expect(const SetPower(true).capability, Capability.powerOn);
      expect(const SetPower(false).capability, Capability.powerOff);
      expect(const ListApps().capability, Capability.appList);
    });

    test('defaults are applied when optional fields are absent', () {
      expect(
        Command.fromJson({'type': 'pressKey', 'key': 'back'}),
        const PressKey(RemoteKey.back),
      );
      expect(
        Command.fromJson({'type': 'typeText', 'text': 'x'}),
        const TypeText('x'),
      );
    });

    test('rejects unknown types and bad fields', () {
      expect(
        () => Command.fromJson({'type': 'selfDestruct'}),
        throwsFormatException,
      );
      expect(
        () => Command.fromJson({'type': 'pressKey', 'key': 'warpDrive'}),
        throwsFormatException,
      );
      expect(
        () => Command.fromJson({'type': 'setVolume', 'level': 'loud'}),
        throwsFormatException,
      );
    });

    test('accepts integral doubles for ints (JSON from JavaScript)', () {
      expect(
        Command.fromJson({'type': 'setVolume', 'level': 30.0}),
        const SetVolume(30),
      );
    });

    group('SetPower.userConfirmed', () {
      test('defaults to false and is omitted from JSON when false', () {
        expect(const SetPower(true).userConfirmed, isFalse);
        expect(const SetPower(true).toJson(), {'type': 'setPower', 'on': true});
        expect(const SetPower(false, userConfirmed: true).toJson(), {
          'type': 'setPower',
          'on': false,
          'userConfirmed': true,
        });
      });

      test('absent or null decodes as false; true survives the wire', () {
        expect(
          Command.fromJson({'type': 'setPower', 'on': true}),
          const SetPower(true),
        );
        expect(
          Command.fromJson({
            'type': 'setPower',
            'on': true,
            'userConfirmed': null,
          }),
          const SetPower(true),
        );
        final decoded = Command.fromJson(
          wire(const SetPower(true, userConfirmed: true).toJson()),
        );
        expect(decoded, isA<SetPower>());
        expect((decoded as SetPower).userConfirmed, isTrue);
        expect(decoded.on, isTrue);
      });

      test('is part of equality: a confirmed command is a different '
          'command', () {
        expect(
          const SetPower(true, userConfirmed: true),
          isNot(const SetPower(true)),
        );
        expect(
          const SetPower(false, userConfirmed: true),
          isNot(const SetPower(true, userConfirmed: true)),
        );
        expect(
          const SetPower(true, userConfirmed: true).hashCode,
          const SetPower(true, userConfirmed: true).hashCode,
        );
      });

      test('does not change the capability', () {
        expect(
          const SetPower(true, userConfirmed: true).capability,
          Capability.powerOn,
        );
        expect(
          const SetPower(false, userConfirmed: true).capability,
          Capability.powerOff,
        );
      });

      test('rejects a non-boolean value', () {
        expect(
          () => Command.fromJson({
            'type': 'setPower',
            'on': true,
            'userConfirmed': 'yes',
          }),
          throwsFormatException,
        );
      });
    });
  });

  group('CommandResult', () {
    final results = <CommandResult>[
      const Confirmed(),
      const Confirmed(
        payload: AppListPayload([
          AppInfo(id: '12', name: 'Netflix', version: '5.1'),
          AppInfo(id: 'tvinput.hdmi1', name: 'HDMI 1', kind: AppKind.input),
        ]),
      ),
      Confirmed(
        payload: ScreenshotPayload(
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
          mimeType: 'image/png',
        ),
      ),
      const SentUnconfirmed(),
      const Unsupported(Unsupported.needsConfirmation),
      const Failed(
        WatchmeError.partiallyDelivered(
          'Stepped the volume 1 of 3 times before the TV stopped answering',
        ),
      ),
      const Failed(
        WatchmeError.destinationRefused(
          'Refused to contact 8.8.8.8: it is a public internet address.',
        ),
      ),
      const Failed(
        WatchmeError.rejected(
          'Roku refused the key press',
          rawDeviceMessage: 'ECP command not allowed in Limited mode.',
        ),
      ),
    ];

    for (final result in results) {
      test('round-trips $result', () {
        final decoded = CommandResult.fromJson(wire(result.toJson()));
        expect(decoded, result);
        expect(decoded.hashCode, result.hashCode);
      });
    }

    test('Failed exposes the raw device message', () {
      final failed = results.last as Failed;
      expect(
        failed.rawDeviceMessage,
        'ECP command not allowed in Limited mode.',
      );
      expect(failed.delivered, isFalse);
      expect(const SentUnconfirmed().delivered, isTrue);
    });

    test('partiallyDelivered is true only for a partial-delivery failure, '
        'which is not delivered', () {
      const partial = Failed(
        WatchmeError.partiallyDelivered('1 of 3 volume steps'),
      );
      expect(partial.partiallyDelivered, isTrue);
      expect(partial.delivered, isFalse);
      final decoded = CommandResult.fromJson(wire(partial.toJson()));
      expect(decoded.partiallyDelivered, isTrue);
      for (final other in <CommandResult>[
        const Confirmed(),
        const SentUnconfirmed(),
        const Unsupported(Unsupported.needsConfirmation),
        for (final code in WatchmeErrorCode.values)
          if (code != WatchmeErrorCode.partiallyDelivered)
            Failed(WatchmeError(code, 'x')),
      ]) {
        expect(other.partiallyDelivered, isFalse, reason: '$other');
      }
    });
  });

  group('WatchmeError codes', () {
    test('every code round-trips by name', () {
      for (final code in WatchmeErrorCode.values) {
        final error = WatchmeError(code, 'm', rawDeviceMessage: 'raw');
        final decoded = WatchmeError.fromJson(wire(error.toJson()));
        expect(decoded, error);
        expect(decoded.toJson()['code'], code.name);
      }
    });

    test('named constructors set their code', () {
      expect(
        const WatchmeError.partiallyDelivered('m').code,
        WatchmeErrorCode.partiallyDelivered,
      );
      expect(
        const WatchmeError.destinationRefused('m').code,
        WatchmeErrorCode.destinationRefused,
      );
      final cause = StateError('second request failed');
      final partial = WatchmeError.partiallyDelivered('m', cause: cause);
      expect(partial.cause, same(cause));
      expect(WatchmeError.fromJson(wire(partial.toJson())).cause, isNull);
    });

    test('the wire names of the new codes are stable', () {
      expect(WatchmeErrorCode.partiallyDelivered.name, 'partiallyDelivered');
      expect(WatchmeErrorCode.destinationRefused.name, 'destinationRefused');
      expect(
        WatchmeError.fromJson({'code': 'partiallyDelivered', 'message': 'm'})
            .code,
        WatchmeErrorCode.partiallyDelivered,
      );
    });
  });

  test('WatchmeError round-trips without its cause', () {
    final error = WatchmeError.timeout(
      'No answer',
      rawDeviceMessage: 'raw',
      cause: StateError('x'),
    );
    final decoded = WatchmeError.fromJson(wire(error.toJson()));
    expect(decoded, error);
    expect(decoded.cause, isNull);
    expect(error.toString(), contains('timeout'));
  });

  test('CapabilitySupport round-trips with flags and note', () {
    const support = CapabilitySupport.partial(
      Capability.volume,
      flags: {CapFlag.relativeOnly, CapFlag.writeOnly},
      note: 'VolumeUp/VolumeDown only',
    );
    expect(CapabilitySupport.fromJson(wire(support.toJson())), support);
    expect(
      CapabilitySupport.fromJson(
        wire(const CapabilitySupport.no(Capability.pointer).toJson()),
      ),
      const CapabilitySupport.no(Capability.pointer),
    );
  });

  test('DiscoveryHit round-trips', () {
    const hit = DiscoveryHit(
      host: '192.0.2.10',
      provider: DiscoveryProviderId.ssdp,
      port: 8060,
      serviceType: 'roku:ecp',
      name: 'Living Room',
      attributes: {
        DiscoveryAttr.location: 'http://192.0.2.10:8060/',
        DiscoveryAttr.usn: 'uuid:roku:ecp:X00400ABCDEF',
      },
      mac: 'aa:bb:cc:dd:ee:ff',
      stableId: 'roku:serial:X00400ABCDEF',
    );
    expect(DiscoveryHit.fromJson(wire(hit.toJson())), hit);
    const minimal = DiscoveryHit(host: '192.0.2.11', provider: 'manual');
    expect(DiscoveryHit.fromJson(wire(minimal.toJson())), minimal);
  });

  group('Credential', () {
    final credentials = <Credential>[
      TokenCredential(
        driverId: 'firetv.lightning',
        deviceId: 'dev-1',
        createdAt: t0,
        token: 'client-token',
        peerCertSha256: 'ab' * 32,
        expiresAt: t0.add(const Duration(days: 30)),
        refreshToken: 'refresh',
        refreshExpiresAt: t0.add(const Duration(days: 60)),
        attributes: const {'friendlyName': 'watchme'},
      ),
      ClientCertCredential(
        driverId: 'androidtv.remote2',
        deviceId: 'dev-2',
        createdAt: t0,
        certificatePem: '-----BEGIN CERTIFICATE-----\nAAA\n',
        privateKeyPem: '-----BEGIN PRIVATE KEY-----\nBBB\n',
      ),
      UserSuppliedClientCertCredential(
        driverId: 'vidaa.mqtt',
        deviceId: 'dev-3',
        createdAt: t0,
        certificatePem: 'cert',
        privateKeyPem: 'key',
        password: 'pw',
        label: 'my VIDAA cert',
      ),
      KeyPairCredential(
        driverId: 'appletv.companion',
        deviceId: 'dev-4',
        createdAt: t0,
        algorithm: 'ed25519',
        publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
        privateKey: Uint8List.fromList(List.generate(32, (i) => 255 - i)),
        peerPublicKey: Uint8List.fromList([1, 2, 3]),
        peerIdentifier: 'ATV-ID',
      ),
      SharedSecretCredential(
        driverId: 'sony.rest',
        deviceId: 'dev-5',
        createdAt: t0,
        secret: '0000',
        username: 'admin',
      ),
      CloudOAuthCredential(
        driverId: 'smartthings',
        deviceId: 'dev-6',
        createdAt: t0,
        accessToken: 'access',
        refreshToken: 'refresh',
        clientId: 'client',
        clientSecret: 'secret',
        scopes: const ['r:devices:*', 'x:devices:*'],
        tokenEndpoint: Uri.parse('https://api.smartthings.com/oauth/token'),
        expiresAt: t0.add(const Duration(hours: 24)),
      ),
      MatterFabricCredential(
        driverId: 'matter',
        deviceId: 'dev-7',
        createdAt: t0,
        fabricId: '18446744073709551615',
        nodeId: '112233',
        rootCertificate: Uint8List.fromList([1, 1, 1]),
        intermediateCertificate: Uint8List.fromList([2, 2]),
        nodeOperationalCertificate: Uint8List.fromList([3]),
        operationalPrivateKey: Uint8List.fromList([4, 4, 4, 4]),
        ipk: Uint8List.fromList(List.filled(16, 9)),
      ),
    ];

    for (final credential in credentials) {
      test('round-trips ${credential.type}', () {
        final decoded = Credential.fromJson(wire(credential.toJson()));
        expect(decoded, credential);
        expect(decoded.hashCode, credential.hashCode);
        expect(decoded.runtimeType, credential.runtimeType);
      });
    }

    test('toString never reveals secrets', () {
      for (final credential in credentials) {
        final text = credential.toString();
        for (final secret in [
          'client-token',
          'refresh',
          'access',
          'secret',
          'PRIVATE',
          'pw',
          '0000',
        ]) {
          expect(text, isNot(contains(secret)));
        }
        expect(text, contains(credential.driverId));
      }
    });

    test('isExpired', () {
      final token = credentials.first;
      expect(token.isExpired(t0), isFalse);
      expect(token.isExpired(t0.add(const Duration(days: 30))), isTrue);
    });

    test('rejects an unknown type', () {
      expect(
        () => Credential.fromJson({
          'type': 'magic',
          'driverId': 'x',
          'deviceId': 'y',
          'createdAt': isoT0,
        }),
        throwsFormatException,
      );
    });
  });

  group('PairingStep', () {
    final credential = TokenCredential(
      driverId: 'firetv.lightning',
      deviceId: 'dev-1',
      createdAt: t0,
      token: 'secret-token',
    );
    final steps = <PairingStep>[
      Instruct(
        'Enable Control by mobile apps',
        helpUrl: Uri.parse('https://support.roku.com/'),
        requiresAck: true,
      ),
      const AcceptOnTv(Duration(seconds: 30), message: 'Allow on the TV'),
      const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits),
      OpenUrlFirst(Uri.parse('https://192.0.2.9:8002/'), 'Accept the cert'),
      NeedsUserMaterial(
        MaterialKind.clientCertificate,
        Uri.parse('https://example.invalid/help'),
      ),
      const EnterText('Login ID set on the TV'),
      const EnterText('Password', secret: true, minLength: 1, maxLength: 16),
      const ConfirmChange('Turn on network power-on?'),
      const ConfirmChange(
        'Turn on network power-on?',
        detail: 'Raises standby power.',
        yesLabel: 'Turn it on',
        noLabel: 'Not now',
      ),
      const PairingFailed(
        WatchmeError.rejected(
          'LG refused',
          rawDeviceMessage: '403 Pairing rejected: blacklisted certificate',
        ),
      ),
    ];

    for (final step in steps) {
      test('round-trips $step', () {
        expect(PairingStep.fromJson(wire(step.toJson())), step);
      });
    }

    test('Paired is redacted unless secrets are requested', () {
      final paired = Paired(credential);
      final redacted = paired.toJson();
      expect(jsonEncode(redacted), isNot(contains('secret-token')));
      expect(PairingStep.fromJson(wire(redacted)), const Paired.redacted());
      expect(
        PairingStep.fromJson(wire(paired.toJson(includeSecrets: true))),
        paired,
      );
    });

    test('awaitsInput and isTerminal', () {
      expect(steps[0].awaitsInput, isTrue);
      expect(const Instruct('note').awaitsInput, isFalse);
      expect(steps[1].awaitsInput, isFalse);
      expect(steps[2].awaitsInput, isTrue);
      expect(steps.last.isTerminal, isTrue);
      expect(Paired(credential).isTerminal, isTrue);
      expect(steps[2].isTerminal, isFalse);
    });

    test('EnterCode validates codes', () {
      const pin = EnterCode('PIN', 4, CodeAlphabet.digits);
      expect(pin.accepts('0123'), isTrue);
      expect(pin.accepts('012'), isFalse);
      expect(pin.accepts('01a3'), isFalse);
      const hex = EnterCode('Code', 6, CodeAlphabet.hex);
      expect(hex.accepts('A1b2C3'), isTrue);
      expect(hex.accepts('A1b2Cg'), isFalse);
    });

    test('EnterText validates length and refuses control characters', () {
      const login = EnterText('Login ID');
      expect(login.accepts(''), isTrue);
      expect(login.accepts('admin'), isTrue);
      expect(login.accepts('a' * 64), isTrue);
      expect(login.accepts('a' * 65), isFalse);
      expect(login.accepts('admin\r'), isFalse);
      expect(login.accepts('ad\nmin'), isFalse);
      expect(login.accepts('ad\x00min'), isFalse);
      expect(login.accepts('ad\x7fmin'), isFalse);
      const password = EnterText('Password', secret: true, minLength: 1);
      expect(password.accepts(''), isFalse);
      expect(password.accepts('pässwörd 1'), isTrue);
      expect(password.awaitsInput, isTrue);
    });

    test('a secret EnterText never carries a value', () {
      const password = EnterText('Password', secret: true);
      expect(password.toJson(), {
        'type': 'enterText',
        'label': 'Password',
        'secret': true,
      });
    });

    test('ConfirmChange awaits a yes or no', () {
      const ask = ConfirmChange('Turn on network power-on?');
      expect(ask.awaitsInput, isTrue);
      expect(ask.isTerminal, isFalse);
      expect(ConfirmChange.yes, 'yes');
      expect(ConfirmChange.no, 'no');
    });
  });

  group('DeviceState and events', () {
    final state = DeviceState(
      power: Observed.reported(PowerMode.standby, 'roku.ecp', t0),
      volume: Observed.inferred(17, 'roku.ecp', t0),
      muted: Observed(false, 'roku.ecp', t0, Confidence.stale),
      input: Observed.reported('hdmi1', 'roku.ecp', t0),
      foregroundApp: Observed.reported(
        const AppInfo(id: '12', name: 'Netflix'),
        'roku.ecp',
        t0,
      ),
      nowPlaying: Observed.reported(
        const NowPlaying(
          state: PlaybackState.playing,
          appId: '12',
          title: 'Show',
          position: Duration(seconds: 90),
          duration: Duration(minutes: 45),
        ),
        'roku.ecp',
        t0,
      ),
      connections: const {
        'roku.ecp': ConnectionState.connected,
        'wol': ConnectionState.disconnected,
      },
    );

    test('DeviceState round-trips', () {
      expect(DeviceState.fromJson(wire(state.toJson())), state);
      expect(
        DeviceState.fromJson(wire(DeviceState.empty.toJson())),
        DeviceState.empty,
      );
    });

    final events = <DeviceEvent>[
      StateChanged(state, driverId: 'roku.ecp'),
      const ConnectionChanged(
        ConnectionState.failed,
        driverId: 'firetv.lightning',
        error: WatchmeError.unreachable('Connection refused'),
      ),
      const ConnectionChanged(ConnectionState.connected, driverId: 'roku.ecp'),
      const CapabilitiesChanged([
        CapabilitySupport.no(Capability.dpadNavigation, note: 'Limited mode'),
      ], driverId: 'roku.ecp'),
      const ReauthRequired(
        WatchmeError.reauthRequired('Token revoked', rawDeviceMessage: '401'),
        driverId: 'firetv.lightning',
      ),
    ];

    for (final event in events) {
      test('round-trips $event', () {
        expect(DeviceEvent.fromJson(wire(event.toJson())), event);
      });
    }
  });

  test('DeviceView round-trips without secrets', () {
    final view = DeviceView(
      id: 'dev-1',
      name: 'Living Room TV',
      host: '192.0.2.10',
      manufacturer: 'TCL',
      model: '55S455',
      drivers: [
        const DriverView(
          driverId: 'roku.ecp',
          protocol: 'Roku ECP',
          connection: ConnectionState.connected,
          setup: [
            SetupStep(
              id: 'roku.controlByMobileApps',
              title: 'Control by mobile apps = Enabled',
            ),
          ],
          notes: ['Network access: Enabled'],
        ),
        const DriverView(
          driverId: 'firetv.lightning',
          protocol: 'Fire TV remote API',
          requiresPairing: true,
          lastError: WatchmeError.reauthRequired('Token revoked'),
        ),
        const DriverView(
          driverId: 'sharp.aquos',
          protocol: 'Sharp AQUOS IP control',
          offersPairing: true,
          paired: true,
        ),
      ],
      capabilities: const [
        CapabilitySupport.yes(Capability.dpadNavigation),
        CapabilitySupport.partial(
          Capability.volume,
          flags: {CapFlag.relativeOnly},
        ),
      ],
      state: DeviceState(
        power: Observed.reported(PowerMode.on, 'roku.ecp', t0),
      ),
      lastSeen: t0,
    );
    expect(DeviceView.fromJson(wire(view.toJson())), view);
    expect(view.needsPairing, isTrue);
    expect(view.connected, isTrue);
    expect(view.supportOf(Capability.volume).has(CapFlag.relativeOnly), isTrue);
    expect(view.supportOf(Capability.pointer).level, Support.unknown);
    expect([for (final d in view.drivers) d.canPair], [false, true, true]);
    expect(view.drivers.last.needsPairing, isFalse);
    expect(view.drivers.first.toJson(), isNot(contains('offersPairing')));
  });

  test('DeviceRecord round-trips', () {
    final record = DeviceRecord(
      id: 'dev-1',
      name: 'Bedroom',
      host: '192.0.2.10',
      manufacturer: 'Roku',
      model: '3930X',
      mac: 'aa:bb:cc:dd:ee:ff',
      otherMacs: const {'aa:bb:cc:dd:ee:00'},
      stableId: 'roku:serial:X00400ABCDEF',
      ports: const {'ecp': 8060},
      driverIds: const ['roku.ecp', 'wol'],
      lastSeen: t0,
    );
    expect(DeviceRecord.fromJson(wire(record.toJson())), record);
    expect(record.endpoint, const Endpoint('192.0.2.10', ports: {'ecp': 8060}));
    expect(record.allMacs, hasLength(2));
  });

  test('DriverDescriptor round-trips', () {
    const descriptor = DriverDescriptor(
      id: 'roku.ecp',
      vendor: 'Roku',
      protocol: 'Roku ECP',
      ceiling: [
        CapabilitySupport.yes(Capability.dpadNavigation),
        CapabilitySupport.partial(
          Capability.powerOn,
          flags: {CapFlag.needsNetworkStandby},
        ),
      ],
      backends: [
        DriverBackend(
          id: 'roku.ecp.http',
          requires: {TransportFeature.httpReadCrossOrigin},
          targets: {DriverTarget.webSafe, DriverTarget.native},
        ),
      ],
      stability: Stability.documented,
      provenance: 'clean-room from the Roku ECP documentation',
      matchers: [
        DiscoveryMatcher(
          provider: DiscoveryProviderId.ssdp,
          serviceType: 'roku:ecp',
          portName: 'ecp',
        ),
      ],
      userSetup: [
        SetupStep(
          id: 'roku.controlByMobileApps',
          title: 'Control by mobile apps = Enabled',
        ),
      ],
      ports: {'ecp': 8060},
    );
    expect(DriverDescriptor.fromJson(wire(descriptor.toJson())), descriptor);
    const optional = DriverDescriptor(
      id: 'sharp.aquos',
      vendor: 'Sharp',
      protocol: 'Sharp AQUOS IP control',
      ceiling: [],
      backends: [],
      stability: Stability.documented,
      provenance: 'test',
      offersPairing: true,
      powerQuietPeriod: Duration(seconds: 30),
    );
    expect(DriverDescriptor.fromJson(wire(optional.toJson())), optional);
    expect(optional.toJson(), containsPair('powerQuietPeriodMs', 30000));
    expect(optional, isNot(descriptor));
    expect(descriptor.toJson(), isNot(contains('offersPairing')));
    expect(
      descriptor
          .ceilingFor(Capability.powerOn)
          .has(CapFlag.needsNetworkStandby),
      isTrue,
    );
    expect(descriptor.ceilingFor(Capability.screenshot).level, Support.unknown);
  });

  test('DeviceInfo and Endpoint round-trip', () {
    const info = DeviceInfo(
      name: 'Kitchen',
      manufacturer: 'Amazon',
      model: 'AFTKA',
      mac: '11:22:33:44:55:66',
      stableId: 'uuid:abc',
      osVersion: 'Fire OS 8',
      extra: {'serial': 'G070'},
    );
    expect(DeviceInfo.fromJson(wire(info.toJson())), info);
    const ep = Endpoint(
      '127.0.0.1',
      ports: {'dial': 50001, 'remote': 50002},
      attributes: {DiscoveryAttr.manufacturer: 'Amazon'},
    );
    expect(Endpoint.fromJson(wire(ep.toJson())), ep);
  });
}

final isoT0 = t0.toIso8601String();
