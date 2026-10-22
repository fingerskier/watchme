// Internal helpers for reading JSON maps under strict-casts. Not exported.

import 'dart:convert';
import 'dart:typed_data';

/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

Never _bad(String key, Object? value, String expected) => throw FormatException(
  'Expected $expected for "$key", got ${value.runtimeType}: $value',
);

/// Reads a required value of type [T].
T req<T extends Object>(JsonMap json, String key) {
  final value = json[key];
  if (value is T) return value;
  _bad(key, value, '$T');
}

/// Reads an optional value of type [T]; absent and `null` both give `null`.
T? opt<T extends Object>(JsonMap json, String key) {
  final value = json[key];
  if (value == null || value is T) return value as T?;
  _bad(key, value, '$T?');
}

/// Reads a required integer, accepting integral doubles (JSON from JS).
int reqInt(JsonMap json, String key) =>
    optInt(json, key) ?? _bad(key, json[key], 'int');

/// Reads an optional integer, accepting integral doubles (JSON from JS).
int? optInt(JsonMap json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble()) {
    return value.toInt();
  }
  _bad(key, value, 'int');
}

/// Reads a required nested object.
JsonMap reqMap(JsonMap json, String key) =>
    optMap(json, key) ?? _bad(key, json[key], 'object');

/// Reads an optional nested object.
JsonMap? optMap(JsonMap json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is Map) return value.cast<String, Object?>();
  _bad(key, value, 'object');
}

/// Reads an optional list (absent gives an empty list).
List<Object?> list(JsonMap json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is List) return value;
  _bad(key, value, 'list');
}

/// Reads an optional list of objects, decoding each with [decode].
List<T> objList<T>(JsonMap json, String key, T Function(JsonMap) decode) => [
  for (final item in list(json, key))
    if (item is Map)
      decode(item.cast<String, Object?>())
    else
      _bad(key, item, 'list of objects'),
];

/// Reads an optional list of strings.
List<String> strList(JsonMap json, String key) => [
  for (final item in list(json, key))
    if (item is String) item else _bad(key, item, 'list of strings'),
];

/// Reads an optional `{String: String}` map.
Map<String, String> strMap(JsonMap json, String key) {
  final raw = optMap(json, key);
  if (raw == null) return const {};
  return {
    for (final MapEntry(:key, :value) in raw.entries)
      key: value is String ? value : _bad(key, value, 'string'),
  };
}

/// Reads an optional `{String: int}` map.
Map<String, int> intMap(JsonMap json, String key) {
  final raw = optMap(json, key);
  if (raw == null) return const {};
  return {for (final k in raw.keys) k: reqInt(raw, k)};
}

/// Looks up an enum value by its [Enum.name].
E enumByName<E extends Enum>(List<E> values, Object? name, String key) {
  if (name is String) {
    for (final value in values) {
      if (value.name == name) return value;
    }
  }
  throw FormatException('Unknown value for "$key": $name');
}

/// Reads a required enum value stored by name.
E reqEnum<E extends Enum>(JsonMap json, String key, List<E> values) =>
    enumByName(values, json[key], key);

/// Reads an optional enum value stored by name.
E? optEnum<E extends Enum>(JsonMap json, String key, List<E> values) =>
    json[key] == null ? null : enumByName(values, json[key], key);

/// Reads a set of enum values stored as a list of names.
Set<E> enumSet<E extends Enum>(JsonMap json, String key, List<E> values) => {
  for (final name in list(json, key)) enumByName(values, name, key),
};

/// Encodes a set of enum values as a sorted list of names.
List<String> enumNames(Iterable<Enum> values) =>
    [for (final v in values) v.name]..sort();

/// Reads a required ISO-8601 timestamp.
DateTime reqTime(JsonMap json, String key) =>
    optTime(json, key) ?? _bad(key, json[key], 'ISO-8601 timestamp');

/// Reads an optional ISO-8601 timestamp.
DateTime? optTime(JsonMap json, String key) {
  final raw = opt<String>(json, key);
  if (raw == null) return null;
  return DateTime.tryParse(raw) ?? _bad(key, raw, 'ISO-8601 timestamp');
}

/// Encodes a timestamp as UTC ISO-8601.
String isoTime(DateTime value) => value.toUtc().toIso8601String();

/// Reads an optional duration stored as integer milliseconds.
Duration? optMs(JsonMap json, String key) {
  final ms = optInt(json, key);
  return ms == null ? null : Duration(milliseconds: ms);
}

/// Reads a required duration stored as integer milliseconds.
Duration reqMs(JsonMap json, String key) =>
    Duration(milliseconds: reqInt(json, key));

/// Reads an optional URI.
Uri? optUri(JsonMap json, String key) {
  final raw = opt<String>(json, key);
  if (raw == null) return null;
  return Uri.tryParse(raw) ?? _bad(key, raw, 'URI');
}

/// Reads a required URI.
Uri reqUri(JsonMap json, String key) =>
    optUri(json, key) ?? _bad(key, json[key], 'URI');

/// Reads optional base64 bytes.
Uint8List? optBytes(JsonMap json, String key) {
  final raw = opt<String>(json, key);
  if (raw == null) return null;
  try {
    return base64.decode(raw);
  } on FormatException {
    _bad(key, raw, 'base64');
  }
}

/// Reads required base64 bytes.
Uint8List reqBytes(JsonMap json, String key) =>
    optBytes(json, key) ?? _bad(key, json[key], 'base64');

/// Encodes bytes as base64.
String base64Of(List<int> value) => base64.encode(value);

/// Checks the `type` discriminator of a sealed-hierarchy object.
String typeOf(JsonMap json) => req<String>(json, 'type');
