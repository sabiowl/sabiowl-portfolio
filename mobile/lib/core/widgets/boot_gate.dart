import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../providers/connection_error_provider.dart';
import '../providers/maintenance_provider.dart';
import '../providers/rate_limit_provider.dart';
import '../services/maintenance_service.dart';

/// 【2026-07-08 FEAT-483】起動時パラレルプローブによる Backend 健全性ゲート（非ブロッキング版）。
///
/// ## 責務
///
/// アプリ起動直後、通常 UI を描画しながら以下 2 経路の probe を並列実行し、
/// Backend の実際の健全性を判定する:
///
/// 1. `GET /api/health/` (Phase 3 強化版、DB + schema alignment チェック)
/// 2. `GET /api/maintenance/` (admin が設定した maintenance フラグ)
///
/// probe は fire-and-forget で実行され、完了時に `maintenanceStatusProvider` の
/// state を更新する。`MaintenanceOverlay`（main.dart 常時 mount）が変化を
/// watch して degraded 検知時に後乗せで overlay を表示する。
///
/// ## Case 判定 (2026-07-09 再設計)
///
/// | Case | probe 結果 | 発火先 provider | UI |
/// |------|-----------|-----------------|-----|
/// | A | maintenance.is_enabled=true (probe or header) | maintenanceStatusProvider | MaintenanceOverlay |
/// | B | health=200 + maintenance.is_enabled=false | (何もしない) | 通常 UI |
/// | C | health=5xx (明示的 non-2xx 応答) | connectionErrorProvider | ConnectionErrorOverlay |
/// | D | network error / 個別 probe timeout | connectionErrorProvider | ConnectionErrorOverlay |
/// | E | 全体 timeout (10s) | connectionErrorProvider | ConnectionErrorOverlay |
/// | F | health=429 (レート制限) | rateLimitProvider | RateLimitOverlay |
///
/// 【BUG-158 (2026-09-12) Case F 追加】**429 を C に混ぜてはならない。**
/// 429 はサーバが「今は多すぎる、あと N 秒待て」と答えている = **通信は
/// 生きている**。ConnectionErrorOverlay の「通信できませんでした」は
/// 事実と逆であり、しかもあの画面の「再試行」が `/health/` を叩くので
/// **脱出のためのボタンが枠をさらに消費していた**。
///
/// ## overlay の分離 (2026-07-09 制定、user 要望への対応)
///
/// **v1: 単一 MaintenanceOverlay 時代 (〜2026-07-08)**
/// - 5xx / network error / timeout どれも markEnabledFromHeader() → MaintenanceOverlay
/// - Backend cold-start / 遅い網 / セルラー handoff で false positive が頻発
///   (user 報告 2026-07-09、「メンテしていないのにメンテ画面が出る」)
///
/// **v2: 中間版 (2026-07-09 早朝)**
/// - timeout は isDegraded=false に変更、false positive は消えたが、
///   「Backend が真に downtime のとき何も出ない」状態に
///
/// **v3: 現行版 (2026-07-09 user 要望)**
/// - **admin 設定 maintenance (isEnabled=true)** と **通信接続 / サーバエラー** を別 overlay に分離
/// - Case A: MaintenanceOverlay (「システムに手当てをしております」、admin 意図の明示的通知)
/// - Case C/D/E: ConnectionErrorOverlay (「通信できませんでした」、mobile 側の推測)
/// - 両者は独立した provider (maintenanceStatusProvider / connectionErrorProvider) で管理
/// - UI 優先順位: MaintenanceOverlay > ConnectionErrorOverlay > 通常 UI
///   (main.dart で MaintenanceOverlay を ConnectionErrorOverlay の 1 段外側にラップ)
///
/// ## 3 層防御 (v3 でも維持)
///
/// 1. 予防: SQLite fallback default (local 事故防止)
/// 2. 起動時検知: BootGate probe (本 widget、Case A → maintenance / Case C/D/E → connection error)
/// 3. 運用中検知: ApiClient 5xx sentinel (連続 3 回で connection error 発火)
///
/// ## 設計方針（FEAT-483 非ブロッキング化、2026-07-08）
///
/// - **`build()` は常に `widget.child` を即返す**: probe の完了を待たない。
///   通常 UI が即座に描画され、起動コスト = 0 になる。
/// - **probe は fire-and-forget**: `addPostFrameCallback` で起動し、
///   `await` の結果で provider を更新するのみ。UI のブロッキングなし。
/// - **degraded 検知時の overlay は「後乗せ」**: `MaintenanceOverlay` が
///   `maintenanceStatusProvider.isEnabled` を watch し、true になった時点で
///   全画面 Stack に被さる（5xx sentinel と同じパターン）。
/// - **例外は全て吞み込む**: probe 失敗で UI を止めない (defense-in-depth)。
///
/// ## なぜ 5xx sentinel だけでは不十分か
///
/// `api_client.dart` の 5xx sentinel (30 秒スライディングウィンドウで 5xx 3 回検知)
/// との役割分担:
///
/// 1. **起動直後の即時検知**: sentinel の閾値は連続 3 回。BootGate は 1 リクエストで
///    即断できるため、user が最初の操作を試みる直後に overlay を表示できる。
/// 2. **schema drift 特有の検知**: `/api/health/` が `PlayerProfile.objects.first()`
///    を実行して能動的に ORM エラーを検知。sentinel は業務 API の失敗を受動的に集計。
/// 3. **多層防御**: 予防（SQLite fallback default）/ 起動時検知（BootGate）/
///    運用中検知（5xx sentinel）の 3 層。
class BootGate extends ConsumerStatefulWidget {
  const BootGate({super.key, required this.child});
  final Widget child;

