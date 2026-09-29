import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'icu.dart';

/// Texts delivered from Verba at runtime (over the air).
///
/// - Lookups hit an in-memory map — no network on the render path.
/// - On start the last downloaded texts are loaded (cached in `shared_preferences`), then one bundle per
///   locale is requested in the background, conditionally (ETag → `304` when nothing changed); again whenever
///   the app returns to the foreground and, optionally, every `interval`.
/// - Verba unreachable → the last good texts stay (or the compiled ones); OTA never blocks and never throws.
/// - A text that cannot be formatted (missing argument) yields `null` → the compiled text is used.
class VerbaOta extends ChangeNotifier with WidgetsBindingObserver {
  VerbaOta._();

  /// The single instance; a [Listenable] that notifies after a new set of texts is applied.
  static final VerbaOta instance = VerbaOta._();

  static const _defaultToken = String.fromEnvironment('VERBA_TOKEN');

  Map<String, Map<String, String>> _data = const {};
  final Map<String, String> _etags = {};
  String _server = 'https://verba.kred';
  String? _project;
  String _token = '';
  List<String> _locales = const [];
  bool _escaping = false;
  http.Client? _client;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _failing = false;

  /// Starts OTA. `token` defaults to `--dart-define=VERBA_TOKEN=…` (a **read** token); without a token OTA
  /// stays off and the app uses its compiled texts. `locales` default to the project's locales in Verba.
  /// Set `escaping` when `l10n.yaml` has `use-escaping: true`. Awaiting only waits for the cache to load;
  /// the download runs in the background.
  static Future<void> start({
    required String project,
    String? token,
    List<String>? locales,
    String server = 'https://verba.kred',
    Duration? interval,
    bool escaping = false,
    http.Client? client,
  }) =>
      instance._start(project, token ?? _defaultToken, locales, server, interval, escaping, client);

  /// Fetches new texts now (e.g. on pull-to-refresh). No effect when OTA is not started.
  static Future<void> refresh() => instance._refresh();

  /// Stops refreshing (texts already fetched stay).
  static void stop() => instance._stop();

  /// The text of [key] in [locale] (`ro`, `pt-BR`, `pt_BR`), formatted with [args]; falls back to the parent
  /// locale (`ro-RO` → `ro`). `null` = unknown to Verba → use the compiled text.
  static String? get(String locale, String key, [Map<String, Object?> args = const {}]) =>
      instance._get(locale, key, args);

  /// Like [get], in the locale of [context]. Under a [VerbaScope] the widget rebuilds when new texts arrive.
  static String? text(BuildContext context, String key, [Map<String, Object?> args = const {}]) {
    context.dependOnInheritedWidgetOfExactType<_VerbaInherited>();
    return instance._get(Localizations.localeOf(context).toLanguageTag(), key, args);
  }

  /// Locales that have OTA texts (normalized: `ro`, `pt-br`).
  static Iterable<String> get locales => instance._data.keys;

