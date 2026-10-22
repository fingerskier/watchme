import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';

import 'support/fixtures.dart';

void main() {
  group('RokuDeviceInfo', () {
    test('parses a Roku TV device-info', () {
      final info = RokuDeviceInfo.parse(tclTvDeviceInfo);
      expect(info.serialNumber, 'X01900ABCDEF');
      expect(info.vendorName, 'TCL');
      expect(info.modelName, '5-Series');
      expect(info.modelNumber, '7105X');
      expect(info.isTv, isTrue);
      expect(info.isStick, isFalse);
      expect(info.tunerType, 'ATSC');
      expect(info.displayName, "Mom & Dad's TV");
      expect(info.wifiMac, 'd8:31:34:aa:bb:cc');
      expect(info.ethernetMac, 'b0:a7:37:dd:ee:ff');
      expect(info.softwareVersion, '14.1.4');
      expect(info.powerModeRaw, 'PowerOn');
      expect(info.powerMode, PowerMode.on);
      expect(info.supportsFindRemote, isTrue);
      expect(info.supportsWakeOnWlan, isTrue);
      expect(info.supportsTvPowerControl, isNull);
      expect(info.ecpAccess, RokuEcpAccess.unknown);
      // Empty elements read as null; unknown elements are kept.
      expect(info['keyed-developer-id'], isNull);
      expect(info.fields['davinci-version'], '2.8.20');
    });

    test('maps a TV to DeviceInfo with the wired MAC first', () {
      final d = RokuDeviceInfo.parse(tclTvDeviceInfo).toDeviceInfo();
      expect(d.name, "Mom & Dad's TV");
      expect(d.manufacturer, 'TCL');
      expect(d.model, '5-Series');
      expect(d.mac, 'b0:a7:37:dd:ee:ff');
      expect(d.otherMacs, {'d8:31:34:aa:bb:cc'});
      expect(d.stableId, 'roku:serial:X01900ABCDEF');
      expect(d.osVersion, '14.1.4');
      expect(d.extra['is-tv'], 'true');
      expect(d.extra['model-number'], '7105X');
      expect(d.extra.containsKey('advertising-id'), isFalse);
      expect(d.extra.containsKey('keyed-developer-id'), isFalse);
    });

    test('parses a player and falls back for an empty user name', () {
      final info = RokuDeviceInfo.parse(expressPlayerDeviceInfo);
      expect(info.isTv, isFalse);
      expect(info.displayName, 'Bedroom Roku');
      expect(info.wifiMac, 'd8:31:34:12:34:56');
      expect(info.ethernetMac, isNull);
      expect(info.powerMode, PowerMode.screenOff);
      expect(info.supportsTvPowerControl, isTrue);
      expect(info.supportsAudioVolumeControl, isFalse);
      final d = info.toDeviceInfo();
      expect(d.mac, 'd8:31:34:12:34:56');
      expect(d.otherMacs, isEmpty);
      expect(d.manufacturer, 'Roku');
      expect(d.model, 'Roku Express 4K+');
    });

    test('reads ecp-setting-mode when present', () {
      String withMode(String mode) => tclTvDeviceInfo.replaceFirst(
        '<power-mode>',
        '<ecp-setting-mode>$mode</ecp-setting-mode>\n\t<power-mode>',
      );
      expect(
        RokuDeviceInfo.parse(withMode('limited')).ecpAccess,
        RokuEcpAccess.limited,
      );
      expect(
        RokuDeviceInfo.parse(withMode('enabled')).ecpAccess,
        RokuEcpAccess.enabled,
      );
      expect(
        RokuDeviceInfo.parse(withMode('permissive')).ecpAccess,
        RokuEcpAccess.enabled,
      );
      expect(
        RokuDeviceInfo.parse(withMode('disabled')).ecpAccess,
        RokuEcpAccess.disabled,
      );
    });

    test('rejects non-XML and the wrong root', () {
      expect(
        () => RokuDeviceInfo.parse('<html><body>hi</body></html>'),
        throwsFormatException,
      );
      expect(() => RokuDeviceInfo.parse('not xml'), throwsFormatException);
      expect(() => RokuDeviceInfo.parse(''), throwsFormatException);
    });

    test('equality is by fields', () {
      expect(
        RokuDeviceInfo.parse(tclTvDeviceInfo),
        RokuDeviceInfo.parse(tclTvDeviceInfo),
      );
      expect(
        RokuDeviceInfo.parse(tclTvDeviceInfo),
        isNot(RokuDeviceInfo.parse(tvDeviceInfoIn('Ready'))),
      );
    });
  });

  test('power-mode mapping', () {
    expect(rokuPowerMode('PowerOn'), PowerMode.on);
    expect(rokuPowerMode('DisplayOff'), PowerMode.screenOff);
    expect(rokuPowerMode('Headless'), PowerMode.screenOff);
    expect(rokuPowerMode('Ready'), PowerMode.standby);
    expect(rokuPowerMode('Suspend'), PowerMode.standby);
    expect(rokuPowerMode('Mystery'), PowerMode.unknown);
    expect(rokuPowerMode(null), PowerMode.unknown);
  });

  test('serial from SSDP USN', () {
    expect(rokuSerialFromUsn('uuid:roku:ecp:X01900ABCDEF'), 'X01900ABCDEF');
    expect(rokuSerialFromUsn('UUID:ROKU:ECP:abc::roku:ecp'), 'abc');
    expect(rokuSerialFromUsn('uuid:something-else'), isNull);
    expect(rokuSerialFromUsn(null), isNull);
  });

  group('parseRokuApps', () {
    test('maps types, entities and icons', () {
      final apps = parseRokuApps(
        appsXml,
        iconBase: Uri.parse('http://192.0.2.10:8060/'),
      );
      expect(apps, hasLength(7));
      expect(apps.first.id, 'tvinput.dtv');
      expect(apps.first.kind, AppKind.input);
      expect(apps[1].name, 'Xbox');
      final fandango = apps.firstWhere((a) => a.id == '31012');
      expect(fandango.name, 'FandangoNOW Movies & TV');
      expect(fandango.kind, AppKind.other);
      final netflix = apps.firstWhere((a) => a.id == '12');
      expect(netflix.kind, AppKind.app);
      expect(netflix.version, '5.2.98079401');
      expect(netflix.icon.toString(), 'http://192.0.2.10:8060/query/icon/12');
    });

    test('skips entries without an id and tolerates an empty list', () {
      expect(parseRokuApps('<apps><app>Broken</app></apps>'), isEmpty);
      expect(parseRokuApps('<apps/>'), isEmpty);
      expect(() => parseRokuApps('<player/>'), throwsFormatException);
    });
  });

  group('parseRokuActiveApp', () {
    test('home screen has no id', () {
      final app = parseRokuActiveApp(activeAppHome);
      expect(app.id, rokuHomeAppId);
      expect(app.name, 'Roku');
      expect(app.kind, AppKind.other);
    });

    test('an app, an input, and an app under a screensaver', () {
      expect(parseRokuActiveApp(activeAppNetflix).id, '12');
      final hdmi = parseRokuActiveApp(activeAppHdmi1);
      expect(hdmi.kind, AppKind.input);
      expect(hdmi.name, 'Xbox');
      expect(parseRokuActiveApp(activeAppWithScreensaver).id, '837');
    });
  });

  group('RokuMediaPlayer', () {
    test('parses a playing stream', () {
      final p = RokuMediaPlayer.parse(mediaPlayerIn('play'));
      expect(p.state, 'play');
      expect(p.playbackState, PlaybackState.playing);
      expect(p.pluginId, '12');
      expect(p.pluginName, 'Netflix');
      expect(p.position, const Duration(milliseconds: 754020));
      expect(p.duration, const Duration(milliseconds: 2580000));
      expect(p.isLive, isFalse);
      expect(
        p.toNowPlaying(),
        const NowPlaying(
          state: PlaybackState.playing,
          appId: '12',
          position: Duration(milliseconds: 754020),
          duration: Duration(milliseconds: 2580000),
        ),
      );
    });

    test('maps every state', () {
      PlaybackState of(String s) =>
          RokuMediaPlayer.parse(mediaPlayerIn(s)).playbackState;
      expect(of('pause'), PlaybackState.paused);
      expect(of('buffer'), PlaybackState.buffering);
      expect(of('startup'), PlaybackState.buffering);
      expect(of('stop'), PlaybackState.stopped);
      expect(of('none'), PlaybackState.stopped);
      expect(of('weird'), PlaybackState.unknown);
    });

    test('closed and live players', () {
      final closed = RokuMediaPlayer.parse(mediaPlayerClosed);
      expect(closed.playbackState, PlaybackState.stopped);
      expect(closed.pluginId, isNull);
      expect(closed.position, isNull);
      final live = RokuMediaPlayer.parse(mediaPlayerLive).toNowPlaying();
      expect(live.isLive, isTrue);
      expect(live.duration, isNull);
      expect(live.appId, 'tvinput.dtv');
    });
  });
}
