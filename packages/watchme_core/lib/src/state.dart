import 'package:meta/meta.dart';

import 'commands.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// The TV's power mode as watchme believes it.
enum PowerMode {
  /// Fully on with the picture showing.
  on,

  /// On with the panel dark (Roku `DisplayOff`, LG screen off).
  screenOff,

  /// Samsung Frame Art Mode.
  artMode,

  /// Network standby: the TV answers some requests (Roku `Ready`).
  standby,

  /// Off or deep sleep: nothing answers.
  off,

  /// Not known.
  unknown,
}

/// How much to trust an [Observed] value.
///
/// Earlier values are more trustworthy.
enum Confidence {
  /// The device said so.
  reported,

  /// Derived from indirect evidence (a command we sent, a timeout).
  inferred,

  /// Once reported or inferred, but the source has since gone quiet.
  stale,
}

/// A value with its provenance: who said it, when, and how sure we are.
@immutable
final class Observed<T> {
  /// Creates an observation.
  const Observed(this.value, this.source, this.at, this.confidence);

  /// Creates a [Confidence.reported] observation.
  const Observed.reported(this.value, this.source, this.at)
    : confidence = Confidence.reported;

  /// Creates a [Confidence.inferred] observation.
  const Observed.inferred(this.value, this.source, this.at)
    : confidence = Confidence.inferred;

  /// Decodes the form written by [toJson], decoding `value` with [decode].
  factory Observed.fromJson(JsonMap json, T Function(Object? raw) decode) =>
      Observed(
        decode(json['value']),
        req<String>(json, 'source'),
        reqTime(json, 'at'),
        reqEnum(json, 'confidence', Confidence.values),
      );

  /// The observed value.
  final T value;

  /// Who reported it, usually a driver id such as `roku.ecp`.
  final String source;

  /// When it was observed.
  final DateTime at;

  /// How much to trust it.
  final Confidence confidence;

  /// Returns a copy with [Confidence.stale].
  Observed<T> asStale() => Observed(value, source, at, Confidence.stale);

  /// Whether this observation should replace [other] in a merge: newer wins;
  /// at the same instant the better confidence wins; a full tie prefers this.
  bool supersedes(Observed<T>? other) {
    if (other == null) return true;
    if (at.isAfter(other.at)) return true;
    if (at.isBefore(other.at)) return false;
    return confidence.index <= other.confidence.index;
  }

  /// JSON form, encoding `value` with [encode].
  JsonMap toJson(Object? Function(T value) encode) => {
    'value': encode(value),
    'source': source,
    'at': isoTime(at),
    'confidence': confidence.name,
  };

  @override
  bool operator ==(Object other) =>
      other is Observed<T> &&
      other.value == value &&
      other.source == source &&
      other.at.isAtSameMomentAs(at) &&
      other.confidence == confidence;

  @override
  int get hashCode =>
      Object.hash(value, source, at.microsecondsSinceEpoch, confidence);

  @override
  String toString() =>
      'Observed($value from $source at ${isoTime(at)}, ${confidence.name})';
}

/// Playback state in [NowPlaying].
enum PlaybackState {
  /// Playing.
  playing,

  /// Paused.
  paused,

  /// Buffering or loading.
  buffering,

  /// Stopped or idle.
  stopped,

  /// Not known.
  unknown,
}

/// What the TV is playing.
@immutable
final class NowPlaying {
  /// Creates a now-playing snapshot.
  const NowPlaying({
    this.state = PlaybackState.unknown,
    this.appId,
    this.title,
    this.subtitle,
    this.position,
    this.duration,
    this.isLive = false,
  });

  /// Decodes the form written by [toJson].
  factory NowPlaying.fromJson(JsonMap json) => NowPlaying(
    state:
        optEnum(json, 'state', PlaybackState.values) ?? PlaybackState.unknown,
    appId: opt<String>(json, 'appId'),
    title: opt<String>(json, 'title'),
    subtitle: opt<String>(json, 'subtitle'),
    position: optMs(json, 'positionMs'),
    duration: optMs(json, 'durationMs'),
    isLive: opt<bool>(json, 'isLive') ?? false,
  );

  /// Playback state.
  final PlaybackState state;

  /// The app playing, if known.
  final String? appId;

