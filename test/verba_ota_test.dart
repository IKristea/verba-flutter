import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:verba_translations/verba_translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int bundleCalls;
  late Map<String, String> ro;

  http.Client server() => MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer tok');
        if (req.url.path == '/manifest') {
          return http.Response(jsonEncode({'slug': 'app', 'locales': ['ro', 'pt-BR']}), 200);
        }
        bundleCalls++;
        final locale = req.url.queryParameters['locale'];
        expect(req.url.queryParameters['format'], 'flutter-arb');
        final body = jsonEncode(locale == 'ro' ? {'@@locale': 'ro', ...ro} : {'@@locale': 'pt_BR', 'hello': 'Olá'});
        final etag = '"${body.hashCode}"';
        if (req.headers['If-None-Match'] == etag) return http.Response('', 304);
        return http.Response.bytes(utf8.encode(body), 200, headers: {'etag': etag});
      });

  setUp(() {
    VerbaOta.reset();
    SharedPreferences.setMockInitialValues({});
    bundleCalls = 0;
    ro = {
      'hello': 'Salut, {name}!',
      'files': '{count, plural, one{{count} fișier} few{{count} fișiere} other{{count} de fișiere}}',
      '@hello': '{}',
    };
  });

  test('aduce textele, formatează, caută în limba părinte', () async {
    await VerbaOta.start(project: 'app', token: 'tok', client: server());
    await VerbaOta.refresh();
    expect(VerbaOta.get('ro', 'hello', {'name': 'Ana'}), 'Salut, Ana!');
    expect(VerbaOta.get('ro_RO', 'files', {'count': 3}), '3 fișiere');
    expect(VerbaOta.get('pt_BR', 'hello'), 'Olá');
    expect(VerbaOta.get('pt-BR', 'missing'), isNull);
    expect(VerbaOta.get('de', 'hello'), isNull);
    expect(VerbaOta.get('ro', 'hello'), isNull, reason: 'argument lipsă → textul compilat');
  });

  test('ETag: fără schimbări nu notifică; cache-ul supraviețuiește repornirii', () async {
    await VerbaOta.start(project: 'app', token: 'tok', client: server());
    await VerbaOta.refresh();
    var notified = 0;
    void listener() => notified++;
    VerbaOta.instance.addListener(listener);
    await VerbaOta.refresh();
    expect(notified, 0);
    ro['hello'] = 'Bună, {name}!';
    await VerbaOta.refresh();
    expect(notified, 1);
    VerbaOta.instance.removeListener(listener);

    VerbaOta.reset();
    await VerbaOta.start(project: 'app', token: 'tok', client: MockClient((_) async => http.Response('', 500)));
    expect(VerbaOta.get('ro', 'hello', {'name': 'Ion'}), 'Bună, Ion!', reason: 'din cache, serverul e căzut');
  });

  test('fără token OTA e oprit', () async {
    await VerbaOta.start(project: 'app', token: '', client: server());
    await VerbaOta.refresh();
    expect(bundleCalls, 0);
    expect(VerbaOta.get('ro', 'hello', {'name': 'x'}), isNull);
  });

  testWidgets('VerbaScope reconstruiește widget-urile la texte noi', (tester) async {
    await tester.runAsync(() async {
      await VerbaOta.start(project: 'app', token: 'tok', client: server());
      await VerbaOta.refresh();
    });
    await tester.pumpWidget(VerbaScope(
      child: Localizations(
        locale: const Locale('ro'),
        delegates: const [DefaultWidgetsLocalizations.delegate],
        child: Builder(
          builder: (context) => Text(VerbaOta.text(context, 'hello', {'name': 'Ana'}) ?? 'compilat',
              textDirection: TextDirection.ltr),
        ),
      ),
    ));
    expect(find.text('Salut, Ana!'), findsOneWidget);
    ro['hello'] = 'Hei, {name}!';
    await tester.runAsync(VerbaOta.refresh);
    await tester.pump();
    expect(find.text('Hei, Ana!'), findsOneWidget);
  });
}
