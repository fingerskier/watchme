# Third-party material in watchme

watchme is licensed under Apache-2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). This file lists the following:

- every outside source whose facts watchme's code relies on;
- what was taken from each source;
- every package dependency and its licence.

Rules:
- watchme ports code only from Apache-2.0, MIT or BSD sources.
- GPL, LGPL and AGPL code is reference-only.
- Dependencies must be Apache, MIT or BSD licensed.

So far no third-party code has been copied into watchme. The drivers and simulators are clean-room Dart written from protocol documentation and the references below. The one place where watchme follows another implementation's logic step by step is noted under "Followed logic".

## Protocol references

| Reference | Licence | URL | Used for | Where |
|---|---|---|---|---|
| Roku External Control Protocol documentation | Roku developer documentation (facts only) | https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md | Endpoints, key names, device-info and query formats | `watchme_driver_roku`, Roku simulator |
| python-rokuecp | MIT | https://github.com/ctalkington/python-rokuecp | Cross-check of response shapes; no code copied | `watchme_driver_roku`, Roku simulator XML |
| brs-desktop | MIT | https://github.com/lvcabral/brs-desktop | Cross-check of ECP and SSDP response shapes (incl. `ecp-setting-mode`); shapes of the SSDP test samples (made-up addresses and serials) | `watchme_driver_roku`, Roku simulator, `watchme_io` test samples |
| LibreControl/fire-tv | MIT | https://github.com/LibreControl/fire-tv | Fire TV endpoints, headers, PIN pairing and request bodies; discovery evidence (SSDP/DIAL only, no `_amzn-fireTv._tcp`); no code copied | `watchme_driver_firetv`, Fire TV simulator |
| hms-homelab/hms-firetv | MIT | https://github.com/hms-homelab/hms-firetv | Fire TV endpoints, `appsV2` field names, "a body-less POST is one key press"; no code copied | `watchme_driver_firetv`, Fire TV simulator |
| Netflix DIAL reference | BSD-2-Clause | https://github.com/Netflix/dial-reference | DIAL server behaviour; shape of the DIAL SSDP test sample | `watchme_io` test samples, Fire TV simulator DIAL server |
| DIAL protocol specification 2.x | Specification (facts only) | http://www.dial-multiscreen.org/dial-protocol-specification | `GET` of an application URL reports status without launching (the passive Fire TV probe) | `watchme_driver_firetv` |
| Home Assistant community: "REST commands for Fire TV" | Forum post (facts only) | https://community.home-assistant.io/t/rest-commands-for-fire-tv/901314 | Fire TV request shapes; the device error text `Bad arguments supplied. Please check inputs.` quoted by the simulator | Fire TV simulator |
| openHAB PR #17925, Home Assistant core issue #131969 | Field reports (facts only) | https://github.com/openhab/openhab-addons/pull/17925, https://github.com/home-assistant/core/issues/131969 | Roku "Limited mode" 403 body, and the rule that `Host` must be an IP literal | `watchme_driver_roku`, Roku simulator |
| raman325/vizaio | MIT | https://github.com/raman325/vizaio | VIZIO SmartCast endpoints, pairing bodies, key codes, HASHVAL read-modify-write, the `current_input` cname rule, app launch payloads, 7345/9000 port probing; no code copied | `watchme_driver_vizio`, VIZIO simulator |
| raman325/pyvizio | MIT | https://github.com/raman325/pyvizio | Cross-check of key codes (EXIT 9/0, CC 4/4), pairing flow and status words; no code copied | `watchme_driver_vizio`, VIZIO simulator |
| heathbar/vizio-smart-cast | MIT | https://github.com/heathbar/vizio-smart-cast | Cross-check of key codes and the display-name input selection of older firmware; no code copied | `watchme_driver_vizio`, VIZIO simulator |
| Home Assistant `vizio` integration | Apache-2.0 | https://github.com/home-assistant/core/tree/dev/homeassistant/components/vizio | Power and auth-error handling (a refused token is re-auth, never a power reading); no code copied | `watchme_driver_vizio` |
| exiva/Vizio_SmartCast_API | No licence (facts only) | https://github.com/exiva/Vizio_SmartCast_API | Endpoint and status-word facts, the firmware-to-port rule (before 4.0: 9000); nothing copied | `watchme_driver_vizio`, VIZIO simulator |
| vindeckyy/smartcast-backdoor | MIT (research write-up, facts only) | https://github.com/vindeckyy/smartcast-backdoor | Security posture only: the token is an unscoped bearer secret; the surfaces deliberately not implemented (the loopback twin on 7346, the WebSocket bus, the NAME_SPACE 4 / APP_ID 3001 raw-URL launcher); the `_viziocast._tcp` TXT keys | `watchme_driver_vizio` (what not to implement), VIZIO simulator TXT record |
| florianholzapfel/panasonic-viera | MIT | https://github.com/florianholzapfel/panasonic-viera | VIERA NRC SOAP envelopes, key names, app ids, the PAC inquiry format, the AES-128-CBC / HMAC-SHA-256 framing and key derivations; no code copied | `watchme_driver_panasonic`, Panasonic simulator |
| AntonioMeireles/homebridge-vieramatic | Apache-2.0 | https://github.com/AntonioMeireles/homebridge-vieramatic | Session re-open behaviour, the GENA `X_ScreenState` power model, Wake-on-LAN notes, PKCS#7 client padding; no code copied | `watchme_driver_panasonic`, Panasonic simulator |
| Home Assistant `panasonic_viera` integration | Apache-2.0 | https://github.com/home-assistant/core/tree/dev/homeassistant/components/panasonic_viera | Pairing flow (a new PIN after a wrong one), error handling, field reports (403 across subnets, captured request lengths); no code copied | `watchme_driver_panasonic`, Panasonic simulator |
| FastyBird miniserver, Viera connector | Apache-2.0 | https://github.com/FastyBird/miniserver | Device and service description and `X_AppList` content, response-HMAC handling, the SSDP search form; no code copied | `watchme_driver_panasonic`, Panasonic simulator documents |
| jens-maus/node-panasonic-viera | MIT | https://github.com/jens-maus/node-panasonic-viera | Additional key names; no code copied | `watchme_driver_panasonic` |
| FHEM `70_VIERA.pm`, UniversalMediaServer renderer profiles, gen1nya/panasonic-viera-control-js, mase1981/uc-intg-panasonicviera, rpeyron's blog post (2020-12-24), Crestron Panasonic Pro AV Control v1.1 help, Cocoontech thread 21266 | GPL-2.0, MPL-2.0, unlicensed, proprietary or forum posts (facts only) | https://github.com/mhop/fhem-mirror, https://github.com/UniversalMediaServer/UniversalMediaServer, https://github.com/gen1nya/panasonic-viera-control-js, https://github.com/mase1981/uc-intg-panasonicviera, https://rpeyron.github.io, https://applicationmarket.crestron.com/content/Help/Panasonic/Panasonic%20Pro%20AV%20Control%20v1.1%20Help.pdf, https://cocoontech.com/threads/panasonic-viera-plasma-ip-control.21266/ | Facts only: sequence-number tolerance, the 401 encryption check, the `X_GetAppInfo` form, Wake-on-LAN timing (ignored for about 30 s after off), polling limits, `-ON`/`-OFF` key holds | `watchme_driver_panasonic`, Panasonic simulator |
| Issue threads: panasonic-viera #2, #8, #9, #13, #21, #32, #43, #48, #60, #65; Home Assistant core #184837, #89280, #91199, #117735, #118604, #103366, #139159 and PR #181929; homebridge-vieramatic #8, #39, #42, #43, #44, #93, #97, #120, #131 | Field reports (facts only) | https://github.com/florianholzapfel/panasonic-viera/issues, https://github.com/home-assistant/core/issues, https://github.com/AntonioMeireles/homebridge-vieramatic/issues | Captured Content-Length values (301, 315, 324, 328, 379, 525, 561), the cross-subnet 403, sessions dropped after a power change, standby behaviour, model generations | `watchme_driver_panasonic`, Panasonic simulator |
| Sharp AQUOS operation manuals: US LC-40/46/52/60LE830U and LE835U (2010), LC-70/60/52LE640U, C6400U, LE633U (2011), LC-70/60LE847U, LE745U, LC-80LE844U (2012), the 2014 TV operation manual, the 4T-B series (2021); EU LC-40/46LE830E (2011), LC-60LE635E (2012), LC-70LE747E (2013); the JP LC-40W35 PC-control appendix | Vendor documentation (facts only) | http://files.sharpusa.com/Downloads/ForHome/HomeEntertainment/LCDTVs/Manuals/2014_TV_OM.pdf (the 2014 manual; the others are on Sharp's regional support sites) | IP-control framing, command tables (`POWR`, `RSPW`, `VOLM`, `MUTE`, `IAVD`/`ITVD`/`IDTV`, `RCKY` codes, channel and information commands), volume scales, network-standby settings and their standby-power wording | `watchme_driver_sharp`, Sharp simulator |
| Hixie/dart-home-automation-tools (`lib/src/devices/sharptv.dart`) | MIT | https://github.com/Hixie/dart-home-automation-tools | Login prompts and type-ahead, `POWR1` settling, `ERR` while booting, `IAVD`/`IDIN` `ERR` for the current input, 750 ms reconnect spacing; no code copied | `watchme_driver_sharp`, Sharp simulator |
| TanukiSharp/AquosRemoteControl | MIT | https://github.com/TanukiSharp/AquosRemoteControl | The unterminated `Login:`, the JP "CRLF then OK" login variant, the missing-CR firmware bug, a disabled login sending nothing; no code copied | `watchme_driver_sharp`, Sharp simulator |
| kechako/go-aquos | MIT | https://github.com/kechako/go-aquos | JP login handling and information commands (cross-check); no code copied | `watchme_driver_sharp` |
| cgarren/homebridge-sharp-aquos-tv-26 | Apache-2.0 | https://github.com/cgarren/homebridge-sharp-aquos-tv-26 | A successful login answers a bare CRLF (US LC-60LE632U); no code copied | `watchme_driver_sharp`, Sharp simulator |
| jmoore987/sharp_aquos_rc | MIT | https://github.com/jmoore987/sharp_aquos_rc | Command and key cross-check; no code copied | `watchme_driver_sharp` |
| Home Assistant `aquostv` integration | Apache-2.0 | https://github.com/home-assistant/core/tree/dev/homeassistant/components/aquostv | Behaviour reference (why the driver never writes RSPW on its own); no code copied | `watchme_driver_sharp` |
| golliher/go-proveSharpAPI ("report to sharp.md") | MIT | https://github.com/golliher/go-proveSharpAPI | The 2015 "ULI" firmware transcript (queries and absolute commands answer `ERR`; the login prompt is not enforced); `MNRD1`/`SWVN1` sample values | `watchme_driver_sharp`, Sharp simulator |
| benburkhart1/sharp-aquos-remote-control | Public-domain dedication (its package.json says MIT; facts only) | https://github.com/benburkhart1/sharp-aquos-remote-control | The login-failure text `User Name or Password mismatch` | `watchme_driver_sharp`, Sharp simulator |
| carlsapp/python-ssdp README (a Sharp SSDP capture) | LGPL-3.0 (reference only) | https://github.com/carlsapp/python-ssdp | The `AquosIPC` UPnP device type and the UUIDv1 UDN shape; facts only, no code | `watchme_driver_sharp` descriptor matcher, `watchme_io` SSDP search targets |
| Wireshark `manuf` | GPL data file (facts only) | https://www.wireshark.org/download/automated/data/manuf | The Sharp OUI list for the UDN MAC hint | `watchme_driver_sharp` |