  /// Title, if known.
  final String? title;

  /// Secondary text (episode, artist), if known.
  final String? subtitle;

  /// Position at the observation time.
  final Duration? position;

  /// Total length, if finite and known.
  final Duration? duration;

  /// Live content (no fixed duration).
  final bool isLive;

  /// JSON form.
  JsonMap toJson() => {
    'state': state.name,
    if (appId != null) 'appId': appId,
    if (title != null) 'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (position != null) 'positionMs': position!.inMilliseconds,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (isLive) 'isLive': true,
  };

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.state == state &&
      other.appId == appId &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.position == position &&
      other.duration == duration &&
      other.isLive == isLive;

  @override
  int get hashCode =>
      Object.hash(state, appId, title, subtitle, position, duration, isLive);

  @override
  String toString() => 'NowPlaying(${state.name}, $appId, $title)';
}

/// The state of one driver session's link to the device.
///
/// Note: Flutter's widgets library also exports a `ConnectionState`. Flutter
/// code that needs this one should hide Flutter's
/// (`import 'package:flutter/material.dart' hide ConnectionState;`) or import
/// watchme_core with a prefix.
enum ConnectionState {
  /// Not connected.
  disconnected,

  /// Connecting (including a wake such as Fire TV's DIAL POST).
  connecting,

  /// Connected and usable.
  connected,

  /// The last attempt failed; see the accompanying error.
  failed,
}

/// Everything watchme believes about one device's state.
///
/// Every field is an [Observed] so the UI can show provenance and staleness,
/// and the power orchestrator can tell reported state from guesses.
/// Instances are immutable; use [copyWith] and [merge].
@immutable
final class DeviceState {
  /// Creates a state snapshot. All fields are optional.
  const DeviceState({
    this.power,
    this.volume,
    this.muted,
    this.input,
    this.foregroundApp,
    this.nowPlaying,
    this.connections = const {},
  });

  /// A state with nothing known.
  static const DeviceState empty = DeviceState();

  /// Decodes the form written by [toJson].
  factory DeviceState.fromJson(JsonMap json) {
    Observed<T>? read<T>(String key, T Function(Object? raw) decode) =>
        switch (optMap(json, key)) {
          null => null,
          final m => Observed<T>.fromJson(m, decode),
        };
    final connections = optMap(json, 'connections') ?? const {};
    return DeviceState(
      power: read(
        'power',
        (raw) => enumByName(PowerMode.values, raw, 'power.value'),
      ),
      volume: read('volume', (raw) => _asInt(raw, 'volume.value')),
      muted: read('muted', (raw) => _as<bool>(raw, 'muted.value')),
      input: read('input', (raw) => _as<String>(raw, 'input.value')),
      foregroundApp: read(
        'foregroundApp',
        (raw) => AppInfo.fromJson(_asMap(raw, 'foregroundApp.value')),
      ),
      nowPlaying: read(
        'nowPlaying',
        (raw) => NowPlaying.fromJson(_asMap(raw, 'nowPlaying.value')),
      ),
      connections: {
        for (final key in connections.keys)
          key: enumByName(ConnectionState.values, connections[key], key),
      },
    );
  }

  /// Power mode.
  final Observed<PowerMode>? power;

  /// Absolute volume 0..100, when the device reports one.
  final Observed<int>? volume;

  /// Mute state.
  final Observed<bool>? muted;

  /// Current input id (driver-specific, e.g. `hdmi1`).
  final Observed<String>? input;

  /// The app in the foreground.
  final Observed<AppInfo>? foregroundApp;

  /// What is playing.
  final Observed<NowPlaying>? nowPlaying;

  /// Connection state per driver session, keyed by driver id.
  final Map<String, ConnectionState> connections;

  /// Whether nothing is known.
  bool get isEmpty =>
      power == null &&
      volume == null &&
      muted == null &&
      input == null &&
      foregroundApp == null &&
      nowPlaying == null &&
      connections.isEmpty;

