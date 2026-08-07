import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/api/api_client.dart';
import '../../../core/api/dio_error_helper.dart';  // 【2026-07-25】ApiError 経由でエラーメッセージ抽出
import '../../../l10n/app_localizations.dart';
import '../../habits/providers/habits_provider.dart';
import '../models/gamification_models.dart';
import '../services/gamification_service.dart';
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

part 'gamification_provider.g.dart';

// ── サービスプロバイダー ────────────────────────────────────
@riverpod
GamificationService gamificationService(Ref ref) {
  return GamificationService(ref.watch(apiClientProvider));
}

// ── ステータス ──────────────────────────────────────────────
@riverpod
class StatsNotifier extends _$StatsNotifier {
  bool _inFlight = false; // 多重送信防止フラグ

  @override
  Future<List<CharacterStat>> build() async {
    return ref.watch(gamificationServiceProvider).fetchStats();
  }

  /// ポイントを 1 割り振る。
  /// 多重送信中は `false` を返してスキップ。成功時は `true` を返す。
  Future<bool> allocate(int statId) async {
    if (_inFlight) return false;
    _inFlight = true;
    try {
      final svc = ref.read(gamificationServiceProvider);
      await svc.allocateStat(statId);
      // ポイント消費 → player も更新
      ref.invalidate(playerNotifierProvider);
      ref.invalidateSelf();
      return true;
    } finally {
      _inFlight = false;
    }
  }
}

// ── キャラクター ────────────────────────────────────────────
@riverpod
class CharactersNotifier extends _$CharactersNotifier {
  @override
  Future<List<Character>> build() async {
    return ref.watch(gamificationServiceProvider).fetchCharacters();
  }

  Future<void> select(int characterId) async {
    await ref.read(gamificationServiceProvider).selectCharacter(characterId);
    ref.invalidateSelf();
    // ホーム画面のアバターを即時反映するため PlayerProfile も更新する
    ref.invalidate(playerNotifierProvider);
  }

  /// 【FEAT-389 (2026-05-30)】未所持キャラをダイヤで購入する。
  ///
  /// 成功後は invalidateSelf で再フェッチ (owned=true 反映) +
  /// playerNotifierProvider invalidate でダイヤ残高を UI に即時反映。
  /// DioException は caller (_onTap) で catch してサビ口調 SnackBar を表示。
  Future<void> purchase(int characterId) async {
    await ref.read(gamificationServiceProvider).purchaseCharacter(characterId);
    ref.invalidateSelf();
    ref.invalidate(playerNotifierProvider);  // ダイヤ残高 UI 即時更新
  }

  /// 【FEAT-427 (2026-06-11)】キャラ交換券を 1 枚消費して未所持 SSR キャラを獲得する。
  ///
  /// 成功後は invalidateSelf で再フェッチ (owned=true 反映) +
  /// playerNotifierProvider invalidate で交換券残数を UI に即時反映。
  /// DioException は caller (_onTap) で catch してサビ口調 SnackBar を表示。
  Future<void> exchange(int characterId) async {
    await ref.read(gamificationServiceProvider).exchangeCharacter(characterId);
    ref.invalidateSelf();
    ref.invalidate(playerNotifierProvider);  // 交換券残数 UI 即時更新
  }
}

// ── ショップ ────────────────────────────────────────────────
class ShopState {
  final int coins;
  final List<ShopItem> items;
  const ShopState({required this.coins, required this.items});
}

