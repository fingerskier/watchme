/// Validation for the "Add by IP address" field.
library;

final RegExp _digitsAndDots = RegExp(r'^[0-9.]+$');
final RegExp _octet = RegExp(r'^[0-9]{1,3}$');
final RegExp _hostLabel = RegExp(
  r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
);
final RegExp _hostWithPort = RegExp(r'^[^:\[\]]+:[0-9]+$');
final RegExp _bracketedWithPort = RegExp(r'^\[.*\]:[0-9]+$');

/// Returns an error message for [input], or null when it is an IPv4
/// address, an IPv6 address (bracketed or not) or a host name.
///
/// Ports are rejected on purpose: a TV speaks several protocols on
/// different ports, and the engine picks each one.
String? validateHostInput(String? input) {
  final value = input?.trim() ?? '';
  if (value.isEmpty) return "Enter the TV's IP address.";
  if (value.contains('://') || value.contains('/')) {
    return 'Enter just the address, without http:// or a path.';
  }
  if (value.contains(RegExp(r'\s'))) return 'Addresses cannot contain spaces.';
  if (_hostWithPort.hasMatch(value) || _bracketedWithPort.hasMatch(value)) {
    return 'Leave out the port; watchme chooses it for each protocol.';
  }
  final bare = _unbracket(value);
  if (bare.contains(':')) {
    return _isIPv6(bare) ? null : 'That is not a valid IPv6 address.';
  }
  if (_digitsAndDots.hasMatch(bare)) {
    return _parseIPv4(bare) != null
        ? null
        : 'That is not a valid IPv4 address. Use four numbers from 0 to 255, '
              'like 192.168.1.20.';
  }
  if (_isHostName(bare)) return null;
  return 'Enter an IP address like 192.168.1.20, or a host name.';
}

/// The host to hand to the engine for a valid [input]: trimmed, IPv6
/// brackets removed, IPv4 octets without leading zeros, and a host name's
/// trailing dot dropped.
String normalizeHostInput(String input) {
  final bare = _unbracket(input.trim());
  if (_digitsAndDots.hasMatch(bare)) {
    final octets = _parseIPv4(bare);
    if (octets != null) return octets.join('.');
  }
  if (!bare.contains(':') && bare.endsWith('.')) {
    return bare.substring(0, bare.length - 1);
  }
  return bare;
}

String _unbracket(String value) =>
    value.length > 2 && value.startsWith('[') && value.endsWith(']')
    ? value.substring(1, value.length - 1)
    : value;

List<int>? _parseIPv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (!_octet.hasMatch(part)) return null;
    final n = int.parse(part);
    if (n > 255) return null;
    octets.add(n);
  }
  return octets;
}

bool _isIPv6(String value) {
  try {
    Uri.parseIPv6Address(value);
    return true;
  } on FormatException {
    return false;
  }
}

bool _isHostName(String value) {
  final name = value.endsWith('.')
      ? value.substring(0, value.length - 1)
      : value;
  if (name.isEmpty || name.length > 253) return false;
  return name.split('.').every(_hostLabel.hasMatch);
}
