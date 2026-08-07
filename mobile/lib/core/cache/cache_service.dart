import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_config.dart';

/// 【FEAT-280】オフラインキャッシュの基盤サービス（Tier 2: 読み取り専用 SWR）。
///
/// 設計:
///   - `shared_preferences` に JSON 文字列で保存
///   - 各エントリは `{cached_at_ms, expires_at_ms, data}` ラッパー構造
///   - 読み取りは「期限切れでも返す」（呼び出し側が `isFresh` を見て判定）
///   - 起動時に GC で TTL × 3 を超えた古いエントリを削除（Pre-mortem #3）
///   - サインアウト時に全削除（Pre-mortem #2）
///
/// このクラスは Riverpod の `cacheServiceProvider` 経由で取得する。
/// `main.dart` で `SharedPreferences.getInstance()` した上で
/// `cacheServiceProvider.overrideWithValue(CacheService(prefs))` で
/// 注入する（init 同期化のため）。
class CacheService {
  CacheService(this._prefs);

  final SharedPreferences _prefs;

  /// 全キャッシュキーに付与する prefix。
  /// 既存の SharedPreferences キーと衝突しないようバージョン番号付き。
  /// 将来スキーマを変えたら `cache_v2:` 等に上げてマイグレーション不要で破棄できる。
  static const String _prefix = 'cache_v1:';

  /// JSON Map をキャッシュから取得する。期限切れでも返す（呼び出し側で `isFresh` を確認）。
  ///
  /// JSON の `data` 部分が `Map<String, dynamic>` 想定。
  /// 不正な JSON や型不一致は silently `null` を返し、不正エントリは自動削除する。
  CacheEntry<Map<String, dynamic>>? getMap(String key) {
    return _getRaw<Map<String, dynamic>>(key, (raw) {
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
      throw const FormatException('cache data is not a Map');
    });
  }

  /// JSON List をキャッシュから取得する。期限切れでも返す。
  CacheEntry<List<dynamic>>? getList(String key) {
    return _getRaw<List<dynamic>>(key, (raw) {
      if (raw is List) return raw;
      throw const FormatException('cache data is not a List');
    });
  }

  CacheEntry<T>? _getRaw<T>(String key, T Function(Object?) coerce) {
    if (!CacheConfig.enabled) return null;
    final raw = _prefs.getString('$_prefix$key');
    if (raw == null) return null;
    try {
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt =
          DateTime.fromMillisecondsSinceEpoch(wrapper['cached_at_ms'] as int);
      final expiresAt =
          DateTime.fromMillisecondsSinceEpoch(wrapper['expires_at_ms'] as int);
      final data = coerce(wrapper['data']);
      return CacheEntry<T>(
        data: data,
        cachedAt: cachedAt,
        expiresAt: expiresAt,
      );
    } catch (e, st) {
      // 破損エントリは silently 削除（次回 fetch でリビルド）
      debugPrint('[CacheService] dropping corrupt entry "$key": $e\n$st');
      _prefs.remove('$_prefix$key');
      return null;
    }
  }

  /// Map をキャッシュに保存する。TTL を内部に埋め込み、`getMap` で復元する。
  Future<void> setMap(
    String key,
    Map<String, dynamic> data, {
    required Duration ttl,
  }) async {
    if (!CacheConfig.enabled) return;
    await _setRaw(key, data, ttl: ttl);
  }

  /// List をキャッシュに保存する。
  Future<void> setList(
    String key,
    List<dynamic> data, {
    required Duration ttl,
  }) async {
    if (!CacheConfig.enabled) return;
    await _setRaw(key, data, ttl: ttl);
  }

  Future<void> _setRaw(
    String key,
    Object data, {
    required Duration ttl,
  }) async {
    final now = DateTime.now();
    final wrapper = <String, dynamic>{
      'cached_at_ms':  now.millisecondsSinceEpoch,
      'expires_at_ms': now.add(ttl).millisecondsSinceEpoch,
      'data':          data,
    };
    try {
      final encoded = jsonEncode(wrapper);
      await _prefs.setString('$_prefix$key', encoded);
    } catch (e, st) {
      // jsonEncode が失敗するのは Object/Function 等の非 JSON 値が紛れたとき。
      // キャッシュ保存失敗はアプリ全体を止めないため silently 飲み込む。
      debugPrint('[CacheService] setRaw failed for "$key": $e\n$st');
    }
  }

  /// 単一キーの無効化（write 操作後の invalidate に使う）。
  Future<void> invalidate(String key) async {
    await _prefs.remove('$_prefix$key');
  }