## Followed logic

| Source | Licence | URL | What |
|---|---|---|---|
| Dart SDK, `WebSocket.connect` in `dart:io` | BSD-3-Clause | https://github.com/dart-lang/sdk | The checks in watchme_io's hand-written WebSocket client handshake (`Sec-WebSocket-Accept`, upgrade and subprotocol validation) follow the SDK's. The code was written for watchme. A comment in `packages/watchme_io/lib/src/network/io_network_stack.dart` notes the source. |

## Reference-only (copyleft, not used for code)

The following sources were read for reference only, and no code was taken from them.

| Source | Licence | Note |
|---|---|---|
| Dart `wake_on_lan` package | GPL-3.0 | watchme's magic packet (`magicPacket` in watchme_core, `WakeOnLan` in watchme_io) is written from the public packet format (6 x `0xFF` + 16 x MAC). |
| samsungtvws, ha-samsungtv-smart, libcec, webos-ssap-web (AGPL fork), bluetooth-tv-remote | LGPL/GPL/AGPL | Not used by M0 code. They are listed in the architecture overview so that future drivers stay clean-room. |
| FHEM `70_VIERA.pm` | GPL-2.0 | Read for Panasonic facts only (see Protocol references); no code taken. |
| carlsapp/python-ssdp | LGPL-3.0 | Its README's Sharp SSDP capture was read for the device type only; no code taken. |
| Wireshark `manuf` | GPL-2.0 | Read for Sharp's OUI prefixes only; no data file is shipped. |

