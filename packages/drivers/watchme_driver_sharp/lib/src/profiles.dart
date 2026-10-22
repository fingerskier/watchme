// Model profiles from the Sharp manuals' command tables (US 2010: LE830U
// family; US 2011 and 2012; US 2014; US 4T-B 2021; EU 2011, 2012 and 2013;
// JP LC-40W35) and the 2015 "ULI" firmware transcript of
// golliher/go-proveSharpAPI. Facts only.

/// Which family of the IP-control command set a TV speaks.
enum SharpRegion {
  /// The US tables (US 2010-2015 and 4T-B).
  us,

  /// The EU tables: different input numbering, no `POWR1`, `IPPY`.
  eu,

  /// The JP tables: JP channels and inputs.
  jp,
}

/// How a profile tunes channels.
enum SharpChannels {
  /// US direct tuning (`DCCH`, `DA2P`, `DC2U`/`DC2L`, `DC10`/`DC11`) and
  /// `CHUP`/`CHDW`.
  us,

  /// EU digital tuning (`DTVD`) and `CHUP`/`CHDW`.
  eu,

  /// `CHUP`/`CHDW` only.
  upDown,

  /// The CH up/down remote keys only (`RCKY34`/`RCKY35`).
  keys,
}

/// One input a profile can switch to.
typedef SharpInputCommand = ({String command, String parameter, int? iavd});

/// A model generation and the part of the command set it speaks.
///
/// The driver picks one from the model the TV reports (`MNRD1`), the UPnP
/// model name, or the endpoint attribute `sharp.profile`; see
/// [sharpProfileForModel]. Anything unknown gets [us2011] with the volume
/// scale assumed to be 0-60.
enum SharpProfile {
  /// US 2010 (LE830U family, also LE835U): `VOLM` 0-60, `IAVD` 1-7, no
  /// remote keys (`RCKY`).
  us2010(
    id: 'us2010',
    label: 'US 2010 (LE830U family)',
    region: SharpRegion.us,
    volumeMax: 60,
    rcky: {},
    inputs: _usInputs7,
    rspw: true,
    channels: SharpChannels.us,
  ),

  /// US 2011-2013 (LE640U, C6400U, LE633U, LE732U, LE745U, LE847U, ...):
  /// `VOLM` 0-60, `IAVD` 1-8, `RCKY` 0-59. Also the default for an
  /// unknown model.
  us2011(
    id: 'us2011',
    label: 'US 2011-2013',
    region: SharpRegion.us,
    volumeMax: 60,
    rcky: _rcky2011,
    inputs: _usInputs8,
    rspw: true,
    channels: SharpChannels.us,
  ),

  /// US 2014 (UQ17U, TQ15U, SQ15U, EQ10U, LE657U, C6500U, UD27U, ...):
  /// `VOLM` 0-100, `IAVD` 1-8, `RCKY` 0-61. Power-on over IP also needs
  /// Quick Start Mode.
  us2014(
    id: 'us2014',
    label: 'US 2014',
    region: SharpRegion.us,
    volumeMax: 100,
    rcky: _rcky2014,
    inputs: _usInputs8,
    rspw: true,
    quickStart: true,
    channels: SharpChannels.us,
  ),

  /// US 2015 "ULI" firmware (LE653U, LE654U, UB30U, ...): every query and
  /// most absolute commands answer `ERR`; power, the mute toggle and
  /// remote keys work.
  us2015Limited(
    id: 'us2015limited',
    label: 'US 2015 (write-only firmware)',
    region: SharpRegion.us,
    volumeMax: 100,
    rcky: _rcky2014,
    inputs: {},
    queries: false,
    absoluteVolume: false,
    discreteMute: false,
    channels: SharpChannels.keys,
  ),

  /// US 4T-B commercial series (2021): `VOLM` 0-100, `IAVD` 0-5 (0 = TV),
  /// a reduced `RCKY` set, blank parameters for argument-less commands.
  us4tb(
    id: 'us4tb',
    label: 'US 4T-B (2021)',
    region: SharpRegion.us,
    volumeMax: 100,
    rcky: _rcky4tb,
    inputs: _inputs4tb,
    quickStart: true,
    blankArguments: true,
    channels: SharpChannels.us,
  ),