  /// Returns a copy with the given fields replaced.
  ///
  /// `null` arguments keep the current value; this method cannot clear a
  /// field. Downgrade instead with [markStale], which keeps the history the
  /// power rules depend on.
  DeviceState copyWith({
    Observed<PowerMode>? power,
    Observed<int>? volume,
    Observed<bool>? muted,
    Observed<String>? input,
    Observed<AppInfo>? foregroundApp,
    Observed<NowPlaying>? nowPlaying,
    Map<String, ConnectionState>? connections,
  }) => DeviceState(
    power: power ?? this.power,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    input: input ?? this.input,
    foregroundApp: foregroundApp ?? this.foregroundApp,
    nowPlaying: nowPlaying ?? this.nowPlaying,
    connections: connections ?? this.connections,
  );

  /// Merges [other] into this state, field by field.
  ///
  /// For each observed field the observation that [Observed.supersedes] the
  /// other wins: the newer one, or at the same instant the more confident
  /// one, or on a full tie [other]'s. Fields absent from [other] are kept.
  /// [connections] are combined with [other]'s entries winning.
  DeviceState merge(DeviceState other) {
    Observed<T>? pick<T>(Observed<T>? mine, Observed<T>? theirs) =>
        theirs != null && theirs.supersedes(mine) ? theirs : mine;
    return DeviceState(
      power: pick(power, other.power),
      volume: pick(volume, other.volume),
      muted: pick(muted, other.muted),
      input: pick(input, other.input),
      foregroundApp: pick(foregroundApp, other.foregroundApp),
      nowPlaying: pick(nowPlaying, other.nowPlaying),
      connections: {...connections, ...other.connections},
    );
  }

  /// The fields of this state that differ from [previous], for emitting a
  /// `StateChanged` diff. Connections that differ or are new are included.
  DeviceState changesSince(DeviceState previous) {
    Observed<T>? diff<T>(Observed<T>? now, Observed<T>? before) =>
        now == before ? null : now;
    return DeviceState(
      power: diff(power, previous.power),
      volume: diff(volume, previous.volume),
      muted: diff(muted, previous.muted),
      input: diff(input, previous.input),
      foregroundApp: diff(foregroundApp, previous.foregroundApp),
      nowPlaying: diff(nowPlaying, previous.nowPlaying),
      connections: {
        for (final MapEntry(:key, :value) in connections.entries)
          if (previous.connections[key] != value) key: value,
      },
    );
  }

  /// Returns a copy whose observations are all [Confidence.stale], e.g. after
  /// the device stops answering.
  DeviceState markStale() => DeviceState(
    power: power?.asStale(),
    volume: volume?.asStale(),
    muted: muted?.asStale(),
    input: input?.asStale(),
    foregroundApp: foregroundApp?.asStale(),
    nowPlaying: nowPlaying?.asStale(),
    connections: connections,
  );

  /// JSON form. Absent fields are omitted.
  JsonMap toJson() => {
    if (power != null) 'power': power!.toJson((v) => v.name),
    if (volume != null) 'volume': volume!.toJson((v) => v),
    if (muted != null) 'muted': muted!.toJson((v) => v),
    if (input != null) 'input': input!.toJson((v) => v),
    if (foregroundApp != null)
      'foregroundApp': foregroundApp!.toJson((v) => v.toJson()),
    if (nowPlaying != null) 'nowPlaying': nowPlaying!.toJson((v) => v.toJson()),
    if (connections.isNotEmpty)
      'connections': {
        for (final MapEntry(:key, :value) in connections.entries)
          key: value.name,
      },
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceState &&
      other.power == power &&
      other.volume == volume &&
      other.muted == muted &&
      other.input == input &&
      other.foregroundApp == foregroundApp &&
      other.nowPlaying == nowPlaying &&
      mapEquals(other.connections, connections);

  @override
  int get hashCode => Object.hash(
    power,
    volume,
    muted,
    input,
    foregroundApp,
    nowPlaying,
    mapHash(connections),
  );

  @override
  String toString() => 'DeviceState(${toJson()})';
}

T _as<T>(Object? raw, String key) =>
    raw is T ? raw : throw FormatException('Expected $T for "$key": $raw');

int _asInt(Object? raw, String key) => switch (raw) {
  int v => v,
  double v when v == v.truncateToDouble() => v.toInt(),
  _ => throw FormatException('Expected int for "$key": $raw'),
};

JsonMap _asMap(Object? raw, String key) => raw is Map
    ? raw.cast<String, Object?>()
    : throw FormatException('Expected object for "$key": $raw');
