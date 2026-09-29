import 'package:flutter/material.dart';
import 'package:verba_translations/verba_translations.dart';

import 'l10n/gen/app_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // read token: flutter run --dart-define=VERBA_TOKEN=$(cat .verba-token)
  await VerbaOta.start(project: 'my-project');
  runApp(const VerbaScope(child: DemoApp()));
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key, this.locale});

  final Locale? locale;

  @override
  Widget build(BuildContext context) => MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Home(),
      );
}

class Home extends StatelessWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(VerbaOta.text(context, 'title') ?? l.title)),
      body: Column(children: [
        Text(VerbaOta.text(context, 'hello', {'name': 'Ana'}) ?? l.hello('Ana')),
        Text(VerbaOta.text(context, 'files', {'count': 3}) ?? l.files(3)),
      ]),
    );
  }
}
