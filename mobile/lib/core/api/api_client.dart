import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】
import 'package:dio_cache_interceptor_hive_store/dio_cache_interceptor_hive_store.dart';  // 【FEAT-476】
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';  // 【FEAT-476】
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2E】Accept-Language 解決
import '../providers/connection_error_provider.dart';  // 【2026-07-09】5xx sentinel の発火先
import '../providers/maintenance_provider.dart';  // 【FEAT-463】X-Maintenance header 検知

part 'api_client.g.dart';

// 環境に応じてベースURLを切り替え
// 【FEAT-199】Render サービス名を Sabiowl ブランドに統一
//   旧: restack-backend.onrender.com
//   新: sabiowl-backend.onrender.com
// ignore: do_not_use_environment
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://sabiowl-backend.onrender.com/api',
);

const _tokenKey            = 'hg_token';
const _guestTokenKey       = 'hg_guest_token';   // FEAT-188: ゲストセッショントークン
const _registeredKey       = 'is_registered';
const _tutorialKey         = 'has_seen_tutorial';
const _guestModeKey        = 'guest_mode';
const _tokenSavedAtKey     = 'token_saved_at';
const _tokenValidatedAtKey = 'token_validated_at';

@riverpod
ApiClient apiClient(Ref ref) {
  return ApiClient(ref);
}

class ApiClient {
  late final Dio _dio;
  final _storage = const FlutterSecureStorage();
  final Ref _ref;

  // ── 【2026-07-07】5xx sentinel: in-flight degradation 検知 ────────
  // 30 秒スライディングウィンドウで 5xx を連続 3 回検知したら
  // ConnectionErrorOverlay を自動発火し、ユーザーに Backend 障害を通知する。
  //
  // 【2026-07-09 変更】旧: maintenanceStatusProvider.markEnabledFromHeader() 経由で
  //   MaintenanceOverlay を発火していたが、admin 意図の maintenance と mobile 側の
  //   推測 (通信/サーバエラー) を混同していた設計を再構築。
  //   新: connectionErrorProvider.mark() 経由で ConnectionErrorOverlay を発火する。
  //   admin 意図の maintenance は `X-Maintenance: 1` header と `/api/maintenance/`
  //   probe が独立して maintenanceStatusProvider に反映する。
  //
  // 発火経路: connectionErrorProvider.mark() → ConnectionErrorOverlay 表示
  // 復旧経路:
  //   1. 次の 2xx レスポンスで自動的に connectionErrorProvider.clear() 呼出
  //      (Backend が復旧した信号 = overlay 出し続ける必要なし)
  //   2. user が ConnectionErrorOverlay の「再試行」ボタンで `/api/health/` を叩く
  //
  // なぜ 3 回 threshold?
  //   - 1-2 回の 5xx は Render deploy 中の一時的な失敗の可能性が高い
  //   - 3 回連続 = 継続的な障害 = user に通知する価値がある
  //   - 30 秒 window = deploy の一時失敗 (通常 5-10 秒) は超えない
  static const Duration _kSentinelWindow = Duration(seconds: 30);
  static const int _kSentinelThreshold = 3;
  int _consecutive5xx = 0;
  DateTime? _first5xxAt;

  void _record5xx() {
    final now = DateTime.now();
    if (_first5xxAt == null ||
        now.difference(_first5xxAt!) > _kSentinelWindow) {
      // ウィンドウ超過 → カウンタリセット & 新しいウィンドウ開始
      _first5xxAt = now;
      _consecutive5xx = 1;
    } else {
      _consecutive5xx++;
    }
    if (_consecutive5xx >= _kSentinelThreshold) {
      // Threshold 到達: ConnectionErrorOverlay 発火 + カウンタリセット
      _ref.read(connectionErrorProvider.notifier).mark();
      _consecutive5xx = 0;
      _first5xxAt = null;
    }
  }

