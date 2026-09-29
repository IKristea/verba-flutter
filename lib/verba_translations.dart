/// Verba OTA pentru Flutter: textele modificate în Verba apar în aplicație fără release nou.
///
/// ```dart
/// await VerbaOta.start(project: 'slug-proiect');         // token: --dart-define=VERBA_TOKEN=…
/// runApp(const VerbaScope(child: MyApp()));
///
/// // în widget — Verba întâi, apoi textul compilat din gen-l10n
/// Text(VerbaOta.text(context, 'greeting', {'name': user}) ?? l10n.greeting(user))
/// ```
library;

export 'src/icu.dart' show formatIcu;
export 'src/verba_ota.dart' show VerbaOta, VerbaScope;
