# verba_translations

[Verba](https://verba.kred) for Flutter. One package with two jobs:

- **CLI** (`dart run verba_translations`) — pushes new keys from your ARB files to Verba (with a write token) and
  fetches approved translations back into the ARB files that `flutter gen-l10n` compiles;
- **OTA runtime (optional)** — texts changed in Verba show up in the running app, without a new release.

## Setup
```bash
flutter pub add verba_translations
```
`pubspec.yaml` (standard gen-l10n):
```yaml
dependencies:
  flutter_localizations:
    sdk: flutter
  intl: any

flutter:
  generate: true
```
All Verba settings go in one `verba.yaml` next to `pubspec.yaml`:
```yaml
project: my-project
download_token: …     # read: fetch, OTA
upload_token: …       # write: push
# server: https://…   # self-hosted Verba
# locales: [en, ro]   # default: the project's locales in Verba
```
**Add `verba.yaml` to `.gitignore` when it holds tokens.** The same keys also work as a `verba:` section in
`pubspec.yaml` (used when there is no `verba.yaml`) — keep the tokens out of it, since `pubspec.yaml` is committed.

Tokens are looked up in this order:

| | env | config | file |
|---|---|---|---|
| **read** (fetch, OTA) | `VERBA_TOKEN` | `download_token` | `.verba-token` |
| **write** (push) | `VERBA_WRITE_TOKEN` | `upload_token` | `.verba-write-token` |

Generate them in Verba: project → **Settings** → **Package keys**. On CI, pass them as env variables.

## Fetch + push
```bash
dart run verba_translations && flutter run
```
With a **write** token it pushes first, then fetches: keys that exist only in your ARB files are created in Verba
with their texts, and empty values in Verba are filled in. Anything already in Verba is **never overwritten**
(Verba is the source of truth), and keys deleted in Verba are not revived. If the push of a locale fails, its file
is not overwritten by the fetch.
- push only: `dart run verba_translations --push`
- fetch without the automatic push: `--no-push`
- without a write token, fetch rewrites the files with what is in Verba — a key added only locally is lost.

### Descriptions and placeholders
- push sends each `@key.description` from the template file to Verba, as context for translators (only for keys
  that have no description in Verba yet);
- fetch keeps the template's metadata: `description`, placeholder `type`, `format`, `example` and the **order** of
  placeholders — so `flutter gen-l10n` generates exactly the same methods (`phoneLengthRange(int min, int max)`)
  before and after a fetch. A whole-message plural keeps its own argument name (`{days, plural, …}`);
- keys without local metadata get the description from Verba, and placeholders as `String` (`count` → `int`);
- on Android/iOS/.NET, named placeholders are numbered by the source text: `Between {min} and {max}` is
  `%1$s … %2$s`, and a translation that swaps them (`maximum {max}, minimum {min}`) gets `%2$s … %1$s`, so the
  same arguments land in the right place in every language. In a plural with other placeholders the count is
  `%1$d` (`%1$d days / %2$s`).

Fail-soft: no token / offline / error → a warning, exit code 0, existing files are kept.

## What is inferred
| Setting | Default |
|---|---|
| `locales` | from Verba (by token); pin them with `locales: [en, ro]` |
| folder | `arb-dir` from `l10n.yaml` (default `lib/l10n`) |
| file names | from `template-arb-file` (default `app_en.arb`): `app_<locale>.arb`, `pt-BR` → `app_pt_BR.arb` |
| base locale | `pt_BR` without `pt` in Verba → `app_pt.arb` is written too (gen-l10n requires it) |
| escaping | `use-escaping` from `l10n.yaml` |
| server | `https://verba.kred`; self-hosted: `server: https://…` |

## Conversions
| Verba | ARB |
|---|---|
| `{name}` | `{name}` |
| `{0}`, `%1$s` | `{arg0}` (placeholders must be Dart identifiers) |
| `files__one`, `files__other` (`%d`) | `{count, plural, one{{count} …} other{{count} …}}` |
| `MD-{{AAAA}}` (literal braces) | with `use-escaping: true`: `MD-'{'AAAA'}'` (and `'` → `''`); without it: `MD-{AAAA}` |

Keys that cannot be Dart getters (`home.title`, `Title`, `1st`, reserved words like `class`) are skipped — gen-l10n would reject the
whole file. Complex ICU messages (`select`, a plural in the middle of a text) pass through unchanged both ways.

## OTA at runtime (optional)
```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VerbaOta.start(project: 'my-project');   // read token: --dart-define=VERBA_TOKEN=…
  runApp(const VerbaScope(child: MyApp()));
}

// in a widget — Verba first, then the compiled gen-l10n text
final l = AppLocalizations.of(context)!;
Text(VerbaOta.text(context, 'greeting', {'name': user}) ?? l.greeting(user))
Text(VerbaOta.text(context, 'files', {'count': n}) ?? l.files(n))
```
```bash
flutter run --dart-define=VERBA_TOKEN=$(cat .verba-token)
```
- no network on the render path: an in-memory map; on start, the last downloaded texts (`shared_preferences`);
- background download on start and whenever the app returns to the foreground, one conditional request per
  locale (ETag → `304`); optionally `interval:`; manually `VerbaOta.refresh()`;
- Verba unreachable → the last good texts stay (or the compiled ones), with a single warning;
- placeholders, plural (CLDR rules from `intl`) and select, like gen-l10n; a text that cannot be formatted
  (missing argument) yields `null` → the compiled text;
- under `VerbaScope`, widgets that read through `VerbaOta.text` rebuild when new texts arrive;
  without a context: `VerbaOta.get('ro', 'greeting', {'name': user})`;
- `use-escaping: true` in `l10n.yaml` → `VerbaOta.start(..., escaping: true)`.

## Example
[`example/`](example) — a minimal app (run `flutter create .` in the folder to add platforms).

## Development
```bash
flutter pub get && flutter analyze && flutter test
```