@riverpod
class ShopNotifier extends _$ShopNotifier {
  @override
  Future<ShopState> build() async {
    final data = await ref.watch(gamificationServiceProvider).fetchShop();
    final coins = data['coins'] as int? ?? 0;
    final rawItems = data['items'] as List<dynamic>? ?? [];
    final items = rawItems
        .map((e) => ShopItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return ShopState(coins: coins, items: items);
  }

  /// 【FEAT-443 (2026-06-20)】持ち物リストからアイテムを売却する。
  ///
  /// 成功時: ShopState と playerNotifierProvider を invalidate して
  /// 在庫・コイン残高を即時反映、`coins_gained` を返す。
  /// 失敗時 DioException (装備中 / 所持なし / 売却不可) は rethrow し、
  /// caller 側で status code / error フィールドで切り分けて SnackBar 表示。
  Future<int> sellItem(String itemId) async {
    final result = await ref.read(gamificationServiceProvider).sellItem(itemId);
    ref.invalidateSelf();
    ref.invalidate(playerNotifierProvider);
    return result['coins_gained'] as int? ?? 0;
  }

  /// 購入を実行。成功時は null、失敗時は user 表示用のエラーメッセージ文字列を返す。
  ///
  /// 【2026-07-25】旧 `Future<bool>` を `Future<String?>` に変更。Backend の
  /// `{'error': 'デイリーチケットはこれ以上お持ちになれません 🪶'}` 等の詳細
  /// メッセージを caller (shop_page.dart の SnackBar) で表示可能にする。
  /// 失敗時は必ず non-null を返却 (Backend message 空 / 予期しない例外時は汎用文言)。
  Future<String?> purchase(String itemId, {AppLocalizations? l10n}) async {
    final genericFailureMessage =
        l10n?.gamifShopPurchaseFailedSabi_message ??
            ServiceL10n.current.gamifShopPurchaseFailedFallbackSabi_message;
    final prev = state;
    try {
      await ref.read(gamificationServiceProvider).purchaseItem(itemId);
      ref.invalidateSelf();
      // 【BUG-84 (2026-06-10)】ダイヤ / コイン残高 + アイテム在庫 (特に
      // streak_protection_count、rest_fruits 等の player フィールド) を
      // マイページ / ホーム HUD に即時反映するため明示 invalidate。同
      // ファイルの CharactersNotifier.purchase (line 70) / allocateStat
      // (line 38) で確立済の標準パターンに揃える。本行が抜けると「在庫が
      // 増えない」「ダイヤ残高が古いまま」とユーザーから見え、別の設定を
      // 触ったタイミングで間接的に invalidate されるまで反映が遅れる。
      ref.invalidate(playerNotifierProvider);
      return null;
    } on DioException catch (e) {
      // BUG-37: HTTP エラー（403 / 500 等）を可視化。
      // 旧 catch (_) はあらゆる例外を握り潰しており、購入失敗の原因が
      // デプロイ漏れ（403）なのかサーバエラー（500）なのか判別できなかった。
      // flutter run のコンソールでログを見て対処する。
      debugPrint('[ShopNotifier.purchase] DioException: '
          'status=${e.response?.statusCode} '
          'data=${e.response?.data}');
      state = prev;
      // 【2026-07-25】Backend の詳細メッセージを caller に返却。message 空時は汎用。
      // 【FEAT-515 Phase 2】`message` は Backend 組み立ての日本語なので、
      // localizedMessage 経由で code から ARB を引く (Shop の
      // insufficient_coins / already_owned はここを通る)。
      final apiError = ApiError.fromResponse(e.response?.data);
      return apiError.localizedMessage.isNotEmpty
          ? apiError.localizedMessage
          : genericFailureMessage;
    } catch (e, st) {
      // BUG-37: Dart レベルの予期しない例外（StateError 等）も同様に可視化する。
      debugPrint('[ShopNotifier.purchase] unexpected: $e\n$st');
      state = prev;
      return genericFailureMessage;
    }
  }

  /// 【FEAT-318 (2026-06-13 再活性化)】XP ブースト (xp_boost_1.5x) を使用する。
  ///
  /// 成功時: shop / player を invalidate して在庫・有効期限を即時反映し、
  /// レスポンス Map (active_until, remaining_quantity, boosted_duration_minutes)
  /// を返す。失敗時 DioException を rethrow し、caller (ダイアログ) で
  /// status code 400 (insufficient_stock) / 409 (already_active) を判別する。
  Future<Map<String, dynamic>> useXpBoost({int consumeValue = 1}) async {
    final result = await ref
        .read(gamificationServiceProvider)
        .useXpBoost(consumeValue: consumeValue);
    ref.invalidateSelf();
    ref.invalidate(playerNotifierProvider);
    return result;
  }
}

// ── ガチャ排出確率 (FEAT-518) ───────────────────────────────
// App Store Guideline 3.1.1 対応。プレイヤー状態に依存しない master data なので
// autoDispose の読み取り専用 provider で十分 (画面を閉じたら破棄)。
@riverpod
Future<GachaOdds> gachaOdds(Ref ref) async {
  return ref.watch(gamificationServiceProvider).fetchGachaOdds();
}

// ── ガチャ ──────────────────────────────────────────────────
@riverpod
class GachaNotifier extends _$GachaNotifier {
  // P1-05: 多重 pull 防止フラグ。
  // 呼び出し側 (gacha_page._pull) も bool _isPulling で守っているが、
  // クエスト報酬リダイレクト・フレンド画面遷移など別経路から pull() が
  // 呼ばれた場合の二重実行を防ぐため、サービス層自体にもガードを置く。
  bool _inFlight = false;