  /// EU 2011-2013 (LE830E, LE635E, LE747E, ...): no `POWR1` or `RSPW`, EU
  /// inputs, `IPPY`, no remote keys. `VOLM` is 0-60 on 2011-2012 sets and
  /// 0-100 on 2013 sets.
  eu(
    id: 'eu',
    label: 'EU 2011-2013',
    region: SharpRegion.eu,
    volumeMax: 60,
    rcky: {},
    inputs: _euInputs,
    powerOn: false,
    blankArguments: true,
    channels: SharpChannels.eu,
    versionCommand: 'IPPY',
  ),

  /// JP sets: `VOLM` 0-100, inputs 1-6, JP channel commands (only
  /// `CHUP`/`CHDW` are used). The JP manuals list only `POWR0`; field
  /// reports show `POWR1` working with Quick Start.
  jp(
    id: 'jp',
    label: 'Japan',
    region: SharpRegion.jp,
    volumeMax: 100,
    rcky: {},
    inputs: _jpInputs,
    quickStart: true,
    channels: SharpChannels.upDown,
  );

  const SharpProfile({
    required this.id,
    required this.label,
    required this.region,
    required this.volumeMax,
    required this.rcky,
    required this.inputs,
    required this.channels,
    this.queries = true,
    this.absoluteVolume = true,
    this.discreteMute = true,
    this.powerOn = true,
    this.rspw = false,
    this.quickStart = false,
    this.blankArguments = false,
    this.versionCommand = 'IPPV',
  });

  /// Stable id, as the `sharp.profile` endpoint attribute takes it.
  final String id;

  /// Human name.
  final String label;

  /// Which command-set family it speaks.
  final SharpRegion region;

  /// The top of the `VOLM` scale its manual gives (60 or 100).
  final int volumeMax;

  /// The `RCKY` codes its manual lists (empty: no remote keys).
  final Set<int> rcky;

  /// The inputs it can switch to, by watchme input id.
  final Map<String, SharpInputCommand> inputs;

  /// How it tunes channels.
  final SharpChannels channels;

  /// Whether queries (`POWR?`, `VOLM?`, ...) answer.
  final bool queries;

  /// Whether `VOLMn` sets the volume.
  final bool absoluteVolume;

  /// Whether `MUTE1`/`MUTE2` work (otherwise only the `MUTE0` toggle).
  final bool discreteMute;

  /// Whether `POWR1` is a power-on route at all.
  final bool powerOn;

  /// Whether its manual lists `RSPW`, the setting that keeps IP control
  /// listening in standby.
  final bool rspw;

  /// Whether power-on over IP needs Quick Start Mode on the TV.
  final bool quickStart;

  /// Whether argument-less commands (`ITGD`, `CHUP`, `CHDW`, `ACHA`) take
  /// four blanks instead of `0` and three blanks.
  final bool blankArguments;

  /// The protocol-version command: `IPPV` (US, JP) or `IPPY` (EU).
  final String versionCommand;

  /// The parameter of an argument-less command such as `CHUP`.
  String get noArgument => blankArguments ? '' : '0';

  /// The input id `IAVD?` answer [iavd] stands for, or `null`.
  String? inputForIavd(int iavd) {
    for (final MapEntry(:key, :value) in inputs.entries) {
      if (value.iavd == iavd) return key;
    }
    return null;
  }

  /// The profile with [id], or `null`.
  static SharpProfile? byId(String? id) {
    final want = id?.trim().toLowerCase();
    for (final p in values) {
      if (p.id == want) return p;
    }
    return null;
  }
}

/// What [sharpProfileForModel] decided: the profile, whether the model's
/// volume scale is known for sure, and the top of the `VOLM` scale to use
/// (the model's when it is certain, otherwise 60, the quiet side).
typedef SharpModelMatch = ({
  SharpProfile profile,
  bool volumeCertain,
  int volumeMax,
});

