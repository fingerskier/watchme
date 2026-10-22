import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

// Response bodies shaped like real Roku firmware output (TCL Roku TV on
// Roku OS 14.1.4, Roku Express 4K+ on 15.0). Identifiers are made up.

const String tclTvDeviceInfo = '''
<?xml version="1.0" encoding="UTF-8" ?>
<device-info>
	<udn>28001240-0000-1000-8000-b0a737c0ffee</udn>
	<virtual-device-id>S0A36ABCD123</virtual-device-id>
	<serial-number>X01900ABCDEF</serial-number>
	<device-id>S0A36ABCD123</device-id>
	<advertising-id>a6a7e6b1-0000-5d8e-9bb4-000000000000</advertising-id>
	<vendor-name>TCL</vendor-name>
	<model-name>5-Series</model-name>
	<model-number>7105X</model-number>
	<model-region>US</model-region>
	<is-tv>true</is-tv>
	<is-stick>false</is-stick>
	<screen-size>55</screen-size>
	<panel-id>10</panel-id>
	<mobile-has-live-tv>true</mobile-has-live-tv>
	<ui-resolution>1080p</ui-resolution>
	<tuner-type>ATSC</tuner-type>
	<supports-ethernet>true</supports-ethernet>
	<wifi-mac>D8:31:34:AA:BB:CC</wifi-mac>
	<wifi-driver>realtek</wifi-driver>
	<has-wifi-extender>false</has-wifi-extender>
	<has-wifi-5G-support>true</has-wifi-5G-support>
	<can-use-wifi-extender>true</can-use-wifi-extender>
	<ethernet-mac>b0:a7:37:dd:ee:ff</ethernet-mac>
	<network-type>ethernet</network-type>
	<friendly-device-name>Mom &amp; Dad&apos;s TV</friendly-device-name>
	<friendly-model-name>TCL•Roku TV</friendly-model-name>
	<default-device-name>TCL•Roku TV - X01900ABCDEF</default-device-name>
	<user-device-name>Mom &amp; Dad&apos;s TV</user-device-name>
	<user-device-location>Living room</user-device-location>
	<build-number>CHD.50E04174A</build-number>
	<software-version>14.1.4</software-version>
	<software-build>6000</software-build>
	<lightning-base-build-number>14.10.6000</lightning-base-build-number>
	<secure-device>true</secure-device>
	<language>en</language>
	<country>US</country>
	<locale>en_US</locale>
	<time-zone-auto>true</time-zone-auto>
	<time-zone>US/Central</time-zone>
	<time-zone-name>United States/Central</time-zone-name>
	<time-zone-tz>America/Chicago</time-zone-tz>
	<time-zone-offset>-300</time-zone-offset>
	<clock-format>12-hour</clock-format>
	<uptime>1186353</uptime>
	<power-mode>PowerOn</power-mode>
	<supports-suspend>true</supports-suspend>
	<supports-find-remote>true</supports-find-remote>
	<find-remote-is-possible>false</find-remote-is-possible>
	<supports-audio-guide>true</supports-audio-guide>
	<supports-rva>true</supports-rva>
	<has-hands-free-voice-remote>false</has-hands-free-voice-remote>
	<developer-enabled>false</developer-enabled>
	<keyed-developer-id/>
	<search-enabled>true</search-enabled>
	<search-channels-enabled>true</search-channels-enabled>
	<voice-search-enabled>true</voice-search-enabled>
	<notifications-enabled>true</notifications-enabled>
	<notifications-first-use>false</notifications-first-use>
	<supports-private-listening>true</supports-private-listening>
	<supports-private-listening-dtv>true</supports-private-listening-dtv>
	<supports-warm-standby>true</supports-warm-standby>
	<headphones-connected>false</headphones-connected>
	<supports-audio-settings>false</supports-audio-settings>
	<expert-pq-enabled>1.0</expert-pq-enabled>
	<supports-ecs-textedit>true</supports-ecs-textedit>
	<supports-ecs-microphone>true</supports-ecs-microphone>
	<supports-wake-on-wlan>true</supports-wake-on-wlan>
	<supports-airplay>true</supports-airplay>
	<has-play-on-roku>true</has-play-on-roku>
	<has-mobile-screensaver>true</has-mobile-screensaver>
	<support-url>roku.com/support</support-url>
	<grandcentral-version>11.4.22</grandcentral-version>
	<trc-version>3.0</trc-version>
	<trc-channel-version>9.2.0</trc-channel-version>
	<davinci-version>2.8.20</davinci-version>
	<av-sync-calibration-enabled>3.0</av-sync-calibration-enabled>
</device-info>
''';