  @override
  Future<GachaStatus> build() async {
    return ref.watch(gamificationServiceProvider).fetchGachaStatus();
  }

  Future<GachaReward?> pull(String ticketType) async {
    // P1-05: 走行中なら何もせず null を返す。呼び出し側は null を「演出スキップ」
    // として扱う想定（gacha_page 側も _isPulling で同じ挙動）。
    if (_inFlight) return null;
    _inFlight = true;
    try {
      final data = await ref
          .read(gamificationServiceProvider)
          .pullGacha(ticketType);
      // BUG-P: ref.invalidate は呼び出し元（gacha_page._pull の _GachaSummonRoute.onCompleted）
      // に一本化する。
      // 旧実装はサーバー応答確定時点で player / gacha を即時 invalidate していたため、
      // 召喚演出開始前の 1 フレームで背景画面のチケット数 / EXP が「演出後の値」に
      // 切り替わり、ユーザーが Pop して戻る瞬間にチラ見えする違和感があった。
      final rewardJson = data['reward'] as Map<String, dynamic>?;
      if (rewardJson == null) return null;
      // 重複情報をマージしてから GachaReward を生成
      final merged = Map<String, dynamic>.from(rewardJson)
        ..['is_duplicate']      = data['is_duplicate']      as bool? ?? false
        ..['pending_reward_id'] = data['pending_reward_id'] as int?
        ..['character_exchange_ticket_awarded'] =
            data['character_exchange_ticket_awarded'] as bool? ?? false;
      // FEAT-200: ガチャ実行イベントをトラッキング。
      // - rarity: 'n' / 'r' / 'sr' / 'ssr'（マスター側のキー、API レスポンスの値そのまま）
      // - is_new_character: 重複でない場合のみ true（既存所持なら is_duplicate=true で識別可能）
      final rarity = rewardJson['rarity'];
      final isDuplicate = (data['is_duplicate'] as bool?) ?? false;
      await PosthogService.instance.capture('gacha_pulled', properties: {
        'ticket_type':       ticketType,
        if (rarity is String) 'rarity': rarity,
        'is_new_character':  !isDuplicate,
      });
      return GachaReward.fromJson(merged);
    } catch (_) {
      // BUG-O: 旧実装は catch (_) { return null; } で例外を握り潰し。
      // サーバ側で transaction.atomic 完了後にレスポンス送信が失敗した場合、
      // チケット消費・GachaHistory 作成・報酬付与は確定しているのに UI 上は
      // チケットが減っていない状態のまま「もう一度試そう」と案内し、
      // 体感バグ（再引きでチケット不足）が発生していた。
      //
      // 失敗時もサーバの真値で UI を同期し、呼び出し元（gacha_summon_page._handlePullError）
      // に「履歴を確認してね」を案内させるため rethrow する。
      ref.invalidate(playerNotifierProvider);
      ref.invalidateSelf();
      rethrow;
    } finally {
      // P1-05: 例外経路でも必ず解放する（ガード残留防止）
      _inFlight = false;
    }
  }
}

// 【廃止 (2026-06-26)】 titlesData provider は実績 30 件統合で撤去。
// 旧: Future<TitlesData> titlesData(Ref ref) → gamificationService.fetchTitles()
// 実績 (AchievementListView) で十分なバッジ収集要素を提供するため不要。