/// A match for [profile]; [volumeMax] overrides the profile's scale for a
/// model whose manual gives another (the EU 2013 sets).
SharpModelMatch _match(
  SharpProfile profile, {
  required bool certain,
  int? volumeMax,
}) => (
  profile: profile,
  volumeCertain: certain,
  volumeMax: certain ? volumeMax ?? profile.volumeMax : 60,
);

/// Picks the profile for [model]: the reply to `MNRD1` (which leaves out
/// the size and `LC-`, e.g. `C6400UA` for an LC-70C6400U) or a full model
/// number. `null` when the model says nothing the driver knows.
///
/// [SharpModelMatch.volumeCertain] is false where the scale is in doubt
/// (US 2013 sets were reported at 0-60 although their siblings are 0-100;
/// anything matched by region alone), and the session then assumes 0-60
/// until the TV reads above 60. The EU profile covers both EU scales: 0-60
/// for the 2011-2012 series and 0-100 for the 2013 series (LE747E).
SharpModelMatch? sharpProfileForModel(String? model) {
  if (model == null) return null;
  final m = model.trim().toUpperCase().replaceAll(RegExp(r'\s'), '');
  if (m.isEmpty) return null;
  if (m.startsWith('4T-B')) {
    return _match(SharpProfile.us4tb, certain: true);
  }
  if (RegExp(r'^4T-C\d{2}[A-Z]{2}\d$').hasMatch(m) ||
      RegExp(r'^LC-\d{2}[A-Z]{1,3}\d{1,2}$').hasMatch(m)) {
    return _match(SharpProfile.jp, certain: true);
  }
  final series = m
      .replaceFirst(RegExp(r'^LC-?'), '')
      .replaceFirst(RegExp(r'^\d{2,3}(?=[A-Z])'), '');
  bool any(List<String> list) => list.any(series.startsWith);
  if (any(_us2010Series)) {
    return _match(SharpProfile.us2010, certain: true);
  }
  if (any(_us2015Series)) {
    return _match(SharpProfile.us2015Limited, certain: false);
  }
  if (any(_us2014Uncertain)) {
    return _match(SharpProfile.us2014, certain: false);
  }
  if (any(_us2014Series)) {
    return _match(SharpProfile.us2014, certain: true);
  }
  if (any(_us2011Series)) {
    return _match(SharpProfile.us2011, certain: true);
  }
  if (any(_us2013Series)) {
    return _match(SharpProfile.us2011, certain: false);
  }
  if (any(_eu2013Series)) {
    return _match(SharpProfile.eu, certain: true, volumeMax: 100);
  }
  if (any(_eu2011Series)) {
    return _match(SharpProfile.eu, certain: true);
  }
  final region = RegExp(r'^[A-Z]{1,3}\d{2,5}([A-Z])').firstMatch(series);
  return switch (region?.group(1)) {
    'E' || 'K' => _match(SharpProfile.eu, certain: false),
    // US, and Asia/Oceania sets (X, M), which field reports call US-like.
    'U' || 'X' || 'M' => _match(SharpProfile.us2011, certain: false),
    _ => null,
  };
}

/// The volume scale of a 2013 EU set (LC-70LE747E, the EU 2013 manual).
const List<String> _eu2013Series = ['LE747E'];
const List<String> _eu2011Series = ['LE830E', 'LE831E', 'LE635E', 'LE636E'];

/// US 2010 (LE830U manual); LE835U has the same table. LE831U and LE832U
/// look like siblings (unverified).
const List<String> _us2010Series = ['LE830U', 'LE831U', 'LE832U', 'LE835U'];

/// US 2011-2012 manuals.
const List<String> _us2011Series = [
  'LE640U', 'C6400U', 'LE633U', 'LE632U', 'LE732U', 'LE734U', //
  'LE745U', 'LE847U', 'LE844U',
];

/// US 2013 sets (no manual table at hand; field reports say 0-60).
const List<String> _us2013Series = ['LE652U', 'LE755U', 'LE857U', 'LE960U'];

