import 'package:watchme_core/watchme_core.dart';

import 'capabilities.dart';
import 'constants.dart';

/// The UPnP device type a Sharp TV advertises for its IP-control service
/// (one SSDP capture, rebuilt from the capturing tool's short form). It
/// identifies a Sharp TV; the control port is still [SharpPorts.ipc].
const String sharpAquosIpcDeviceType =
    'urn:schemas-sharp-co-jp:device:AquosIPC:1';

/// Static facts about the Sharp AQUOS IP-control driver.
const DriverDescriptor sharpDescriptor = DriverDescriptor(
  id: sharpDriverId,
  vendor: 'Sharp',
  protocol: 'Sharp AQUOS IP control',
  stability: Stability.documented,
  provenance:
      "Clean-room Dart implementation from Sharp's AQUOS operation manuals "
      '(the IP-control command tables of the US 2010, 2011, 2012 and 2014 '
      'manuals, the US 4T-B manual, the EU 2011-2013 manuals and the JP '
      'LC-40W35 appendix). Login, timing and firmware quirks were checked '
      'against Hixie/dart-home-automation-tools (MIT), '
      'TanukiSharp/AquosRemoteControl (MIT), kechako/go-aquos (MIT), '
      'cgarren/homebridge-sharp-aquos-tv-26 (Apache-2.0), '
      'jmoore987/sharp_aquos_rc (MIT), the Home Assistant aquostv '
      'integration (Apache-2.0), golliher/go-proveSharpAPI (MIT, the 2015 '
      'firmware transcript) and benburkhart1/sharp-aquos-remote-control '
      '(the login-failure text). No code was copied.',
  ports: {SharpPorts.ipc: SharpPorts.ipcDefault},
  // Pairing is required only where the TV enforces a login (the probe
  // says so), but every Sharp TV can be paired: to store a login the TV
  // asks for without enforcing it, and to allow power-on over the network.
  offersPairing: true,
  backends: [
    DriverBackend(
      id: 'sharp.aquos.tcp',
      requires: {TransportFeature.rawTcp},
      targets: {DriverTarget.native},
    ),
  ],
  matchers: [
    // No portName: the SSDP description is served on 12346, which is not
    // the control port.
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: sharpAquosIpcDeviceType,
    ),
  ],
  userSetup: [
    SetupStep(
      id: 'sharp.ipControl',
      title: 'AQUOS Remote Control / IP Control = Enable',
      detail:
          'US 2010-2011: Menu > Initial Setup > Internet Setup > Network '
          'Setup > IP Control Setup. US 2012-2013: Menu > Initial Setup > '
          'Internet Setup > AQUOS Remote Control. US 2014: Menu > Smart TV > '
          'AQUOS Remote Control > Remote Control App. 4T-B: Network Settings '
          '> IP Control. EU 2011-2012: Menu > Setup > View setting > Network '
          'setup > IP Control setup; EU 2013: HOME > IP Control. Keep the '
          'control port at 10002 or give watchme the one you chose.',
    ),
    SetupStep(
      id: 'sharp.login',
      title: 'Recommended: set a login ID and password',
      detail:
          'IP control has no encryption and no login by default, so anyone '
          'on the network can switch the TV off or change its settings. Set '
          'a login ID and password in the same menu (Detailed Settings); '
          'watchme asks for them when pairing.',
    ),
    SetupStep(
      id: 'sharp.networkPowerOn',
      title: 'Optional: allow power-on over the network',
      detail:
          'From standby the TV answers only while it keeps IP control '
          'listening. US 2010-2014 sets need the power-on command setting '
          '(RSPW), which watchme offers to set while pairing; Sharp warns '
          'that standby power consumption then becomes "just about the same '
          'as usual" and the front Center Icon Illumination stays lit. US '
          '2014, 4T-B and JP sets also need Quick Start Mode = On (it '
          'consumes more power in standby). EU 2011-2013 sets cannot be '
          'turned on over IP.',
    ),
  ],
  ceiling: sharpCeiling,
);