const String expressPlayerDeviceInfo = '''
<?xml version="1.0" encoding="UTF-8" ?>
<device-info>
	<udn>29600011-1c0d-1041-80e4-d83134123456</udn>
	<serial-number>YH00AB123456</serial-number>
	<device-id>S0B41AB12345</device-id>
	<vendor-name>Roku</vendor-name>
	<model-name>Roku Express 4K+</model-name>
	<model-number>3941X</model-number>
	<model-region>US</model-region>
	<is-tv>false</is-tv>
	<is-stick>false</is-stick>
	<ui-resolution>1080p</ui-resolution>
	<supports-ethernet>false</supports-ethernet>
	<wifi-mac>d8-31-34-12-34-56</wifi-mac>
	<wifi-driver>realtek</wifi-driver>
	<network-type>wifi</network-type>
	<network-name>HomeNet</network-name>
	<friendly-device-name>Bedroom Roku</friendly-device-name>
	<friendly-model-name>Roku Express 4K+</friendly-model-name>
	<default-device-name>Roku Express 4K+ - YH00AB123456</default-device-name>
	<user-device-name></user-device-name>
	<user-device-location>Bedroom</user-device-location>
	<build-number>D3B.00E04170A</build-number>
	<software-version>15.0.4</software-version>
	<software-build>4170</software-build>
	<secure-device>true</secure-device>
	<power-mode>DisplayOff</power-mode>
	<supports-suspend>false</supports-suspend>
	<supports-find-remote>false</supports-find-remote>
	<developer-enabled>false</developer-enabled>
	<keyed-developer-id/>
	<supports-wake-on-wlan>false</supports-wake-on-wlan>
	<supports-tv-power-control>true</supports-tv-power-control>
	<supports-audio-volume-control>false</supports-audio-volume-control>
</device-info>
''';

/// [tclTvDeviceInfo] with another power mode.
String tvDeviceInfoIn(String powerMode) =>
    tclTvDeviceInfo.replaceFirst('PowerOn', powerMode);

const String appsXml = '''
<?xml version="1.0" encoding="UTF-8" ?>
<apps>
	<app id="tvinput.dtv" type="tvin" version="1.0.0">Live TV</app>
	<app id="tvinput.hdmi1" type="tvin" version="1.0.0">Xbox</app>
	<app id="tvinput.hdmi2" type="tvin" version="1.0.0">HDMI 2</app>
	<app id="31012" type="menu" version="1.9.37">FandangoNOW Movies &amp; TV</app>
	<app id="12" type="appl" version="5.2.98079401">Netflix</app>
	<app id="837" type="appl" version="2.21.100005034">YouTube</app>
	<app id="782875" type="appl" version="2.3.1">Media Assistant</app>
</apps>
''';

const String activeAppHome = '''
<?xml version="1.0" encoding="UTF-8" ?>
<active-app>
	<app>Roku</app>
</active-app>
''';

const String activeAppNetflix = '''
<?xml version="1.0" encoding="UTF-8" ?>
<active-app>
	<app id="12" type="appl" version="5.2.98079401">Netflix</app>
</active-app>
''';

const String activeAppHdmi1 = '''
<?xml version="1.0" encoding="UTF-8" ?>
<active-app>
	<app id="tvinput.hdmi1" type="tvin" version="1.0.0">Xbox</app>
</active-app>
''';

const String activeAppWithScreensaver = '''
<?xml version="1.0" encoding="UTF-8" ?>
<active-app>
	<app id="837" type="appl" version="2.21.100005034">YouTube</app>
	<screensaver id="55545" type="ssvr" version="2.0.1">Default screensaver</screensaver>
</active-app>
''';

