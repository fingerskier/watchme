// Internal deep-equality helpers so watchme_core needs no package:collection.

/// Element-wise list equality.
bool listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Set equality.
bool setEquals<T>(Set<T>? a, Set<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  return a.containsAll(b);
}

/// Map equality (values compared with `==`).
bool mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (!b.containsKey(key) || b[key] != value) return false;
  }
  return true;
}

/// Order-sensitive hash of a list's elements.
int listHash(List<Object?>? list) =>
    list == null ? null.hashCode : Object.hashAll(list);

/// Order-insensitive hash of a set's elements.
int setHash(Set<Object?>? set) =>
    set == null ? null.hashCode : Object.hashAllUnordered(set);

/// Order-insensitive hash of a map's entries.
int mapHash(Map<Object?, Object?>? map) => map == null
    ? null.hashCode
    : Object.hashAllUnordered([
        for (final MapEntry(:key, :value) in map.entries)
          Object.hash(key, value),
      ]);