  /// probe 全体の最大待機時間。この時間を超えたら probe 結果を諦めて通常 UI に進む。
  ///
  /// 【2026-07-09 緩和】旧 3s → 10s。Render Starter プランでも稀に cold-start
  /// (5-8 秒) が発生するため、3 秒 timeout は tight。10 秒なら通常条件でほぼ確実に
  /// 応答が返る。`Dio.receiveTimeout: 60s` より短くしつつ余裕を持たせている。
  /// この時間を超えて timeout が起きたときは Case D/E として
  /// `ConnectionErrorOverlay` が出る (`!health.isOk` の分岐)。
  ///
  /// 【FEAT-536 (2026-08-29) 訂正】旧記述は「通常 UI 継続 (overlay 発火せず)」
  /// だったが、それは v2 (2026-07-09 早朝) の挙動である。v3 で overlay を 2 種類に
  /// 分離したときに更新されなかった残骸で、**動作は正しい**。
  /// 真実値はクラス冒頭の Case 表 (D / E とも ConnectionErrorOverlay)。
  static const Duration probeTimeout = Duration(seconds: 10);

  /// 個別 probe (health / maintenance) の receiveTimeout。
  static const Duration singleProbeTimeout = Duration(seconds: 10);

  @override
  ConsumerState<BootGate> createState() => _BootGateState();
}