String mediaPlayerIn(String state) =>
    '''
<?xml version="1.0" encoding="UTF-8" ?>
<player error="false" state="$state">
	<plugin bandwidth="19807640 bps" id="12" name="Netflix"/>
	<format audio="eac3" captions="none" container="mp4" drm="widevine" video="hevc_b" video_res="3840x2160"/>
	<buffering current="1000" max="1000" target="0"/>
	<new_stream speed="128000 bps"/>
	<position>754020 ms</position>
	<duration>2580000 ms</duration>
	<is_live blocked="false">false</is_live>
	<runtime>2580000 ms</runtime>
	<stream_segment bitrate="15600000" media_sequence="377" segment_type="mux" time="752000"/>
</player>
''';

const String mediaPlayerClosed = '''
<?xml version="1.0" encoding="UTF-8" ?>
<player error="false" state="close"/>
''';

const String mediaPlayerLive = '''
<?xml version="1.0" encoding="UTF-8" ?>
<player error="false" state="play">
	<plugin bandwidth="8000000 bps" id="tvinput.dtv" name="Live TV"/>
	<position>3600 ms</position>
	<duration>0 ms</duration>
	<is_live blocked="false">true</is_live>
</player>
''';

const String limitedBody = 'ECP command not allowed in Limited mode.';

/// A scripted Roku on a [FakeNetworkStack]: device-info, active-app,
/// media-player, apps, keys and launch, with a switchable Limited mode.
final class FakeRoku {
  FakeRoku({
    FakeTransports? transports,
    this.host = '192.0.2.10',
    this.port = 8060,
    this.deviceInfo = tclTvDeviceInfo,
  }) : transports = transports ?? FakeTransports() {
    _install();
  }

  final FakeTransports transports;
  final String host;
  final int port;

  String deviceInfo;
  String activeApp = activeAppNetflix;
  String mediaPlayer = mediaPlayerIn('play');
  String apps = appsXml;

  /// Answer gated requests with the Limited-mode 403.
  bool limited = false;

  FakeNetworkStack get net => transports.net;

  Endpoint get endpoint =>
      Endpoint(host, ports: port == 8060 ? const {} : {'ecp': port});

  /// `METHOD /path?query` of every request so far.
  List<String> get log => [
    for (final c in net.httpCalls)
      '${c.method} ${c.uri.path}${c.uri.hasQuery ? '?${c.uri.query}' : ''}',
  ];

  /// Paths of every POST so far.
  List<String> get posts => [
    for (final c in net.httpCalls)
      if (c.method == 'POST')
        '${c.uri.path}${c.uri.hasQuery ? '?${c.uri.query}' : ''}',
  ];

  /// A position in the request log, for [postsSince].
  int mark() => net.httpCalls.length;

  /// Paths of the POSTs made after [mark].
  List<String> postsSince(int mark) => [
    for (final c in net.httpCalls.skip(mark))
      if (c.method == 'POST')
        '${c.uri.path}${c.uri.hasQuery ? '?${c.uri.query}' : ''}',
  ];

  static HttpResult xml(String body) =>
      HttpResult.text(200, body, contentType: 'text/xml; charset="utf-8"');

  HttpResult _gated(HttpResult Function() ok) =>
      limited ? HttpResult.text(403, limitedBody) : ok();

  void _install() {
    void on(String method, Pattern path, FakeHttpHandler handler) =>
        net.onHttp(method, path, handler, host: host, port: port);
    on('GET', '/query/device-info', (_) => xml(deviceInfo));
    on('GET', '/query/active-app', (_) => xml(activeApp));
    on('GET', '/query/media-player', (_) => _gated(() => xml(mediaPlayer)));
    on('GET', '/query/apps', (_) => _gated(() => xml(apps)));
    on(
      'POST',
      RegExp(r'^/key(press|down|up)/'),
      (_) => _gated(() => HttpResult(200)),
    );
    on('POST', RegExp(r'^/launch/'), (_) => HttpResult(200));
  }
}