## Test material written for watchme

- `packages/watchme_io/test/fixtures/tls/`: a test CA, server, self-signed and client certificates with their private keys, generated by `generate.sh` with OpenSSL. These keys are **public test fixtures** and protect nothing.
- `packages/watchme_testkit/lib/src/simulators/firetv/test_certificates.dart`: two self-signed certificates and keys for the Fire TV simulator, generated for watchme. They are also public test fixtures. The VIZIO simulator presents the same two certificates.
- The Panasonic driver's and simulator's crypto known-answer vectors were recomputed for watchme from the protocol description; the simulator's documents are synthetic, not captures of a TV.
- Simulator device identities (serials, MACs in the locally administered range, UUIDs) are made up.

## Toolchain

| Component | Licence | URL |
|---|---|---|
| Flutter SDK (framework, engine, `flutter_test`, `sky_engine`) | BSD-3-Clause, with third-party notices shipped in the SDK | https://github.com/flutter/flutter |
| Dart SDK | BSD-3-Clause | https://github.com/dart-lang/sdk |

## Package dependencies

These tables are generated from the root `pubspec.lock` (resolved on 2026-10-22). Each licence was read from the package's LICENSE file. Every dependency is Apache-2.0, BSD or MIT.

### In the app and libraries (runtime and native build hooks)

