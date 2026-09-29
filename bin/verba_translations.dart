// Client Flutter pentru Verba (CLI), rulat din rădăcina aplicației:
//
//   dart run verba_translations            fetch; dacă există token write, întâi push automat (chei noi din ARB)
//   dart run verba_translations --push     doar push
//   dart run verba_translations --no-push  fetch fără push automat
//
// Config minim în pubspec.yaml:   verba: { project: slug }
// Restul se deduce:
//  - locales        → din Verba (GET /manifest, după token)
//  - arb-dir        → din l10n.yaml (implicit lib/l10n)
//  - fișierele      → după template-arb-file din l10n.yaml (implicit app_en.arb): app_<limbă>.arb, pt-BR → app_pt_BR.arb
//  - use-escaping   → din l10n.yaml; cu el, acoladele literale ies '{' '}' și apostroful ''
// Opțional în secțiunea verba: server (self-host), locales.
//
// Tokenuri, căutate în ordine (fișierele lângă pubspec.yaml, gitignored):
//   read : env VERBA_TOKEN       → .verba-token
//   write: env VERBA_WRITE_TOKEN → .verba-write-token
// Push = POST /projects/{slug}/push: creează cheile lipsă și completează valorile goale; ce e deja în Verba
// rămâne neatins (Verba e sursa de adevăr), cheile șterse în Verba nu reînvie.
// Fail-soft: orice eroare → avertisment, exit 0 (nu blochează build-ul / CI-ul).
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
  if (!pubspec.existsSync()) return warn('rulează din rădăcina aplicației (lipsește pubspec.yaml) — sar peste.');
  final YamlMap? cfg;
  try {
    final y = loadYaml(pubspec.readAsStringSync());
    cfg = y is YamlMap && y['verba'] is YamlMap ? y['verba'] as YamlMap : null;
  } on YamlException catch (e) {
    return warn('pubspec.yaml invalid: ${e.message}');
  }
  final project = cfg?['project']?.toString();
  if (project == null || project.isEmpty) return warn('lipsește `verba: project: <slug>` în pubspec.yaml — sar peste.');

  // l10n.yaml: aceleași chei ca `flutter gen-l10n`
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
    return warn('push: fără token write (env VERBA_WRITE_TOKEN sau .verba-write-token) — sar peste.');
  }
  if (!pushOnly && readToken == null && writeToken == null) {
    return warn('fără token (env VERBA_TOKEN sau .verba-token) — sar peste, rămân fișierele existente.');
  }
  final token = readToken ?? writeToken!;
  final client = http.Client();

  try {
    var locales = (cfg?['locales'] as YamlList?)?.map((e) => '$e').toList() ?? <String>[];
    String? defaultLocale;
    if (locales.isEmpty) {
      try {
        final r = await client.get(Uri.parse('$server/manifest'), headers: auth(token)).timeout(timeout);
        if (r.statusCode != 200) return warn('manifest: HTTP ${r.statusCode} — sar peste.');
        final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        if (m['slug'] != null && m['slug'] != project) {
          return warn("tokenul e al proiectului '${m['slug']}', nu '$project' — sar peste.");
        }
        locales = [for (final l in (m['locales'] as List? ?? const [])) '$l'];
        defaultLocale = m['defaultLocale'] as String?;
      } catch (e) {
        return warn('manifest: $e — sar peste.');
      }
    }
    locales = locales.where((l) {
      if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(l)) return true;
      warn("limbă invalidă '$l' — o sar.");
      return false;
    }).toList();

    File fileFor(String locale) => File('${arbDir.path}/$prefix${locale.replaceAll('-', '_')}.arb');
    final templateLocale = locales.where((l) => '$prefix${l.replaceAll('-', '_')}.arb' == template).firstOrNull;
    if (templateLocale == null && !pushOnly) {
      warn('$template nu corespunde niciunei limbi din Verba (${locales.join(', ')}) — gen-l10n are nevoie de el.');
    }

    // ===== PUSH: chei/texte noi din ARB → Verba (înainte de fetch, ca fetch-ul să nu le șteargă) =====
    final pushFailed = <String>{};
    if (writeToken != null && (pushOnly || !noPush)) {
      final source = templateLocale ?? defaultLocale;
      // limba șablonului întâi: cheia se creează cu textul sursă, apoi celelalte completează
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
          if (created != 0 || filled != 0) stdout.writeln('verba: push [$locale] +$created chei, $filled valori noi');
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
      // push-ul n-a trecut → fetch-ul ar șterge cheile care există doar local
      if (pushFailed.contains(locale)) {
        warn('[$locale] push-ul a eșuat — nu rescriu ${fileFor(locale).path.substring(root.length + 1)}.');
        continue;
      }
      try {
        final url = Uri.parse('$projectUrl/bundle?locale=${Uri.encodeComponent(locale)}&format=$format');
        final r = await client.get(url, headers: auth(token)).timeout(timeout);
        if (r.statusCode != 200) {
          warn('[$locale] HTTP ${r.statusCode} — păstrez fișierul existent.');
          continue;
        }
        final body = utf8.decode(r.bodyBytes);
        write(fileFor(locale), body, locale);
        // gen-l10n cere limba de bază lângă una regională (pt_BR → pt); dacă Verba n-o are, o copiem
        final base = locale.split(RegExp('[-_]')).first;
        if (base != locale && !locales.contains(base)) {
          write(fileFor(base), body.replaceFirst(RegExp(r'"@@locale":\s*"[^"]*"'), '"@@locale": "$base"'), base);
        }
      } catch (e) {
        warn('[$locale] $e — păstrez fișierul existent.');
      }
    }
  } finally {
    client.close();
  }
}

const timeout = Duration(seconds: 30);

/// Scrie doar dacă s-a schimbat ceva (evită rebuild-uri și diff-uri inutile).
void write(File file, String body, String locale) {
  if (file.existsSync() && file.readAsStringSync() == body) return;
  file.writeAsStringSync(body);
  stdout.writeln('verba: [$locale] -> ${file.path.substring(Directory.current.path.length + 1)}');
}

/// `app_en.arb` → `app_`, `strings_pt_BR.arb` → `strings_`: prefixul e tot ce e înaintea limbii.
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
