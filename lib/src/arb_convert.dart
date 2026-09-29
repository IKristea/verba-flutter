/// ARB → Verba, the inverse of Verba's `flutter-arb` export (used by push). Pure Dart, no Flutter.
///
/// - `{count, plural, one{…} other{…}}` (the whole message) → flat keys `name__one`, `name__other`, `{count}` → `%d`
///   (how Verba stores plurals, shared with Android/iOS); `=0`/`=1`/`=2` → zero/one/two;
/// - `{arg0}` → `{0}` (the export does the reverse);
/// - with escaping: `'{'` → `{{` (a literal brace in Verba), `''` → `'`;
/// - any other ICU message (select, plural in the middle of a text) stays unchanged.
Map<String, String> arbToVerba(String key, String message, {bool escaping = false}) {
  final plural = _wholePlural(message);
  if (plural != null) {
    final (arg, cases) = plural;
    final out = <String, String>{};
    for (final MapEntry(key: selector, value: body) in cases.entries) {
      final q = switch (selector) { '=0' => 'zero', '=1' => 'one', '=2' => 'two', _ => selector };
      if (!_quantities.contains(q)) return {key: _simple(message, escaping)}; // =5{…}: no flat form
      out['${key}__$q'] = _simple(body, escaping).replaceAll('{$arg}', '%d');
    }
    return out;
  }
  return {key: _simple(message, escaping)};
}

const _quantities = {'zero', 'one', 'two', 'few', 'many', 'other'};

String _simple(String message, bool escaping) {
  // complex messages (select, nested plural) are kept as they are
  if (RegExp(r'\{\s*\w+\s*,\s*(plural|select|selectordinal)\s*,').hasMatch(message)) return message;
  final s = message.replaceAllMapped(RegExp(r'\{arg(\d+)\}'), (m) => '{${m[1]}}');
  if (!escaping) return s;
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != "'") {
      out.write(c);
      continue;
    }
    if (i + 1 < s.length && s[i + 1] == "'") {
      out.write("'");
      i++;
      continue;
    }
    final end = s.indexOf("'", i + 1);
    if (end < 0) {
      out.write(s.substring(i));
      break;
    }
    out.write(s.substring(i + 1, end).replaceAll('{', '{{').replaceAll('}', '}}'));
    i = end;
  }
  return out.toString();
}

/// `{x, plural, a{…} b{…}}` spanning the whole message → (x, {selector: body}); otherwise null.
(String, Map<String, String>)? _wholePlural(String message) {
  final head = RegExp(r'^\s*\{\s*(\w+)\s*,\s*plural\s*,').firstMatch(message);
  if (head == null) return null;
  var pos = head.end;
  final cases = <String, String>{};
  while (true) {
    while (pos < message.length && message[pos].trim().isEmpty) {
      pos++;
    }
    if (pos >= message.length) return null;
    if (message[pos] == '}') {
      return message.substring(pos + 1).trim().isEmpty ? (head[1]!, cases) : null;
    }
    final sel = RegExp(r'[=\w:]+').matchAsPrefix(message, pos);
    if (sel == null) return null;
    pos = sel.end;
    if (sel[0]!.startsWith('offset:')) continue;
    while (pos < message.length && message[pos].trim().isEmpty) {
      pos++;
    }
    if (pos >= message.length || message[pos] != '{') return null;
    // the body: up to the matching brace
    var depth = 0;
    final start = pos + 1;
    for (; pos < message.length; pos++) {
      if (message[pos] == '{') depth++;
      if (message[pos] == '}' && --depth == 0) break;
    }
    if (pos >= message.length) return null;
    cases[sel[0]!] = message.substring(start, pos);
    pos++;
  }
}