class _BootGateState extends ConsumerState<BootGate> {
  @override
  void initState() {
    super.initState();
    // 起動直後の 1 フレーム後に probe 開始 (ProviderScope の初期化を待つ)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ignore: discarded_futures — fire-and-forget、UI をブロックしない
      _runBootProbe();
    });
  }

  /// パラレルプローブ実行（fire-and-forget）。全体 timeout 内に完了しなければ諦める。
  Future<void> _runBootProbe() async {
    try {
      final apiClient = ref.read(apiClientProvider);
      final service = ref.read(maintenanceServiceProvider);

      // 並列 fire、Future.wait で両方の完了を待つ + 全体 timeout で強制打切
      final results = await Future.wait([
        _probeHealth(apiClient),
        _probeMaintenance(service),
      ]).timeout(
        BootGate.probeTimeout,
        onTimeout: () => <dynamic>[
          _HealthResult.timeout(),
          null,
        ],
      );

      if (!mounted) return;

      final health = results[0] as _HealthResult;
      final maintenance = results[1] as MaintenanceStatus?;

      // Case A: admin 設定 maintenance ON → MaintenanceOverlay 発火 (最優先)
      if (maintenance != null && maintenance.isEnabled) {
        ref.read(maintenanceStatusProvider.notifier).setStatusForBoot(maintenance);
      }
      // Case F: 429 (レート制限)。🔴 **Case C/D/E より先に判定すること。**
      // `!health.isOk` は 429 にも当たるので、順序を入れ替えると
      // 「通信できませんでした」に戻る = BUG-158 の症状そのものである。
      //
      // 🔴 429 は **サーバが応答している証拠**であり、通信障害ではない。
      // 待ち時間は `Retry-After` ヘッダから読む (DRF が必ず秒数で付ける)。
      else if (health.retryAfter != null) {
        ref.read(rateLimitProvider.notifier).mark(health.retryAfter!);
      }
      // Case C / D / E: /health/ が確定 5xx を返した OR timeout / network error で
      // Backend 到達不能 → ConnectionErrorOverlay 発火 (通信接続エラー / サーバエラー)。
      //
      // 【2026-07-09 再設計】user 要望に基づき:
      //   - maintenance ON: MaintenanceOverlay 表示 (admin 意図の明示的通知)
      //   - maintenance OFF (or 未確認): ConnectionErrorOverlay 表示
      //     (「通信接続エラー、またはサーバに一時的な問題」の別画面)
      //
      // 判定条件 `!health.isOk` は「確定 200 応答が得られなかった」= isDegraded
      // (確定 5xx) or timeout (状態不明) の両方をカバーする。
      // 「maintenance が明示的に OFF (isEnabled=false)」or「maintenance 未確認 (null)」
      // どちらも Case A の条件を通過しないため、ここで connection error が発火する。
      else if (!health.isOk) {
        ref.read(connectionErrorProvider.notifier).mark();
      }
      // Case B: 通常 UI のまま (何もしない、両 provider default off のまま)
    } catch (_) {
      // 例外は全て吞み込む (defense-in-depth)
    }
  }

  /// GET /api/health/ を短 timeout で叩き、200 かどうかを返す。
  ///
  /// 【FEAT-475 Phase 3】/api/health/ は AllowAny endpoint、認証不要。
  /// 【2026-07-07】DB + schema alignment チェック追加、503 で degraded 検知。
  ///
  /// 【BUG-147 Phase C (2026-08-20)】**`client.probeDio` を使う** (認証
  /// インターセプタ非経由)。旧実装は `client.dio` だったため全リクエスト共通の
  /// `onRequest` が認証ヘッダを付け、端末に古いトークンが残っていると
  /// `/health/` が 401 になって overlay が出続けた。しかも
  /// `validateStatus: (_) => true` のせいで Dio が 401 をエラー扱いせず、
  /// **Phase B の回復経路にも乗らない**という二重の袋小路だった。
  Future<_HealthResult> _probeHealth(ApiClient client) async {
    try {
      final response = await client.probeDio.get(
        '/health/',
        options: Options(
          receiveTimeout: BootGate.singleProbeTimeout,
          sendTimeout: BootGate.singleProbeTimeout,
          // 2xx / 5xx を全て正常応答扱いで受け取り、statusCode で判定する
          // (throw させず handler 側で分岐できるようにする)
          validateStatus: (_) => true,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code == 200) return _HealthResult.ok();
      // 【BUG-158】429 だけは degraded に混ぜない。
      // サーバは応答しているので「通信できませんでした」は事実と逆になる。
      if (code == 429) {
        return _HealthResult.rateLimited(
          parseRetryAfter(response.headers.value('retry-after')),
        );
      }
      // 503 も含めて 2xx 以外は degraded 扱い
      return _HealthResult.degraded(code);
    } catch (_) {
      // network error / timeout / DioException 全て degraded 扱い
      return _HealthResult.timeout();
    }
  }

  /// GET /api/maintenance/ を叩き、MaintenanceStatus を返す。
  ///
  /// 失敗時は null を返し、caller は「Case A ではない」と判定する。
  Future<MaintenanceStatus?> _probeMaintenance(MaintenanceService service) async {
    try {
      return await service.fetchStatus();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 非ブロッキング: probe 完了を待たず、常に通常 UI を即座に描画する。
    // degraded 検知時は MaintenanceOverlay が provider 変化を watch して後乗せ表示。
    return widget.child;
  }
}

/// health probe の結果を表す 3 状態値。
///
/// - `isOk=true`: 200 応答 (Backend 健全) → Case B、overlay なし
/// - `isDegraded=true`: 非-2xx の**確定応答** (5xx / 503 schema drift 等) → Case C
/// - **どちらも false (inconclusive)**: timeout / network error → Case D/E
///
/// 🔴 **分岐に効いているのは `isOk` だけ**。`!health.isOk` が Case C / D / E を
/// まとめて `ConnectionErrorOverlay` へ送るため、`isDegraded` と `statusCode` は
/// **現在どこからも読まれていない**。
///
/// 残しているのは、5xx (サーバは応答している) と timeout (そもそも届いていない) を
/// 将来べつ扱いにするときの識別子がここにしか無いため。読む側を足すときは、
/// **クラス冒頭の Case 表を先に更新すること**。
///
/// 【FEAT-536 (2026-08-29) 訂正】旧記述は inconclusive を「overlay 発火せず」と
/// 書いていたが、それは v2 (2026-07-09 早朝) の挙動。v3 で overlay を 2 種類に
/// 分離したときに更新されなかった残骸で、**動作は正しい**。
class _HealthResult {
  final bool isOk;
  final bool isDegraded;
  final int? statusCode;

  /// 【BUG-158 (2026-09-12)】429 のときだけ非 null。Case F の唯一の判定材料。
  ///
  /// 🔴 **`statusCode == 429` で判定しないこと。** `statusCode` は
  /// 上の docstring のとおり**どこからも読まれていない識別子**で、
  /// `timeout()` では null のまま残る。待ち時間を持っているかどうかを
  /// そのまま分岐条件にするほうが、状態と分岐がずれない。
  final Duration? retryAfter;

  const _HealthResult._({
    required this.isOk,
    required this.isDegraded,
    this.statusCode,
    this.retryAfter,
  });

  factory _HealthResult.ok() =>
      const _HealthResult._(isOk: true, isDegraded: false);
  factory _HealthResult.degraded(int code) =>
      _HealthResult._(isOk: false, isDegraded: true, statusCode: code);

  /// 【BUG-158】429。**`isDegraded` は false** —— サーバは正常に応答しており、
  /// Backend が壊れているわけではない。ConnectionErrorOverlay には送らない。
  factory _HealthResult.rateLimited(Duration retryAfter) => _HealthResult._(
        isOk: false,
        isDegraded: false,
        statusCode: 429,
        retryAfter: retryAfter,
      );
  /// 【2026-07-09 修正】旧 `isDegraded: true` → `false` に変更。
  /// タイムアウトは「Backend 状態が確定できない」= inconclusive。
  ///
  /// 【FEAT-536 (2026-08-29) 訂正】旧記述の「overlay 発火せず」は誤り。
  /// `isDegraded: false` にしたのは **MaintenanceOverlay を出さない**ためで、
  /// v3 以降は `!isOk` により `ConnectionErrorOverlay` が出る (Case D/E)。
  /// 参照先として書かれていた §「Case D/E で overlay を発火しない理由」という節は
  /// **存在しない** (v2 時代の節名)。真実値はクラス冒頭の Case 表。
  factory _HealthResult.timeout() =>
      const _HealthResult._(isOk: false, isDegraded: false);
}