  void _reset5xxCounter() {
    if (_consecutive5xx > 0 || _first5xxAt != null) {
      _consecutive5xx = 0;
      _first5xxAt = null;
    }
    // 【2026-07-09】業務 API から 2xx を受信 = Backend 復旧の信号。
    // ConnectionErrorOverlay も自動 clear して user を通常 UI に戻す。
    // admin 設定 maintenance (maintenanceStatusProvider) は独立して管理される
    // (X-Maintenance header や /api/maintenance/ probe が真実値のため触らない)。
    _ref.read(connectionErrorProvider.notifier).clear();
  }

  ApiClient(this._ref) {
    _dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
        // 【BUG-FIX (2026-05-31)】Content-Type を BaseOptions.headers に固定しない。
        // 旧: headers: {'Content-Type': 'application/json'} を全リクエストに静的設定。
        // 問題: FormData 送信時、Dio は内部で lowercase キー 'content-type' に
        //       'multipart/form-data; boundary=...' をセットするが、BaseOptions の
        //       'Content-Type' (大文字) は Dart Map のキー大小文字区別で別エントリとして
        //       残り、両方が HTTP ヘッダーに追加される。Django が受信すると DRF は
        //       最初の 'Content-Type: application/json' を優先して JSONParser を選択し
        //       request.FILES が空になる → お問い合わせ添付画像がメールに届かない。
        // 修正: BaseOptions.headers から Content-Type を除去し Dio の自動設定に委ねる。
        //   - Map/JSON データ: Dio の DefaultTransformer が 'application/json' を付与
        //   - FormData: Dio が 'multipart/form-data; boundary=...' を正しく付与
        // (JSON リクエストへの影響なし: Dio のデフォルト動作で同じ Content-Type が付与される)
      ),
    );

    // 【FEAT-476】DioCacheInterceptor を非同期で初期化してインデックス 0 に挿入。
    // Hive.initFlutter() は main() 冒頭で完了済み (Pre-mortem S4)。
    // ignore: discarded_futures
    _initCacheInterceptor();

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // 【FEAT-489 Phase 2E】Accept-Language の付与。
          //
          // Backend の I18nMiddleware は
          //   ① Accept-Language → ② PlayerSettings.preferred_language → ③ ja
          // の順で locale を解決するが、Mobile はこれまで **どちらも送っていなかった**
          // ため、Phase 4 で追加した `_en` field 群 (migration 0191-0196) が
          // 100% 到達不能で常に日本語が返っていた。
          //
          // 【2026-08-02】当初 Backend は ①② が逆順だった。`preferred_language`
          // は `default='ja'` で「未設定」を表現できないため、認証済ユーザーは
          // 常に 1 段目で ja に確定し、**このヘッダが読まれることが無かった**。
          // 「US で新規インストール → 英語 UI → 設定画面を開かない」という
          // 最も普通の導線が 2 言語混在になっていたため、Backend 側の順序を
          // 入れ替えた (doc/design/backend_i18n.md §2.4)。
          //
          // 送る値は **アプリが実際に解決している locale** (`ServiceL10n.current`)。
          // 端末 locale (`Platform.localeName` 等) を送ってはいけない —— UI は
          // BUG-27 対策で `Locale('ja','JP')` 固定なので、端末 locale を送ると
          // 「UI は日本語なのにサビの台詞とお知らせだけ英語」という 1 画面 2 言語
          // 混在になる (Pre-mortem S5)。
          //
          // 現状の実効挙動は「`ja` を明示送信」= Backend の default と同値なので無風。
          // Phase 5 で言語切替 UI が入ると ServiceL10n が追従するため、ここは
          // 追加対応なしで正しい locale を送り始める。
          options.headers['Accept-Language'] = ServiceL10n.current.localeName;

          // FEAT-188: 認証ヘッダーの自動付与
          // 通常トークンが存在すれば `Token <token>`、
          // 無ければゲストトークンがあるか確認し `GuestToken <token>` を付与する。
          // 両方とも無ければ無認証リクエスト（/auth/guest-init/ 等）。
          final userToken = await _storage.read(key: _tokenKey);
          if (userToken != null && userToken.isNotEmpty) {
            options.headers['Authorization'] = 'Token $userToken';
          } else {
            final guestToken = await _storage.read(key: _guestTokenKey);
            if (guestToken != null && guestToken.isNotEmpty) {
              options.headers['Authorization'] = 'GuestToken $guestToken';
            }
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          // 【FEAT-463】X-Maintenance: 1 header 検知 → maintenance overlay 起動。
          // 【Pre-mortem S2】循環参照対策: ApiClient は @riverpod 経由で Ref を
          // 直接保持しており (既存 onError の authProvider 読み取りと同じ設計)、
          // ここでの `_ref.read()` はビルド時の watch チェーンを作らない単発の
          // 読み取りのため、ProviderContainer への WeakReference 等の追加機構は
          // 不要 (既存 authProvider 連携と同じ安全なパターンを踏襲)。
          if (response.headers.value('x-maintenance') == '1') {
            _ref.read(maintenanceStatusProvider.notifier).markEnabledFromHeader();
          }
          // 【2026-07-07】5xx sentinel: 2xx 応答時はカウンタリセット。
          // Backend が復旧したら sentinel が再計測を新規に始められるようにする。
          final code = response.statusCode ?? 0;
          if (code >= 200 && code < 300) {
            _reset5xxCounter();
          }
          handler.next(response);
        },
        onError: (error, handler) async {
          // 【2026-07-07】5xx sentinel: 5xx を連続 3 回検知したら maintenance
          // overlay を自動発火する。timeout (connectionTimeout/receiveTimeout)
          // は 5xx とは別扱い = ローカルネットワーク障害を Backend 障害と混同しない。
          final code = error.response?.statusCode ?? 0;
          if (code >= 500 && code < 600) {
            _record5xx();
          }
          if (error.response?.statusCode == 401) {
            // FEAT-193: 401 ハンドリングを「通常ユーザーのセッション失効」だけに限定。
            //
            // 旧実装（FEAT-188）はゲスト時の 401 で deleteGuestToken() を呼んでいたが、
            // これは致命的バグだった:
            //   - ショップ等で一時的に 401 が返ると、それだけでゲストトークンを破棄
            //   - 結果ホームに戻った際に「習慣・ToDo・タイムラインが取得不能」状態に
            //   - 端末初期化と同等のデータロス（ゲストはサーバー連携前のため復旧不可）
            //
            // 新方針:
            //   - 通常ユーザートークンが付いていて 401: 期限切れとしてログアウト相当の処理
            //   - ゲストトークン or 無認証で 401: 個別 API のエラーとして上位に伝播するだけで、
            //     ローカルのゲストトークンは保持する。ゲストセッション全体の期限切れ判定は
            //     サーバー側のバッチ処理に任せ、フロントでは触らない。
            //
            // ゲストトークンを削除する経路は「明示的な操作」のときだけ:
            //   - 連携完了時の _verifyAndPromoteGuest()（FEAT-188 で実装済み）
            //   - 衝突確認後の confirmPromote()（FEAT-189 で実装済み）
            //   - 将来的なアカウント削除フロー
            final userToken = await _storage.read(key: _tokenKey);
            if (userToken != null && userToken.isNotEmpty) {
              await deleteToken();
              _ref.read(authProvider.notifier).markSessionExpired();
            }
            // else: ゲスト or 無認証時はトークン保持。エラーは handler.next で伝播。
          }
          handler.next(error);
        },
      ),
    );
  }

  Dio get dio => _dio;

  /// 【FEAT-476】DioCacheInterceptor を非同期で初期化して Dio に登録する。
  ///
  /// 対象 endpoint の service 側が CacheOptions.toOptions() を付与した GET のみ
  /// キャッシュされる (CachePolicy.request = opt-in 設計)。
  /// Auth interceptor より手前 (index 0) に挿入して cache hit 時は auth read をスキップ。
  ///
  /// テスト環境 / path_provider 未初期化時は MissingPluginException が throw されるため
  /// try-catch で吸収する。cache なしでも全機能は動作する (graceful degrade)。
  /// 【FEAT-489 Phase 2G-a】言語切替時に破棄するためのハンドル。
  /// interceptor 初期化前 / テスト環境では null (clearResponseCache が no-op になる)。
  CacheStore? _cacheStore;

  /// 【FEAT-489 Phase 2G-a / Phase 2E S6 の回収】応答キャッシュを全破棄する。
  ///
  /// FEAT-476 の `DioCacheInterceptor` は ja で取得した応答を保持しているため、
  /// **言語を切り替えても破棄しないと「切り替えたのに日本語のまま」になる**。
  /// Backend は `Vary: Accept-Language` を返しているが、dio 側がこれを解釈する
  /// 保証がないので、切替時にこちらから明示的に捨てる。
  Future<void> clearResponseCache() async {
    try {
      await _cacheStore?.clean();
    } catch (_) {
      // 破棄失敗は致命ではない (最悪 maxStale 7 日で自然に切れる)
    }
  }

  Future<void> _initCacheInterceptor() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final store = HiveCacheStore(dir.path, hiveBoxName: 'sabiowl_api_cache');
      _cacheStore = store;
      final options = CacheOptions(
        store: store,
        policy: CachePolicy.request,
        hitCacheOnErrorExcept: [401, 403],
        maxStale: const Duration(days: 7),
        priority: CachePriority.normal,
        allowPostMethod: false,
      );
      _dio.interceptors.insert(0, DioCacheInterceptor(options: options));
    } catch (_) {
      // テスト / path_provider 未初期化環境: cache interceptor をスキップ
    }
  }

  // ── 通常ユーザートークン ─────────────────────────────────────

  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(
      key: _tokenSavedAtKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  Future<void> deleteToken() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _tokenSavedAtKey);
    await _storage.delete(key: _tokenValidatedAtKey);
    // is_registered / has_seen_tutorial / guest_mode は削除しない
    // guest_mode は正式登録完了時のみ setGuestMode(false) で削除する
  }

  Future<String?> getToken() async {
    return _storage.read(key: _tokenKey);
  }

  // ── ゲストトークン（FEAT-188）──────────────────────────────────

  /// ゲストトークンを保存する（guest-init 成功時に呼ぶ）。
  Future<void> saveGuestToken(String token) async {
    await _storage.write(key: _guestTokenKey, value: token);
  }

  /// 保存されているゲストトークンを取得する。
  Future<String?> getGuestToken() async {
    return _storage.read(key: _guestTokenKey);
  }

  /// ゲストトークンを削除する（正式昇格成功時 / 失効検知時）。
  Future<void> deleteGuestToken() async {
    await _storage.delete(key: _guestTokenKey);
  }

  /// 登録済みかどうかを確認する
  Future<bool> isRegistered() async {
    final val = await _storage.read(key: _registeredKey);
    return val == 'true';
  }

  /// 登録済みフラグを保存する（初回認証成功時に呼ぶ）
  Future<void> markAsRegistered() async {
    await _storage.write(key: _registeredKey, value: 'true');
  }

  /// チュートリアルを表示済みか確認する
  Future<bool> hasTutorialBeenShown() async {
    final val = await _storage.read(key: _tutorialKey);
    return val == 'true';
  }

  /// チュートリアル表示済みフラグを保存する
  /// （ログアウト後も保持するため deleteToken() では削除しない）
  Future<void> markTutorialShown() async {
    await _storage.write(key: _tutorialKey, value: 'true');
  }

  // ── ゲストモード ─────────────────────────────────────────────

  /// ゲストモードかどうかを確認する
  Future<bool> isGuestMode() async {
    final val = await _storage.read(key: _guestModeKey);
    return val == 'true';
  }

  /// ゲストモードフラグを設定する（false 時はキーを削除）
  Future<void> setGuestMode(bool value) async {
    if (value) {
      await _storage.write(key: _guestModeKey, value: 'true');
    } else {
      await _storage.delete(key: _guestModeKey);
    }
  }

  // ── トークン検証キャッシュ ────────────────────────────────────

  /// トークン最終サーバー検証日時を取得する
  Future<DateTime?> getTokenValidatedAt() async {
    final val = await _storage.read(key: _tokenValidatedAtKey);
    return val != null ? DateTime.tryParse(val) : null;
  }

  /// トークン最終サーバー検証日時を現在時刻で更新する
  Future<void> updateTokenValidatedAt() async {
    await _storage.write(
      key: _tokenValidatedAtKey,
      value: DateTime.now().toIso8601String(),
    );
  }
}
