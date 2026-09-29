# Verba — client Flutter (`verba_translations`)

Un singur pachet, două roluri:
- **CLI** (`dart run verba_translations`) — urcă cheile noi din ARB în Verba (cu token write) și aduce
  traducerile din Verba în fișierele ARB pe care le folosește `flutter gen-l10n`;
- **runtime (OTA, opțional)** — textele modificate în Verba apar în aplicația care rulează, fără release nou.

## Integrare
```bash
flutter pub add verba_translations
```
`pubspec.yaml` (gen-l10n standard + secțiunea `verba`):
```yaml
dependencies:
  flutter_localizations:
    sdk: flutter
  intl: any

flutter:
  generate: true

verba:
  project: slug-proiect
```
Tokenuri, căutate în ordine (fișierele lângă `pubspec.yaml`, **gitignored**):

| | env | fișier |
|---|---|---|
| **read** (fetch, OTA) | `VERBA_TOKEN` | `.verba-token` |
| **write** (push) | `VERBA_WRITE_TOKEN` | `.verba-write-token` |

## Fetch + push
```bash
dart run verba_translations && flutter run
```
Cu token **write**, întâi push, apoi fetch: cheile care există doar în ARB se creează în Verba cu textele lor,
valorile goale din Verba se completează. Ce e deja în Verba **nu se suprascrie** (Verba e sursa de adevăr), iar
cheile șterse în Verba nu reînvie. Dacă push-ul unei limbi eșuează, fișierul ei nu se rescrie la fetch.
- doar push: `dart run verba_translations --push`
- fetch fără push automat: `--no-push`
- fără token write, fetch-ul rescrie fișierele cu ce e în Verba — o cheie adăugată doar local se pierde;
- ARB-ul e generat de Verba: metadata locală (`description`, `example`) nu se păstrează; placeholder-ele
  primesc tipuri (`String`, `count` → `int`).

Fail-soft: fără token / offline / eroare → avertisment, exit 0, rămân fișierele existente.

## Ce se deduce
| Câmp | Implicit |
|---|---|
| `locales` | din Verba (`/manifest`, după token); fixabil în `verba: locales: [en, ro]` |
| folderul | `arb-dir` din `l10n.yaml` (implicit `lib/l10n`) |
| fișierele | după `template-arb-file` (implicit `app_en.arb`): `app_<limbă>.arb`, `pt-BR` → `app_pt_BR.arb` |
| limba de bază | `pt_BR` fără `pt` în Verba → se scrie și `app_pt.arb` (gen-l10n o cere) |
| escaping | `use-escaping` din `l10n.yaml` |
| server | `https://verba.kred`; self-host: `verba: server: https://…` |

## Conversii
| Verba | ARB |
|---|---|
| `{name}` | `{name}` |
| `{0}`, `%1$s` | `{arg0}` (placeholder-ele trebuie să fie identificatori Dart) |
| `files__one`, `files__other` (`%d`) | `{count, plural, one{{count} …} other{{count} …}}` |
| `MD-{{AAAA}}` (acolade literale) | cu `use-escaping: true`: `MD-'{'AAAA'}'` (și `'` → `''`); fără: `MD-{AAAA}` |

Cheile care nu pot fi getter-e Dart (`home.title`, `Title`, `1st`, `class`) se sar — gen-l10n ar refuza tot
fișierul. Mesajele ICU complexe (`select`, plural în mijlocul textului) trec neschimbate în ambele sensuri.

## OTA la runtime (opțional)
```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VerbaOta.start(project: 'slug-proiect');   // tokenul read: --dart-define=VERBA_TOKEN=…
  runApp(const VerbaScope(child: MyApp()));
}

// în widget — Verba întâi, apoi textul compilat din gen-l10n
final l = AppLocalizations.of(context)!;
Text(VerbaOta.text(context, 'greeting', {'name': user}) ?? l.greeting(user))
Text(VerbaOta.text(context, 'files', {'count': n}) ?? l.files(n))
```
```bash
flutter run --dart-define=VERBA_TOKEN=$(cat .verba-token)
```
- fără rețea pe calea de randare: dicționar în memorie; la pornire ultimele texte descărcate (`shared_preferences`);
- descărcare în fundal la pornire și la revenirea în față, câte o cerere condiționată per limbă (ETag → `304`);
  opțional `interval:`; manual `VerbaOta.refresh()`;
- Verba indisponibil → rămân ultimele texte bune (sau cele compilate), o singură avertizare;
- placeholder-e, plural (regulile CLDR din `intl`) și select, ca în gen-l10n; un text care nu se poate
  formata (argument lipsă) dă `null` → textul compilat;
- sub `VerbaScope`, widget-urile care citesc prin `VerbaOta.text` se reconstruiesc la texte noi;
  fără context: `VerbaOta.get('ro', 'greeting', {'name': user})`;
- `use-escaping: true` în `l10n.yaml` → `VerbaOta.start(..., escaping: true)`.

## Exemplu
[`example/`](example) — aplicație minimă (`flutter create .` în folder pentru platforme).

## Dezvoltare în repo
```bash
flutter pub get && flutter analyze && flutter test
```
Într-o aplicație, fără pachet publicat: `verba_translations: { path: /cale/către/Verba/clients/flutter }`.
