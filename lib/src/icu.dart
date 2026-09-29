import 'package:intl/intl.dart' show Intl;

/// Minimal ICU formatting for OTA texts — the subset `flutter gen-l10n` accepts:
/// `{name}`, `{n, plural, =0{…} one{…} other{…}}`, `{x, select, a{…} other{…}}`, plus `#` inside plural.
/// With [escaping] (`use-escaping: true` in l10n.yaml): `''` → `'`, and `'{…}'` is literal text.
///
/// Any message that cannot be parsed or formatted (missing argument, bad syntax) yields `null` —
/// the caller then uses the compiled text, so OTA can never break a screen.
String? formatIcu(String message, Map<String, Object?> args, {String? locale, bool escaping = false}) {
  try {
    final nodes = _Parser(message, escaping).parseAll();
    final out = StringBuffer();
    _render(nodes, args, locale, null, out);
    return out.toString();
  } on FormatException {
    return null;
  }
}

sealed class _Node {}

class _Text extends _Node {
  _Text(this.text);
  final String text;
}

class _Arg extends _Node {
  _Arg(this.name);
  final String name;
}

class _Hash extends _Node {}

class _Choice extends _Node {
  _Choice(this.name, this.kind, this.cases);
  final String name;
  final String kind; // plural | select
  final Map<String, List<_Node>> cases;
}

void _render(List<_Node> nodes, Map<String, Object?> args, String? locale, num? count, StringBuffer out) {
  for (final n in nodes) {
    switch (n) {
      case _Text(:final text):
        out.write(text);
      case _Hash():
        out.write(count ?? '#');
      case _Arg(:final name):
        if (!args.containsKey(name)) throw FormatException('lipsește argumentul $name');
        out.write(args[name]);
      case _Choice(:final name, :final kind, :final cases):
        if (!args.containsKey(name)) throw FormatException('lipsește argumentul $name');
        final value = args[name];
        final List<_Node>? body;
        if (kind == 'plural') {
          final n = value is num ? value : num.tryParse('$value');
          if (n == null) throw FormatException('$name nu e număr');
          body = cases['=$n'] ??
              (n is double && n == n.roundToDouble() ? cases['=${n.toInt()}'] : null) ??
              Intl.pluralLogic<List<_Node>?>(
                n,
                locale: locale,
                zero: cases['zero'],
                one: cases['one'],
                two: cases['two'],
                few: cases['few'],
                many: cases['many'],
                other: cases['other'],
              );
          if (body == null) throw FormatException('$name: fără formă „other”');
          _render(body, args, locale, n, out);
        } else {
          body = cases['$value'] ?? cases['other'];
          if (body == null) throw FormatException('$name: fără formă „other”');
          _render(body, args, locale, count, out);
        }
    }
  }
}

class _Parser {
  _Parser(this.src, this.escaping);
  final String src;
  final bool escaping;
  int pos = 0;

  List<_Node> parseAll() {
    final nodes = _parseMessage(inChoice: false);
    if (pos < src.length) throw FormatException('„}” în plus la $pos');
    return nodes;
  }

  List<_Node> _parseMessage({required bool inChoice}) {
    final nodes = <_Node>[];
    final text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) nodes.add(_Text(text.toString()));
      text.clear();
    }

    while (pos < src.length) {
      final c = src[pos];
      if (escaping && c == "'") {
        if (pos + 1 < src.length && src[pos + 1] == "'") {
          text.write("'");
          pos += 2;
          continue;
        }
        final end = src.indexOf("'", pos + 1);
        if (end < 0) throw FormatException('apostrof neînchis la $pos');
        text.write(src.substring(pos + 1, end));
        pos = end + 1;
        continue;
      }
      if (c == '{') {
        flush();
        nodes.add(_parseArgument());
        continue;
      }
      if (c == '}') {
        if (!inChoice) throw FormatException('„}” neașteptat la $pos');
        break;
      }
      if (c == '#' && inChoice) {
        flush();
        nodes.add(_Hash());
        pos++;
        continue;
      }
      text.write(c);
      pos++;
    }
    flush();
    return nodes;
  }

  _Node _parseArgument() {
    pos++; // {
    final name = _word();
    if (name.isEmpty) throw FormatException('nume de argument lipsă la $pos');
    _spaces();
    if (_peek('}')) {
      pos++;
      return _Arg(name);
    }
    _expect(',');
    _spaces();
    final kind = _word();
    if (kind != 'plural' && kind != 'select') throw FormatException('tip necunoscut „$kind”');
    _spaces();
    _expect(',');
    final cases = <String, List<_Node>>{};
    while (true) {
      _spaces();
      if (_peek('}')) {
        pos++;
        break;
      }
      final selector = _word(allowEquals: true);
      if (selector.startsWith('offset:')) continue; // offset: nu e folosit de gen-l10n
      if (selector.isEmpty) throw FormatException('selector lipsă la $pos');
      _spaces();
      _expect('{');
      final body = _parseMessage(inChoice: true);
      _expect('}');
      cases[selector] = body;
    }
    return _Choice(name, kind, cases);
  }

  String _word({bool allowEquals = false}) {
    final start = pos;
    while (pos < src.length) {
      final c = src.codeUnitAt(pos);
      final ok = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
          c == 0x5F || c == 0x24 || c == 0x2D || c == 0x2E || (allowEquals && (c == 0x3D || c == 0x3A)) ||
          c > 0x7F;
      if (!ok) break;
      pos++;
    }
    return src.substring(start, pos);
  }

  void _spaces() {
    while (pos < src.length && src[pos].trim().isEmpty) {
      pos++;
    }
  }

  bool _peek(String c) => pos < src.length && src[pos] == c;

  void _expect(String c) {
    if (!_peek(c)) throw FormatException('aștept „$c” la $pos');
    pos++;
  }
}