These are the hosted packages reachable from the app and the non-dev dependencies of `watchme_core`, `watchme_io`, `watchme_engine` and the drivers:

- `meta` (core);
- `crypto`, `multicast_dns`, `path` and `xml` (io);
- `xml` (Roku driver);
- `pointycastle` and `xml` (Panasonic driver: AES-CBC and HMAC-SHA-256 for encrypted VIERA sets, and its SOAP answers);
- `path_provider` (app);
- their transitive dependencies.

| Package | Version | Licence |
|---|---|---|
| [args](https://pub.dev/packages/args) | 2.7.0 | BSD-3-Clause |
| [characters](https://pub.dev/packages/characters) | 1.4.1 | BSD-3-Clause |
| [code_assets](https://pub.dev/packages/code_assets) | 2.1.0 | BSD-3-Clause |
| [collection](https://pub.dev/packages/collection) | 1.19.1 | BSD-3-Clause |
| [convert](https://pub.dev/packages/convert) | 3.1.2 | BSD-3-Clause |
| [crypto](https://pub.dev/packages/crypto) | 3.0.7 | BSD-3-Clause |
| [ffi](https://pub.dev/packages/ffi) | 2.2.0 | BSD-3-Clause |
| [hooks](https://pub.dev/packages/hooks) | 2.2.0 | BSD-3-Clause |
| [jni](https://pub.dev/packages/jni) | 1.1.0 | BSD-3-Clause |
| [jni_flutter](https://pub.dev/packages/jni_flutter) | 1.0.4+1 | BSD-3-Clause |
| [jni_util](https://pub.dev/packages/jni_util) | 1.0.0 | BSD-3-Clause |
| [logging](https://pub.dev/packages/logging) | 1.3.0 | BSD-3-Clause |
| [material_color_utilities](https://pub.dev/packages/material_color_utilities) | 0.13.0 | Apache-2.0 |
| [meta](https://pub.dev/packages/meta) | 1.19.0 | BSD-3-Clause |
| [multicast_dns](https://pub.dev/packages/multicast_dns) | 0.3.3+1 | BSD-3-Clause |
| [objective_c](https://pub.dev/packages/objective_c) | 9.6.2 | BSD-3-Clause |
| [package_config](https://pub.dev/packages/package_config) | 2.2.0 | BSD-3-Clause |
| [path](https://pub.dev/packages/path) | 1.9.1 | BSD-3-Clause |
| [path_provider](https://pub.dev/packages/path_provider) | 2.1.6 | BSD-3-Clause |
| [path_provider_android](https://pub.dev/packages/path_provider_android) | 2.3.1 | BSD-3-Clause |
| [path_provider_foundation](https://pub.dev/packages/path_provider_foundation) | 2.6.0 | BSD-3-Clause |
| [path_provider_linux](https://pub.dev/packages/path_provider_linux) | 2.2.2 | BSD-3-Clause |
| [path_provider_platform_interface](https://pub.dev/packages/path_provider_platform_interface) | 2.1.3 | BSD-3-Clause |
| [path_provider_windows](https://pub.dev/packages/path_provider_windows) | 2.3.0 | BSD-3-Clause |
| [petitparser](https://pub.dev/packages/petitparser) | 7.1.0 | MIT |
| [platform](https://pub.dev/packages/platform) | 3.2.0 | BSD-3-Clause |
| [plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface) | 2.1.8 | BSD-3-Clause |
| [pointycastle](https://pub.dev/packages/pointycastle) | 4.0.0 | MIT (copyright The Legion of the Bouncy Castle Inc.) |
| [pub_semver](https://pub.dev/packages/pub_semver) | 2.2.1 | BSD-3-Clause |
| [record_use](https://pub.dev/packages/record_use) | 1.1.1 | BSD-3-Clause |
| [source_span](https://pub.dev/packages/source_span) | 1.10.2 | BSD-3-Clause |
| [string_scanner](https://pub.dev/packages/string_scanner) | 1.4.1 | BSD-3-Clause |
| [term_glyph](https://pub.dev/packages/term_glyph) | 1.2.2 | BSD-3-Clause |
| [typed_data](https://pub.dev/packages/typed_data) | 1.4.0 | BSD-3-Clause |
| [vector_math](https://pub.dev/packages/vector_math) | 2.4.3 | BSD-3-Clause |
| [xdg_directories](https://pub.dev/packages/xdg_directories) | 1.1.0 | BSD-3-Clause |
| [xml](https://pub.dev/packages/xml) | 7.1.0 | MIT |
| [yaml](https://pub.dev/packages/yaml) | 3.1.4 | MIT |

### Development and test only

These packages are used by tests, analysis, the simulators (`watchme_testkit`, which also uses `crypto`, `pointycastle` and `xml` from the table above) and tools. None of them ship in the app.

| Package | Version | Licence |
|---|---|---|
| [_fe_analyzer_shared](https://pub.dev/packages/_fe_analyzer_shared) | 103.0.0 | BSD-3-Clause |
| [analyzer](https://pub.dev/packages/analyzer) | 13.3.0 | BSD-3-Clause |
| [async](https://pub.dev/packages/async) | 2.13.1 | BSD-3-Clause |
| [boolean_selector](https://pub.dev/packages/boolean_selector) | 2.1.2 | BSD-3-Clause |
| [cli_config](https://pub.dev/packages/cli_config) | 0.2.0 | BSD-3-Clause |
| [cli_util](https://pub.dev/packages/cli_util) | 0.6.0 | BSD-3-Clause |
| [clock](https://pub.dev/packages/clock) | 1.1.3 | Apache-2.0 |
| [coverage](https://pub.dev/packages/coverage) | 1.16.0 | BSD-3-Clause |
| [fake_async](https://pub.dev/packages/fake_async) | 1.3.3 | Apache-2.0 |
| [file](https://pub.dev/packages/file) | 7.0.1 | BSD-3-Clause |
| [flutter_lints](https://pub.dev/packages/flutter_lints) | 6.0.0 | BSD-3-Clause |
| [frontend_server_client](https://pub.dev/packages/frontend_server_client) | 4.2.0 | BSD-3-Clause |
| [glob](https://pub.dev/packages/glob) | 2.2.0 | BSD-3-Clause |
| [http_multi_server](https://pub.dev/packages/http_multi_server) | 3.2.3 | BSD-3-Clause |
| [http_parser](https://pub.dev/packages/http_parser) | 4.1.2 | BSD-3-Clause |
| [io](https://pub.dev/packages/io) | 1.1.0 | BSD-3-Clause |
| [leak_tracker](https://pub.dev/packages/leak_tracker) | 11.0.2 | BSD-3-Clause |
| [leak_tracker_flutter_testing](https://pub.dev/packages/leak_tracker_flutter_testing) | 3.0.10 | BSD-3-Clause |
| [leak_tracker_testing](https://pub.dev/packages/leak_tracker_testing) | 3.0.2 | BSD-3-Clause |
| [lints](https://pub.dev/packages/lints) | 6.1.0 | BSD-3-Clause |
| [matcher](https://pub.dev/packages/matcher) | 0.12.20 | BSD-3-Clause |
| [mime](https://pub.dev/packages/mime) | 2.1.0 | BSD-3-Clause |
| [node_preamble](https://pub.dev/packages/node_preamble) | 2.0.2 | BSD-3-Clause |
| [pool](https://pub.dev/packages/pool) | 1.5.3 | BSD-3-Clause |
| [shelf](https://pub.dev/packages/shelf) | 1.4.3 | BSD-3-Clause |
| [shelf_packages_handler](https://pub.dev/packages/shelf_packages_handler) | 3.0.2 | BSD-3-Clause |
| [shelf_static](https://pub.dev/packages/shelf_static) | 1.2.0 | BSD-3-Clause |
| [shelf_web_socket](https://pub.dev/packages/shelf_web_socket) | 3.0.0 | BSD-3-Clause |
| [source_map_stack_trace](https://pub.dev/packages/source_map_stack_trace) | 2.1.2 | BSD-3-Clause |
| [source_maps](https://pub.dev/packages/source_maps) | 0.10.14 | BSD-3-Clause |
| [stack_trace](https://pub.dev/packages/stack_trace) | 1.12.2 | BSD-3-Clause |
| [stream_channel](https://pub.dev/packages/stream_channel) | 2.1.4 | BSD-3-Clause |
| [test](https://pub.dev/packages/test) | 1.31.1 | BSD-3-Clause |
| [test_api](https://pub.dev/packages/test_api) | 0.7.12 | BSD-3-Clause |
| [test_core](https://pub.dev/packages/test_core) | 0.6.18 | BSD-3-Clause |
| [vm_service](https://pub.dev/packages/vm_service) | 15.4.0 | BSD-3-Clause |
| [watcher](https://pub.dev/packages/watcher) | 1.2.1 | BSD-3-Clause |
| [web](https://pub.dev/packages/web) | 1.1.1 | BSD-3-Clause |
| [web_socket](https://pub.dev/packages/web_socket) | 1.0.1 | BSD-3-Clause |
| [web_socket_channel](https://pub.dev/packages/web_socket_channel) | 3.0.3 | BSD-3-Clause |
| [webkit_inspection_protocol](https://pub.dev/packages/webkit_inspection_protocol) | 1.2.1 | BSD-3-Clause |