/// US 2014 manual (and LC-70UD27U).
const List<String> _us2014Series = [
  'UQ17U', 'TQ15U', 'SQ15U', 'SQ17U', 'SQ10U', 'EQ10U', 'LE657U', //
  'C6500U', 'LE642U', 'UD27U',
];

/// In the 2014 manual, but a user reported 0-60 on an LE650U.
const List<String> _us2014Uncertain = ['LE650U'];

/// US 2015 "ULI" firmware.
const List<String> _us2015Series = [
  'LE653U', 'LE654U', 'UB30U', 'UE30U', 'UH30U', //
];

const Set<int> _rcky2011 = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, //
  20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39,
  40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
  58, 59,
};

const Set<int> _rcky2014 = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, //
  20, 21, 23, 24, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39,
  40, 41, 42, 43, 44, 45, 46, 47, 49, 50, 51, 52, 53, 54, 55, 56, 57,
  58, 59, 60, 61,
};

const Set<int> _rcky4tb = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 23, 24, 31, 32, 33, 34, 35, //
  36, 38, 39, 40, 41, 42, 43, 44, 45, 46, 49, 50, 51, 52, 53, 61,
};

const Map<String, SharpInputCommand> _usInputs7 = {
  'tv': (command: 'ITVD', parameter: '0', iavd: null),
  'hdmi1': (command: 'IAVD', parameter: '1', iavd: 1),
  'hdmi2': (command: 'IAVD', parameter: '2', iavd: 2),
  'hdmi3': (command: 'IAVD', parameter: '3', iavd: 3),
  'hdmi4': (command: 'IAVD', parameter: '4', iavd: 4),
  'component': (command: 'IAVD', parameter: '5', iavd: 5),
  'av1': (command: 'IAVD', parameter: '6', iavd: 6),
  'av2': (command: 'IAVD', parameter: '7', iavd: 7),
};

const Map<String, SharpInputCommand> _usInputs8 = {
  ..._usInputs7,
  'pc': (command: 'IAVD', parameter: '8', iavd: 8),
};

const Map<String, SharpInputCommand> _inputs4tb = {
  'tv': (command: 'ITVD', parameter: '0', iavd: 0),
  'hdmi1': (command: 'IAVD', parameter: '1', iavd: 1),
  'hdmi2': (command: 'IAVD', parameter: '2', iavd: 2),
  'av1': (command: 'IAVD', parameter: '3', iavd: 3),
  'usb': (command: 'IAVD', parameter: '4', iavd: 4),
  'homeNetwork': (command: 'IAVD', parameter: '5', iavd: 5),
};

const Map<String, SharpInputCommand> _euInputs = {
  'tv': (command: 'ITVD', parameter: '', iavd: null),
  'dtv': (command: 'IDTV', parameter: '', iavd: null),
  'ext1': (command: 'IAVD', parameter: '1', iavd: 1),
  'ext2': (command: 'IAVD', parameter: '2', iavd: 2),
  'ext3': (command: 'IAVD', parameter: '3', iavd: 3),
  'hdmi1': (command: 'IAVD', parameter: '4', iavd: 4),
  'hdmi2': (command: 'IAVD', parameter: '5', iavd: 5),
  'hdmi3': (command: 'IAVD', parameter: '6', iavd: 6),
  'hdmi4': (command: 'IAVD', parameter: '7', iavd: 7),
  'pc': (command: 'IAVD', parameter: '8', iavd: 8),
};

const Map<String, SharpInputCommand> _jpInputs = {
  'input1': (command: 'IAVD', parameter: '1', iavd: 1),
  'input2': (command: 'IAVD', parameter: '2', iavd: 2),
  'input3': (command: 'IAVD', parameter: '3', iavd: 3),
  'input4': (command: 'IAVD', parameter: '4', iavd: 4),
  'input5': (command: 'IAVD', parameter: '5', iavd: 5),
  'input6': (command: 'IAVD', parameter: '6', iavd: 6),
};
