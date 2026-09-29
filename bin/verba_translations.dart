// Verba CLI for Flutter, run from the app root:
//
//   dart run verba_translations            fetch; with a write token, push new ARB keys first
//   dart run verba_translations --push     push only
//   dart run verba_translations --no-push  fetch without the automatic push
//
// Minimal config in pubspec.yaml:   verba: { project: slug }
// Everything else is inferred:
//  - locales       → from Verba (GET /manifest, by token)
//  - arb-dir       → from l10n.yaml (default lib/l10n)
//  - file names    → from template-arb-file in l10n.yaml (default app_en.arb): app_<locale>.arb, pt-BR → app_pt_BR.arb
//  - use-escaping  → from l10n.yaml; with it, literal braces become '{' '}' and an apostrophe ''
// Optional in the verba section: server (self-hosting), locales.
//
// Tokens, looked up in order (files next to pubspec.yaml, gitignored):
//   read : env VERBA_TOKEN       → .verba-token
//   write: env VERBA_WRITE_TOKEN → .verba-write-token
// Push = POST /projects/{slug}/push: creates missing keys and fills empty values; anything already in Verba
// is left untouched (Verba is the source of truth) and keys deleted in Verba are not revived.
// Fail-soft: any error → warning, exit 0 (never breaks a build or CI).
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:verba_translations/src/arb_convert.dart';
import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  final pushOnly = args.contains('--push');
  final noPush = args.contains('--no-push');
  final root = Directory.current.path;

  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) return warn('run from your app root (no pubspec.yaml) — skipping.');
  final YamlMap? cfg;
  try {
    final y = loadYaml(pubspec.readAsStringSync());
    cfg = y is YamlMap && y['verba'] is YamlMap ? y['verba'] as YamlMap : null;
  } on YamlException catch (e) {
    return warn('pubspec.yaml invalid: ${e.message}');
  }
  final project = cfg?['project']?.toString();
  if (project == null || project.isEmpty) return warn('missing `verba: project: <slug>` in pubspec.yaml — skipping.');

  // l10n.yaml: same keys as `flutter gen-l10n`
  YamlMap l10n = YamlMap();
  final l10nFile = File('$root/l10n.yaml');
  if (l10nFile.existsSync()) {
    try {
      final y = loadYaml(l10nFile.readAsStringSync());
      if (y is YamlMap) l10n = y;
    } on YamlException catch (e) {
      return warn('l10n.yaml invalid: ${e.message}');
    }
  }
  final arbDir = Directory('$root/${l10n['arb-dir'] ?? 'lib/l10n'}');
  final template = '${l10n['template-arb-file'] ?? 'app_en.arb'}';
  final escaping = l10n['use-escaping'] == true;
  final prefix = arbPrefix(template);

  final server = (cfg?['server']?.toString() ?? 'https://verba.kred').replaceAll(RegExp(r'/+$'), '');
  final projectUrl = '$server/projects/${Uri.encodeComponent(project)}';
  final readToken = findToken(root, 'VERBA_TOKEN', '.verba-token');
  final writeToken = findToken(root, 'VERBA_WRITE_TOKEN', '.verba-write-token');
  if (pushOnly && writeToken == null) {
    return warn('push: no write token (env VERBA_WRITE_TOKEN or .verba-write-token) — skipping.');
  }
  if (!pushOnly && readToken == null && writeToken == null) {
    return warn('no token (env VERBA_TOKEN or .verba-token) — skipping, existing files kept.');
  }
  final token = readToken ?? writeToken!;
  final client = http.Client();

  try {
    var locales = (cfg?['locales'] as YamlList?)?.map((e) => '$e').toList() ?? <String>[];
    String? defaultLocale;
    if (locales.isEmpty) {
      try {
        final r = await client.get(Uri.parse('$server/manifest'), headers: auth(token)).timeout(timeout);
        if (r.statusCode != 200) return warn('manifest: HTTP ${r.statusCode} — skipping.');
        final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        if (m['slug'] != null && m['slug'] != project) {
          return warn("the token belongs to project '${m['slug']}', not '$project' — skipping.");
        }
        locales = [for (final l in (m['locales'] as List? ?? const [])) '$l'];
        defaultLocale = m['defaultLocale'] as String?;
      } catch (e) {
        return warn('manifest: $e — skipping.');
      }
    }
    locales = locales.where((l) {
      if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(l)) return true;
      warn("invalid locale '$l' — skipping it.");
      return false;
    }).toList();

    File fileFor(String locale) => File('${arbDir.path}/$prefix${locale.replaceAll('-', '_')}.arb');
    final templateLocale = locales.where((l) => '$prefix${l.replaceAll('-', '_')}.arb' == template).firstOrNull;
    if (templateLocale == null && !pushOnly) {
      warn('$template matches no Verba locale (${locales.join(', ')}) — gen-l10n needs it.');
    }

    // ===== PUSH: new keys/texts from ARB → Verba (before fetch, so fetch does not drop them) =====
    final pushFailed = <String>{};
    if (writeToken != null && (pushOnly || !noPush)) {
      final source = templateLocale ?? defaultLocale;
      // template locale first: the key is created with its source text, the others fill in
      for (final locale in [...locales]..sort((a, b) => (a == source ? 0 : 1) - (b == source ? 0 : 1))) {
        final file = fileFor(locale);
        if (!file.existsSync()) continue;
        try {
          final values = <String, String>{};
          final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          for (final MapEntry(:key, :value) in arb.entries) {
            if (key.startsWith('@') || value is! String) continue;
            values.addAll(arbToVerba(key, value, escaping: escaping));
          }
          if (values.isEmpty) continue;
          final r = await client
              .post(Uri.parse('$projectUrl/push'),
                  headers: {...auth(writeToken), 'Content-Type': 'application/json'},
                  body: jsonEncode({'locale': locale, 'values': values}))
              .timeout(timeout);
          final body = utf8.decode(r.bodyBytes);
          if (r.statusCode != 200) {
            warn('push [$locale] HTTP ${r.statusCode}: ${trim(body)}');
            pushFailed.add(locale);
            continue;
          }
          final res = jsonDecode(body) as Map<String, dynamic>;
          final created = res['keysCreated'] ?? 0, filled = res['valuesFilled'] ?? 0;
          if (created != 0 || filled != 0) stdout.writeln('verba: push [$locale] +$created keys, $filled new values');
        } catch (e) {
          warn('push [$locale] $e');
          pushFailed.add(locale);
        }
      }
    }
    if (pushOnly) return;

    // ===== FETCH: Verba → ARB =====
    arbDir.createSync(recursive: true);
    final format = escaping ? 'flutter-arb-escaped' : 'flutter-arb';
    for (final locale in locales) {
      // push failed → fetch would drop keys that exist only locally
      if (pushFailed.contains(locale)) {
        warn('[$locale] push failed — not overwriting ${fileFor(locale).path.substring(root.length + 1)}.');
        continue;
      }
      try {
        final url = Uri.parse('$projectUrl/bundle?locale=${Uri.encodeComponent(locale)}&format=$format');
        final r = await client.get(url, headers: auth(token)).timeout(timeout);
        if (r.statusCode != 200) {
          warn('[$locale] HTTP ${r.statusCode} — keeping the existing file.');
          continue;
        }
        final body = utf8.decode(r.bodyBytes);
        write(fileFor(locale), body, locale);
        // gen-l10n needs the base locale next to a regional one (pt_BR → pt); if Verba lacks it, copy it
        final base = locale.split(RegExp('[-_]')).first;
        if (base != locale && !locales.contains(base)) {
          write(fileFor(base), body.replaceFirst(RegExp(r'"@@locale":\s*"[^"]*"'), '"@@locale": "$base"'), base);
        }
      } catch (e) {
        warn('[$locale] $e — keeping the existing file.');
      }
    }
  } finally {
    client.close();
  }
}