  /// 前方一致でキーを一括削除（例: `'timeline_events:'` → 全日付のタイムラインキャッシュ）。
  /// write 操作で「複数日付のキャッシュをまとめて捨てる」場合に使う。
  Future<void> invalidateByPrefix(String keyPrefix) async {
    final fullPrefix = '$_prefix$keyPrefix';
    final keys = _prefs.getKeys().where((k) => k.startsWith(fullPrefix)).toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
  }

  /// 【Pre-mortem #2】プレイヤー切替時に全キャッシュを削除する。
  /// サインアウト / アカウント削除 / ゲスト → 正式昇格時に必須呼び出し。
  ///
  /// 設計判断: キャッシュキーに `<player_id>` 名前空間を含めるより、
  /// サインアウト時に全削除する方が単純で漏れ防止に強い（Tier 2 では十分）。
  Future<void> clearForPlayerSwitch() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
    debugPrint('[CacheService] cleared ${keys.length} entries for player switch');
  }

  /// 【Pre-mortem #3】起動時 GC: 古すぎる / 不正なエントリを削除する。
  ///
  /// 削除対象:
  /// 1. TTL × `hardExpiryTtlMultiplier` を過ぎたエントリ
  ///    （TTL = 5 分なら 15 分後、TTL = 1 時間なら 3 時間後）
  /// 2. JSON 構造が壊れたエントリ
  /// 3. 容量上限 (`maxCacheBytes`) を超えていたら古い順に削除
  Future<void> garbageCollect() async {
    if (!CacheConfig.enabled) return;
    final now = DateTime.now();
    final keys = _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();

    int totalBytes = 0;
    final survivors = <_KeyMeta>[];

    for (final k in keys) {
      final raw = _prefs.getString(k);
      if (raw == null) continue;
      try {
        final wrapper = jsonDecode(raw) as Map<String, dynamic>;
        final cachedAtMs = wrapper['cached_at_ms'] as int;
        final expiresAtMs = wrapper['expires_at_ms'] as int;
        final cachedAt = DateTime.fromMillisecondsSinceEpoch(cachedAtMs);
        final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
        final ttl = expiresAt.difference(cachedAt);
        final hardExpiry = expiresAt.add(
          ttl * (CacheConfig.hardExpiryTtlMultiplier - 1),
        );

        if (now.isAfter(hardExpiry)) {
          await _prefs.remove(k);
          continue;
        }

        totalBytes += raw.length;
        survivors.add(_KeyMeta(key: k, cachedAtMs: cachedAtMs, bytes: raw.length));
      } catch (_) {
        // 不正エントリは即削除
        await _prefs.remove(k);
      }
    }

    if (totalBytes <= CacheConfig.maxCacheBytes) return;

    // 容量超過 → 古い順に削除
    survivors.sort((a, b) => a.cachedAtMs.compareTo(b.cachedAtMs));
    for (final entry in survivors) {
      if (totalBytes <= CacheConfig.maxCacheBytes) break;
      await _prefs.remove(entry.key);
      totalBytes -= entry.bytes;
    }
  }

  /// 現在の全キャッシュサイズ（テスト・観測用）。
  int approximateSizeBytes() {
    int total = 0;
    for (final k in _prefs.getKeys()) {
      if (!k.startsWith(_prefix)) continue;
      total += _prefs.getString(k)?.length ?? 0;
    }
    return total;
  }
}

/// キャッシュエントリ（メタデータ + データ）。
class CacheEntry<T> {
  CacheEntry({
    required this.data,
    required this.cachedAt,
    required this.expiresAt,
  });

  final T data;
  final DateTime cachedAt;
  final DateTime expiresAt;

  /// TTL 内なら true。false でも `data` は返るため SWR の fallback として使える。
  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

/// 内部用: GC ソート対象のメタデータ。
class _KeyMeta {
  _KeyMeta({
    required this.key,
    required this.cachedAtMs,
    required this.bytes,
  });
  final String key;
  final int cachedAtMs;
  final int bytes;
}

// ─────────────────────────────────────────────────────────────────
// Riverpod プロバイダー
// ─────────────────────────────────────────────────────────────────

/// `main()` で SharedPreferences 取得後に `overrideWithValue` で注入する想定。
/// テストや直接生成では `ProviderContainer(overrides: [...])` で差し替える。
///
/// `UnimplementedError` を投げる初期値: 注入忘れを開発時に検出するため。
final cacheServiceProvider = Provider<CacheService>((ref) {
  throw UnimplementedError(
    'cacheServiceProvider must be overridden in main() with '
    'CacheService(await SharedPreferences.getInstance()).',
  );
});
