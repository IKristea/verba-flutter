import 'dart:convert';

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

/// Descriptions from the template ARB (`@key.description`), keyed by Verba key: a whole-message plural is split
/// into `name__one`, `name__other`…, and every form gets the message's description.
Map<String, String> arbDescriptions(Map<String, dynamic> arb, {bool escaping = false}) {
  final out = <String, String>{};
  for (final MapEntry(:key, :value) in arb.entries) {
    if (key.startsWith('@') || value is! String) continue;
    final meta = arb['@$key'];
    final description = meta is Map ? meta['description'] : null;
    if (description is! String || description.trim().isEmpty) continue;
    for (final verbaKey in arbToVerba(key, value, escaping: escaping).keys) {
      out[verbaKey] = description.trim();
    }
  }
  return out;
}

/// Applies the local template's metadata on top of an ARB fetched from Verba, so `gen-l10n` generates the same
/// methods as before the fetch:
/// - the description, types (`int`, `DateTime`…), `format`/`example` and the ORDER of placeholders (which is the
///   order of the generated method's parameters) come from the template; Verba only knows them as String, sorted;
/// - a placeholder that is new in Verba and unknown locally is added with Verba's type;
/// - a whole-message plural gets its local argument back (`{days, plural, …}`), since Verba stores it as `count`.
/// Keys without local metadata keep what Verba sent.
String mergeLocalMetadata(String fetched, Map<String, dynamic> template) {
  final remote = jsonDecode(fetched) as Map<String, dynamic>;
  final out = <String, dynamic>{};
  for (final MapEntry(:key, :value) in remote.entries) {
    if (key.startsWith('@') && !key.startsWith('@@')) continue; // metadata is written next to its message below
    final local = template['@$key'];
    if (key.startsWith('@@') || value is! String || local is! Map) {
      out[key] = value;
      if (remote['@$key'] != null) out['@$key'] = remote['@$key'];
      continue;
    }
    final localPh = local['placeholders'] is Map ? local['placeholders'] as Map : const {};
    var message = value;
    final pluralArg = _wholePlural(template[key] is String ? template[key] as String : '')?.$1;
    if (pluralArg != null && pluralArg != 'count' && !localPh.containsKey('count')) {
      message = message.replaceAllMapped(RegExp(r'\{(\s*)count(\s*[,}])'), (m) => '{${m[1]}$pluralArg${m[2]}');
    }
    out[key] = message;

    final used = {for (final m in RegExp(r'\{\s*([A-Za-z_]\w*)\s*[,}]').allMatches(message)) m[1]!};
    final remotePh = remote['@$key'] is Map && (remote['@$key'] as Map)['placeholders'] is Map
        ? (remote['@$key'] as Map)['placeholders'] as Map
        : const {};
    final placeholders = <String, dynamic>{
      for (final MapEntry(:key, :value) in localPh.entries)
        if (used.contains(key)) '$key': value,
      for (final MapEntry(:key, :value) in remotePh.entries)
        if (!localPh.containsKey(key) && used.contains(key)) '$key': value,
    };
    final description =
        local['description'] ?? (remote['@$key'] is Map ? (remote['@$key'] as Map)['description'] : null);
    final meta = <String, dynamic>{
      for (final MapEntry(:key, :value) in local.entries)
        if (key != 'placeholders' && key != 'description') '$key': value,
      if (description != null) 'description': description,
      if (placeholders.isNotEmpty) 'placeholders': placeholders,
    };
    if (meta.isNotEmpty) out['@$key'] = meta;
  }
  return '${const JsonEncoder.withIndent('  ').convert(out)}\n';
}