const timeout = Duration(seconds: 30);

/// Writes only when something changed (avoids needless rebuilds and diffs).
void write(File file, String body, String locale) {
  if (file.existsSync() && file.readAsStringSync() == body) return;
  file.writeAsStringSync(body);
  stdout.writeln('verba: [$locale] -> ${file.path.substring(Directory.current.path.length + 1)}');
}

/// `app_en.arb` → `app_`, `strings_pt_BR.arb` → `strings_`: the prefix is everything before the locale.
String arbPrefix(String template) {
  final name = template.endsWith('.arb') ? template.substring(0, template.length - 4) : template;
  final m = RegExp(r'^(.*?_)[a-z]{2,3}(_[A-Z][a-z]{3})?(_([A-Z]{2}|\d{3}))?$').firstMatch(name);
  return m?[1] ?? 'app_';
}

String? findToken(String root, String env, String fileName) {
  var t = Platform.environment[env];
  final file = File('$root/$fileName');
  if ((t == null || t.trim().isEmpty) && file.existsSync()) {
    t = file.readAsLinesSync().firstOrNull;
  }
  t = t?.trim();
  return t == null || t.isEmpty ? null : t;
}

Map<String, String> auth(String token) => {'Authorization': 'Bearer $token'};

String trim(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;

void warn(String msg) => stderr.writeln('verba (warn): $msg');