  Future<void> _start(String project, String token, List<String>? locales, String server, Duration? interval,
      bool escaping, http.Client? client) async {
    _stop();
    _project = project;
    _token = token.trim();
    _locales = locales ?? const [];
    _server = server.replaceAll(RegExp(r'/+$'), '');
    _escaping = escaping;
    _client = client ?? http.Client();
    if (_token.isEmpty) {
      debugPrint('Verba OTA: no token (--dart-define=VERBA_TOKEN=…) — using compiled texts');
      return;
    }
    await _loadCache();
    WidgetsBinding.instance.addObserver(this);
    if (interval != null && interval > Duration.zero) {
      _timer = Timer.periodic(interval, (_) => _refresh());
    }
    unawaited(_refresh());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (_project != null) WidgetsBinding.instance.removeObserver(this);
    _project = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  String? _get(String locale, String key, Map<String, Object?> args) {
    final data = _data;
    if (data.isEmpty) return null;
    for (var tag = _norm(locale); tag.isNotEmpty; tag = _parent(tag)) {
      final message = data[tag]?[key];
      if (message != null) return formatIcu(message, args, locale: tag.replaceAll('-', '_'), escaping: _escaping);
    }
    return null;
  }

  // a single refresh at a time (resume + timer + manual refresh)
  Future<void> _refresh() => _inFlight ??= _doRefresh().whenComplete(() => _inFlight = null);

  Future<void> _doRefresh() async {
    final project = _project, client = _client;
    if (project == null || client == null || _token.isEmpty) return;
    try {
      if (_locales.isEmpty) {
        final r = await client.get(Uri.parse('$_server/manifest'), headers: _headers()).timeout(_timeout);
        if (r.statusCode != 200) throw http.ClientException('manifest: HTTP ${r.statusCode}');
        final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        _locales = [for (final l in (m['locales'] as List? ?? const [])) '$l'];
      }
      final format = _escaping ? 'flutter-arb-escaped' : 'flutter-arb';
      var changed = false;
      for (final locale in _locales) {
        final url = Uri.parse('$_server/projects/${Uri.encodeComponent(project)}/bundle'
            '?locale=${Uri.encodeComponent(locale)}&format=$format');
        final etag = _etags[locale];
        final r = await client
            .get(url, headers: _headers(etag == null ? null : {'If-None-Match': etag}))
            .timeout(_timeout);
        if (r.statusCode == 304) continue;
        if (r.statusCode != 200) throw http.ClientException('[$locale] HTTP ${r.statusCode}');
        final body = utf8.decode(r.bodyBytes);
        _apply(locale, body);
        if (r.headers['etag'] case final tag?) _etags[locale] = tag;
        changed = true;
        unawaited(_saveCache(locale, body, r.headers['etag']));
      }
      if (_failing) debugPrint('Verba OTA: connection restored');
      _failing = false;
      if (changed) notifyListeners();
    } catch (e) {
      // one warning per outage
      if (!_failing) debugPrint('Verba OTA: cannot fetch texts, keeping current ones ($e)');
      _failing = true;
    }
  }

  void _apply(String locale, String arbBody) {
    final arb = jsonDecode(arbBody) as Map<String, dynamic>;
    final texts = <String, String>{
      for (final MapEntry(:key, :value) in arb.entries)
        if (!key.startsWith('@') && value is String) key: value,
    };
    _data = {..._data, _norm(locale): texts};
  }

  String _cacheKey(String locale) => 'verba_ota.$_project.${_norm(locale)}';

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = 'verba_ota.$_project.';
      for (final k in prefs.getKeys().where((k) => k.startsWith(prefix) && !k.endsWith('.etag'))) {
        final body = prefs.getString(k);
        if (body == null) continue;
        final locale = k.substring(prefix.length);
        _apply(locale, body);
        if (prefs.getString('$k.etag') case final tag?) _etags[locale] = tag;
      }
      if (_data.isNotEmpty) notifyListeners();
    } catch (e) {
      debugPrint('Verba OTA: unreadable cache, ignoring it ($e)');
    }
  }

  Future<void> _saveCache(String locale, String body, String? etag) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey(locale), body);
      if (etag != null) await prefs.setString('${_cacheKey(locale)}.etag', etag);
    } catch (_) {
      // the cache is only an optimization
    }
  }

  Map<String, String> _headers([Map<String, String>? extra]) =>
      {'Authorization': 'Bearer $_token', ...?extra};

  static const _timeout = Duration(seconds: 20);

  static String _norm(String locale) => locale.replaceAll('_', '-').toLowerCase();

  static String _parent(String tag) {
    final i = tag.lastIndexOf('-');
    return i < 0 ? '' : tag.substring(0, i);
  }

  /// Clears all texts (tests).
  @visibleForTesting
  static void reset() {
    instance._stop();
    instance._data = const {};
    instance._etags.clear();
    instance._locales = const [];
    instance._failing = false;
  }
}

/// Place above your app so widgets that read through [VerbaOta.text] rebuild when new texts arrive.
class VerbaScope extends StatelessWidget {
  const VerbaScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _VerbaInherited(notifier: VerbaOta.instance, child: child);
}

class _VerbaInherited extends InheritedNotifier<VerbaOta> {
  const _VerbaInherited({required super.notifier, required super.child});
}
