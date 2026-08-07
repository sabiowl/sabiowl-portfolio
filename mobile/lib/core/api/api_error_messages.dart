/// 【FEAT-515 Phase 2 (2026-08-04)】API エラー `code` → locale 別文言の解決。
///
/// ## 何を解いているか
///
/// Backend は user 向けのエラー文言を **日本語で** 返す。英語 UI のユーザーは
/// 「失敗したときだけ日本語を見る」状態だった:
///
/// ```
/// チケットが不足しています。少し時間をおいてお試しください 🪶
/// コインが足りないようですね 🪶
/// ```
///
/// Backend 側で locale 別 message を返す方式もあるが、v1.1 では
/// **Flutter 側で `code` から ARB を引く**方式を採る (indirection が 1 段で済み、
/// Backend の locale 解決経路 [I18nMiddleware] に依存しないため)。
///
/// ## 未知 code は server の message にフォールバックする
///
/// [localizedApiError] は知らない code に対して `null` を返し、
/// 呼び出し側 ([ApiError.localizedMessage]) が server の `message` を使う。
/// これにより **訳していない code はこれまで通り**動くので段階導入できる。
///
/// v1.1 の対象は下記 20 code (指示書 §3.2 を Phase 1 完了後に再選定したもの)。
/// 残り 128 件は v1.2 で全件対応か Backend 側 locale 解決かを再検討する
/// (`doc/design/backend_i18n.md`)。
///
/// ## ja も ARB から引く点に注意
///
/// 本層は locale を問わず ARB を引くので、**日本語表示も ARB の値になる**。
/// そのため ARB の ja は Backend の現行文言と 1 文字も違えてはいけない。
/// この同期は `backend/api/tests/test_error_code_l10n_sync.py` が縛っている。
library;

import '../../l10n/app_localizations.dart';

/// 本層が locale 解決する code の一覧。
///
/// テスト (`test/core/api_error_l10n_test.dart`) がこの列挙を使って
/// 「全 code が en / ja の両方で非空に解決されること」を検査する。
/// switch に case を足したらここにも足すこと (テストが漏れを落とす)。
const kLocalizedApiErrorCodes = <String>[
  // ── Shop ──────────────────────────────────────────────────────────────
  'shop_purchase_insufficient_coins',
  'shop_ticket_insufficient_coins',
  'shop_weapon_insufficient_coins',
  'shop_purchase_already_owned',
  'shop_weapon_already_owned',
  // ── Gacha ─────────────────────────────────────────────────────────────
  'gacha_pull_not_enough_tickets',
  'gacha_redo_insufficient_diamonds',
  // ── Battle ────────────────────────────────────────────────────────────
  'daily_battle_limit_reached',
  'not_enough_charges',
  'not_enough_potions',
  // ── Habit ─────────────────────────────────────────────────────────────
  'habit_create_duplicate_name',
  // ── 仮メモ ────────────────────────────────────────────────────────────
  'free_memo_text_required',
  'free_memo_text_too_long',
  'free_memo_not_archived',
  // ── Social ────────────────────────────────────────────────────────────
  'social_gift_already_sent_today',
  'social_gift_not_friend',
  // ── Achievement ───────────────────────────────────────────────────────
  'achievement_claim_already_claimed',
  'achievement_claim_not_unlocked',
  // ── Puzzle ────────────────────────────────────────────────────────────
  'puzzle_active_scene_already_completed',
  'puzzle_displayed_scene_not_available',
];

/// [code] に対応する locale 別文言を返す。**知らない code は `null`**。
///
/// [fields] は Backend の `error.fields`。数値やチケット種別のように
/// **文中に埋める値**はここから取る (prose ではなく machine-readable な
/// データを送る、が本 FEAT の方針)。
String? localizedApiError(
  AppLocalizations l,
  String code,
  Map<String, String> fields,
) {
  switch (code) {
    // ── Shop ──────────────────────────────────────────────────────────────
    case 'shop_purchase_insufficient_coins':
      return l.apiErrorShopPurchaseInsufficientCoinsSabi_message;
    case 'shop_ticket_insufficient_coins':
    case 'shop_weapon_insufficient_coins':
      // Backend の文言が同一なので 1 key に集約している
      return l.apiErrorShopInsufficientCoinsSabi_message;
    case 'shop_purchase_already_owned':
      return l.apiErrorShopAlreadyOwnedSabi_message;
    case 'shop_weapon_already_owned':
      return l.apiErrorShopWeaponAlreadyOwnedSabi_message;

    // ── Gacha ─────────────────────────────────────────────────────────────
    case 'gacha_pull_not_enough_tickets':
      // Backend の message は f'{name}チケットが…' で {name} が日本語の
      // チケット名だった。fields['ticket_type'] (machine-readable) から
      // ICU select で組み立てる。
      //
      // **欠けていたら種別を言わない汎用文 (other) に落とす**。
      // fields を返さない旧 Backend とアプリ更新が前後した瞬間に、
      // weekly を引いたのに「デイリーチケットが…」と誤った種別を
      // 出してしまうため、既定を daily にしてはいけない。
      return l.apiErrorGachaNotEnoughTicketsSabi_message(
        fields['ticket_type'] ?? '',
      );
    case 'gacha_redo_insufficient_diamonds':
      return l.apiErrorGachaRedoInsufficientDiamondsSabi_message(
        fields['required'] ?? '-',
        fields['owned'] ?? '-',
      );

    // ── Battle ────────────────────────────────────────────────────────────
    case 'daily_battle_limit_reached':
      return l.apiErrorBattleDailyLimitReachedSabi_message;
    case 'not_enough_charges':
      return l.apiErrorBattleNotEnoughChargesSabi_message;
    case 'not_enough_potions':
      return l.apiErrorBattleNotEnoughPotionsSabi_message;

    // ── Habit ─────────────────────────────────────────────────────────────
    case 'habit_create_duplicate_name':
      return l.apiErrorHabitDuplicateNameSabi_message;

    // ── 仮メモ ────────────────────────────────────────────────────────────
    case 'free_memo_text_required':
      return l.apiErrorFreeMemoTextRequiredSabi_message;
    case 'free_memo_text_too_long':
      return l.apiErrorFreeMemoTextTooLongSabi_message;
    case 'free_memo_not_archived':
      return l.apiErrorFreeMemoNotArchivedSabi_message;

    // ── Social ────────────────────────────────────────────────────────────
    case 'social_gift_already_sent_today':
      return l.apiErrorSocialGiftAlreadySentTodaySabi_message;
    case 'social_gift_not_friend':
      return l.apiErrorSocialGiftNotFriendSabi_message;

    // ── Achievement ───────────────────────────────────────────────────────
    case 'achievement_claim_already_claimed':
      return l.apiErrorAchievementAlreadyClaimedSabi_message;
    case 'achievement_claim_not_unlocked':
      return l.apiErrorAchievementNotUnlockedSabi_message;

    // ── Puzzle ────────────────────────────────────────────────────────────
    case 'puzzle_active_scene_already_completed':
      return l.apiErrorPuzzleSceneAlreadyCompletedSabi_message;
    case 'puzzle_displayed_scene_not_available':
      return l.apiErrorPuzzleSceneNotAvailableSabi_message;

    default:
      return null;
  }
}
