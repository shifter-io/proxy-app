import 'dart:convert';

/// Dart's decoder accepts duplicate object keys. Reject them, including escaped
/// equivalents, before decoding security-sensitive metadata. Also bound nesting.
dynamic strictJson(String input) {
  var at = 0;
  void space() {
    while (at < input.length && ' \t\n\r'.contains(input[at])) {
      at++;
    }
  }

  String string() {
    final start = at++;
    while (at < input.length) {
      final c = input[at++];
      if (c == '\\') {
        at++;
      } else if (c == '"') {
        return jsonDecode(input.substring(start, at)) as String;
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  late void Function(int) value;
  value = (int depth) {
    if (depth > 32) throw const FormatException('JSON nesting limit');
    space();
    if (at >= input.length) throw const FormatException('Missing JSON value');
    final c = input[at];
    if (c == '"') {
      string();
      return;
    }
    if (c == '{' || c == '[') {
      final object = c == '{';
      final end = object ? '}' : ']';
      final keys = <String>{};
      at++;
      space();
      if (at < input.length && input[at] == end) {
        at++;
        return;
      }
      while (at < input.length) {
        space();
        if (object) {
          if (input[at] != '"') throw const FormatException('Missing JSON key');
          if (!keys.add(string())) {
            throw const FormatException('Duplicate JSON key');
          }
          space();
          if (at >= input.length || input[at++] != ':') {
            throw const FormatException('Missing colon');
          }
        }
        value(depth + 1);
        space();
        if (at >= input.length) break;
        final next = input[at++];
        if (next == end) return;
        if (next != ',') throw const FormatException('Missing separator');
      }
      throw const FormatException('Incomplete JSON container');
    }
    final start = at;
    while (at < input.length && !',]} \t\n\r'.contains(input[at])) {
      at++;
    }
    if (at == start) throw const FormatException('Invalid JSON value');
    jsonDecode(input.substring(start, at));
  };
  value(0);
  space();
  if (at != input.length) throw const FormatException('Trailing JSON content');
  return jsonDecode(input);
}
