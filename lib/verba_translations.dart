/// Verba OTA for Flutter: texts changed in Verba show up in the app without a new release.
///
/// ```dart
/// await VerbaOta.start(project: 'my-project');           // token: --dart-define=VERBA_TOKEN=…
/// runApp(const VerbaScope(child: MyApp()));
///
/// // in a widget — Verba first, then the compiled gen-l10n text
/// Text(VerbaOta.text(context, 'greeting', {'name': user}) ?? l10n.greeting(user))
/// ```
library;

export 'src/icu.dart' show formatIcu;
export 'src/verba_ota.dart' show VerbaOta, VerbaScope;
