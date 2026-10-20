## 1.1.0
- `verba.yaml` next to `pubspec.yaml` holds all settings, including `download_token` and `upload_token`
  (also accepted in the `verba:` section of `pubspec.yaml`).
- Push sends the template's `@key.description` to Verba as translator context.
- Fetch keeps the template's metadata (descriptions, placeholder types, `format`/`example`, placeholder order and
  the plural argument name), so `gen-l10n` generates the same methods before and after a fetch.
- Keys named like contextual Dart keywords (`on`, `get`, `set`, `late`…) are no longer skipped (needs Verba
  server with the matching update).

## 1.0.1
- Documentation, API docs and CLI messages in English.
- Publishing from GitHub Actions.

## 1.0.0
- CLI `dart run verba_translations`: fetch ARB files from Verba, automatic push of new keys (write token), `--push`, `--no-push`.
- OTA at runtime: `VerbaOta.start`, `VerbaOta.text`, `VerbaOta.get`, `VerbaScope`; cache, ETag, refresh when the app returns to the foreground.
