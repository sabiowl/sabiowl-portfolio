// 【FEAT-328 (2026-05-27)】kDebugMode 参照は dev_level_reset 撤廃で不要に。
// import 'package:flutter/foundation.dart' は削除 (Material.dart 経由で取得可)。
import 'package:dio/dio.dart';  // 【FEAT-318】useXpBoost の 400/409 判別用
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/toast_center.dart';  // 【FEAT-434】返金通知
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/sabi_coming_soon.dart';  // FEAT-121
import '../../../shared/widgets/sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-218
import '../../battle/constants/battle_constants.dart';  // 【FEAT-523 Phase 3】maxBattleCharges
import '../constants/exchange_piece_constants.dart';  // 【FEAT-523 Phase 3】
import '../models/gamification_models.dart';
import '../providers/gamification_provider.dart';
import '../../habits/providers/habits_provider.dart'
    show playerNotifierProvider;              // EXP バー更新用

// ── タブ定義 ─────────────────────────────────────────────────────────────────

// 【BUG-91 (2026-06-11)】filter を Set<String>? に変更。「アイテム」タブで
// 複数 item_type (battle_consumable + streak_protection) を 1 つに集約するため。
// 【FEAT-489 Phase 2F-a】旧 `label` field を削除。TabBar は l10n.gamifShopTab* から
// 直接ラベルを組んでおり、この record の label は参照 0 件の日本語 hardcode だった。
typedef _Tab = ({Set<String>? filters});

// 【SEC-12】SHOP_CATALOG 16→4 縮減で「ギフト」「コスチューム」「部屋」タブが完全空になり
// dead UX を生むため、タブを「すべて / アイテム / チケット」3 つに整理。
// 【FEAT-424 (2026-06-10)】休息の果実廃止に伴い「アイテム」タブ（rest_day_consumable
// 専用だった）を撤去、再び dead UX 化するのを防止。
// 【BUG-91 (2026-06-11)】「アイテム」タブ復活。3 種の薬 (回復薬 / 上位回復薬 /
// 攻撃の薬 = item_type='battle_consumable') + ストリーク石 (item_type=
// 'streak_protection') の 4 アイテムが SHOP_CATALOG に存在しており、タブが
// 無いと「すべて」タブにしか出ず、用途別の探索ができない問題があった。
//
// - すべて       : 全カテゴリ
// - アイテム     : battle_consumable + streak_protection (3 薬 + ストリーク石)
// - チケット     : ticket_daily / weekly / monthly (consumable)
// - 装備         : weapon (FEAT-326 / FEAT-329)
//
// 将来、衣装機能の本体実装（active_character のアバター差し替え + アセット 20 枚）が
// 整った時点で「コスチューム」タブを復活させ、SHOP_CATALOG にも再追加できる設計。
const List<_Tab> _tabs = [
  (filters: null),
  // 【BUG-99 hotfix (2026-06-13)】gacha_only (XP ブースト) を「アイテム」タブに追加。
  // ガチャ報酬として PlayerItem 蓄積されるが SHOP_CATALOG 不在で「不可視」だった
  // (BUG-99)、xp_boost_1.5x entry 追加 + 本フィルターで持ち物リスト可視化。
  (filters: {'battle_consumable', 'streak_protection', 'gacha_only'}),
  (filters: {'consumable'}),
  // 【FEAT-329 (2026-05-27)】装備タブ追加。FEAT-326 で SHOP_CATALOG に追加した
  // bronze/iron/steel_sword (item_type='weapon') を「装備」カテゴリに集約表示。
  // ユーザー要望「ショップ画面の所持品リストに『装備』のタブを追加したい」採択。
  // 持ち物モード (FEAT-126) と組み合わせると、所持武器一覧として機能する
  // (PlayerWeapon の owned_quantity 反映は FEAT-327 で対応済)。
  (filters: {'weapon'}),
  // 【FEAT-497 (2026-08-04)】交換ピースタブ。
  // 重複ガチャで貯まる `exchange_pieces` の唯一の消費先。v1.0 は消費経路が
  // ゼロの dead currency だったため、タブごと存在しなかった。
  (filters: {'piece_exchange'}),
];

/// 【2026-08-07】ガチャチケット一覧に排出確率リンクを出すべきか。
///
/// ## なぜ関数に切り出しているか
///
/// App Store Guideline 3.1.1 の *prior to purchase* 開示を満たす条件そのもの
/// なので、**テストから直接呼べる形**にしてある。`_buildTabContent` の中に
/// インライン式で埋めると、テスト側が条件式を複製して検査することになり、
/// 実装から条件が消えても緑のまま通る (BUG-143 で実際に踏んだ)。
///
/// ## 判定をタブではなく表示中の item に置く理由
///
/// 「すべて」タブ (filters == null) にもチケットが並ぶ。タブ番号で判定すると
/// **そちらから買うユーザーが購入前に確率へ到達できなくなる**。
///
/// `itemType == 'consumable'` は SHOP_CATALOG 上ちょうどガチャチケット 2 種
/// (ticket_daily / ticket_weekly) を指す。他の消耗品は battle_consumable /
/// gacha_only / streak_protection に分かれている (実測)。
///
/// 持ち物モードでは出さない。チケットは購入即 `PlayerGachaStatus` に加算され
/// `PlayerItem` 在庫を持たないので実際には並ばないが、**購入の文脈ではない**
/// ことを条件として明示しておく。
bool shouldShowGachaOddsLink({
  required List<ShopItem> items,
  required bool isInventory,
}) {
  if (isInventory) return false;
  return items.any((i) => i.itemType == 'consumable');
}

// ── ShopPage ─────────────────────────────────────────────────────────────────

class ShopPage extends ConsumerStatefulWidget {
  const ShopPage({super.key, this.initialShowInventory = false});

  /// 【新規 (2026-07-05)】初期表示モード。default false = ショップ (購入) モード、
  /// true = 所持品リスト モード (FEAT-126 の _showInventory 初期値を上書き)。
  /// GuildDrawer から「所持品リスト」タップ経由で ?inventory=true を渡す用途。
  final bool initialShowInventory;

  @override
  ConsumerState<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends ConsumerState<ShopPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late bool _showInventory;  // FEAT-126、【2026-07-05】widget から初期値受取

  @override
  void initState() {
    super.initState();
    _showInventory = widget.initialShowInventory;
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shopAsync = ref.watch(shopNotifierProvider);
    // 【FEAT-412 (2026-06-01)】ダイヤボタン色制御用に所持ダイヤを watch。
    // ShopState に diamonds フィールドがないため、playerNotifierProvider 経由で取得。
    final playerAsync = ref.watch(playerNotifierProvider);
    final diamonds = playerAsync.valueOrNull?.diamonds ?? 0;
    // 【FEAT-497 (2026-08-04)】交換ピース。ピースタブのカードで活性判定に使う。
    final pieces = playerAsync.valueOrNull?.exchangePieces ?? 0;
    // 【FEAT-523 Phase 3】出陣チケットの上限判定用。piece_battle_charge のみで使う。
    final battleCharges = playerAsync.valueOrNull?.battleCharges ?? 0;
    final l10n = AppLocalizations.of(context)!;

    // 【FEAT-434 (2026-06-14)】migration 0136 によるレジェンダリー枠拡張の返金通知。
    // legendary_slots_purchase_count が 1+ → 0 へ変化したフレームで、ダイヤ増加分の
    // 返金があったことをサビ口調 SnackBar で知らせる (1 回限り)。
    ref.listen(playerNotifierProvider, (prev, next) {
      final prevPlayer = prev?.valueOrNull;
      final nextPlayer = next.valueOrNull;
      if (prevPlayer == null || nextPlayer == null) return;
      final wasRefunded = prevPlayer.legendarySlotsPurchaseCount > 0
          && nextPlayer.legendarySlotsPurchaseCount == 0
          && nextPlayer.diamonds > prevPlayer.diamonds;
      if (wasRefunded) {
        ToastCenter.showSuccess(l10n.gamifShopLegendaryRefundSabi_message);
      }
    });

    return Scaffold(
      appBar: AppBar(
        // 【FEAT-228】leading を指定しないことで AppBar が自動的に戻るボタン（←）を表示する。
        // SEC-12 で Shop は ShellRoute 外の独立ルート + context.push 遷移になったため、
        // Navigator スタックに前画面（ギルド / ステータス）が積まれており、自動的な
        // pop ナビゲーションが機能する。FEAT-126 で leading に置いていた持ち物トグルは
        // actions（右側）へ移動した。
        // FEAT-126: 絵文字付きタイトルでモードを視覚的に区別
        title: Text(_showInventory ? l10n.gamifShopTitleInventory : l10n.gamifShopTitleShop),
        // FEAT-126: 持ち物モードでは AppBar 背景色を変えてモードを強調
        backgroundColor: _showInventory
            ? Colors.teal.shade900
            : null,  // null = テーマデフォルト
        // 【FEAT-228】actions の構成:
        //   - ショップモード: コイン残高表示 / 持ち物トグル(backpack) / ガチャショートカット
        //   - 持ち物モード  : 持ち物トグル(store_outlined = ショップへ戻る) のみ
        //                    （FEAT-126 の「コイン・ガチャ非表示」UX を踏襲）
        actions: _showInventory
            ? [
                IconButton(
                  icon: const Icon(Icons.store_outlined),
                  tooltip: l10n.gamifShopBackToShopTooltip,
                  onPressed: () => setState(() => _showInventory = false),
                ),
              ]
            : [
                // 【FEAT-422 (2026-06-10)】AppBar 上部のコイン HUD を廃止。
                // 購入時の意思決定支援は確認ダイアログ内の「所持: N 🪙 / N 💎」
                // 1 行表示に統一 (ユーザー要望「上部 HUD は不要」採択)。
                // 上部 HUD があると「コインだけ表示・ダイヤは非表示」という
                // 通貨偏りの問題があった (ダイヤは playerNotifierProvider 経由
                // でロジック用にしか取得していない)。確認ダイアログでまとめて
                // 表示することで通貨混在アイテムの判断材料が一貫する。
                IconButton(
                  icon: const Icon(Icons.backpack_outlined),
                  tooltip: l10n.gamifShopInventoryTooltip,
                  onPressed: () => setState(() => _showInventory = true),
                ),
                // 【2026-08-07】排出確率への導線は AppBar から **チケットの一覧内**
                // へ移した (`_buildOddsLinkHeader`)。
                //
                // FEAT-518 は「ショップからも確率に到達できる」ことを
                // App Store Guideline 3.1.1 の要件として置いたが、指示書が指定した
                // 配置は「チケット購入セクションからのリンク」だった。実装は
                // AppBar のグローバルアイコンになっており、**装備タブでもピース
                // タブでも % が出る**状態だった (ユーザー報告 2026-08-07)。
                //
                // チケットが並んでいるときだけ出す形に変えても、課金経路
                // (ダイヤ → ticket_weekly → 抽選) の購入前開示は維持される。
                const _GachaShortcutButton(),
              ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: l10n.gamifShopTabAll),
            Tab(text: l10n.gamifShopTabItem),
            Tab(text: l10n.gamifShopTabTicket),
            Tab(text: l10n.gamifShopTabEquip),
            Tab(text: l10n.gamifShopTabPiece),  // 【FEAT-497】
          ],
        ),
      ),
      body: shopAsync.when(
        data: (shop) => Column(
          children: [
            // 【FEAT-328 (2026-05-27)】開発用ツールセクション (dev_level_reset)
            // はユーザー判断「利用予定がない」で撤廃済。kDebugMode 分岐ごと削除。
            // ── タブコンテンツ ─────────────────────────────────
            Expanded(
              child: TabBarView(
                controller: _tabController,
                // FEAT-126: 持ち物モードでは ownedQuantity > 0 のみ表示
                children: _tabs.map((tab) {
                  // 【BUG-91 (2026-06-11)】filter Set<String> ベースに変更、
                  // 「アイテム」タブで item_type 2 種 (battle_consumable +
                  // streak_protection) を 1 タブで集約するため。
                  var items = tab.filters == null
                      ? shop.items
                      : shop.items
                          .where((i) => tab.filters!.contains(i.itemType))
                          .toList();
                  if (_showInventory) {
                    items = items.where((i) => i.ownedQuantity > 0).toList();
                  } else {
                    // 【2026-06-14】Shop モードでは gacha_only (XPブースト等の
                    // 購入不可アイテム) を除外。所持品モードでは引き続き表示
                    // (= 持ち物を確認できる)。ユーザー要望「ショップ画面の購入
                    // リストから非表示にしたい、所持品リストには表示」採択。
                    //
                    // 【BUG-143 (2026-08-07)】`isPurchasable` を追加。
                    // Backend が所持品表示のために注入する catalog 外の武器
                    // (ミスリルの剣 / 竜殺しの剣 / 見習いの剣) は
                    // `item_type: 'weapon'` + 全価格 0 で来るため、
                    // gacha_only フィルタだけでは素通りし **0 コインで購入
                    // リストに並んでいた**。
                    //
                    // Backend (shop.py) はこのロジックが既に存在する前提で
                    // 書かれていたが、実際には無かった。ここで実装する。
                    items = items
                        .where((i) => i.itemType != 'gacha_only' && i.isPurchasable)
                        .toList();
                  }
                  return _buildTabContent(
                    context, ref, shop.coins, diamonds, pieces, battleCharges,
                    items, tab.filters,
                    isInventory: _showInventory,  // ← 追加パラメータ
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        loading: () => SabiWaitingPanel(message: l10n.gamifShopLoadingSabi_message),
        error: (_, __) => Center(
          child: Text(
            l10n.gamifShopErrorSabi_message,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent(
    BuildContext context,
    WidgetRef ref,
    int coins,
    int diamonds,  // 【FEAT-412 (2026-06-01)】ダイヤボタン色制御用
    int pieces,    // 【FEAT-497 (2026-08-04)】ピースボタン活性制御用
    int battleCharges,  // 【FEAT-523 Phase 3】出陣チケット上限判定用
    List<ShopItem> items,
    // 【BUG-91 (2026-06-11)】filter (単一 String?) → filters (Set<String>?)。
    // 本関数内では `filters != null` 判定でカテゴリタブの ComingSoon 表示分岐に
    // 使うのみのため、null check 経路は意味同じで安全に置換できる。
    Set<String>? filters, {
    bool isInventory = false,  // FEAT-126
  }) {
    final l10n = AppLocalizations.of(context)!;
    if (items.isEmpty) {
      // FEAT-126: 持ち物モードの空状態は専用メッセージ
      if (isInventory) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎒', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                l10n.gamifShopInventoryEmptySabi_message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                    height: 1.6),
              ),
            ],
          ),
        );
      }

      // FEAT-121: カテゴリタブの準備中表示は共通ウィジェットを使用
      // 【BUG-91 (2026-06-11)】filter → filters の Set<String>? 化に伴い変数名のみ更新。
      if (filters != null) return const SabiComingSoonWidget();

      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
            // SabiEmotion.pity (寄り添い) = 「品揃え準備中、もう少しお待ちを」の意味。
            const SabiIcon(emotion: SabiEmotion.pity, size: 52),
            const SizedBox(height: 12),
            Text(
              l10n.gamifShopEmptySabi_message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 14, height: 1.6),
            ),
          ],
        ),
      );
    }

    // 【FEAT-497 (2026-08-04)】ピースタブだけ残高ヘッダーを出す。
    //
    // 本 FEAT が解消しようとしている v1.0 の問題は「貯まるのに使い道が分からない」
    // だった。消費先を作っても **残高がどこにも見えない** なら印象は変わらない。
    // FEAT-422 で上部コイン HUD を撤去した経緯があるので全画面 HUD には戻さず、
    // ピースを使う画面の中だけに置く。
    final isPieceTab = filters != null && filters.contains('piece_exchange');

    final showOddsLink =
        shouldShowGachaOddsLink(items: items, isInventory: isInventory);

    final headers = <Widget>[
      if (isPieceTab && !isInventory)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              const Text('🧩', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Text(
                l10n.gamifShopPieceBalance(pieces),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              // 【FEAT-523 Phase 3】貯める動機として「あと N 個」を添える。
              // **重複ガチャの 2 択と同じ ARB キー**を使う (Pre-mortem #4)。
              // 片方だけ実装すると、選ぶ画面と貯める画面で表現が食い違う。
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  ExchangePieceConstants.remainingToTicket(pieces) == 0
                      ? l10n.gamifPieceReadyForTicketSabi_message
                      : l10n.gamifPieceProgressToTicket(
                          ExchangePieceConstants.remainingToTicket(pieces)),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (showOddsLink) _buildOddsLinkHeader(context, l10n),
    ];

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        16, 16, 16,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      itemCount: items.length + headers.length,
      itemBuilder: (_, index) {
        if (index < headers.length) return headers[index];
        final i = index - headers.length;
        return _ShopItemCard(
        item: items[i],
        coins: coins,
        diamonds: diamonds,  // 【FEAT-412】ダイヤボタン色制御用
        pieces: pieces,      // 【FEAT-497】ピースボタン活性制御用
        battleCharges: battleCharges,  // 【FEAT-523 Phase 3】上限時に非活性化
        // 【FEAT-443 (2026-06-20)】持ち物モードのタップ動線:
        //   - gacha_only (xp_boost_1.5x): 「使う」ダイアログ (既存 _buy 経路、§8.2)
        //   - その他 (武器 / 薬 / etc.): 詳細ポップアップ + 売却ボタン (新規)
        // ショップモードは従来通り購入確認ダイアログ。
        onBuy: () {
          final item = items[i];
          if (isInventory && item.itemType != 'gacha_only') {
            _showInventoryDetail(context, ref, item);
          } else {
            _buy(context, ref, item);
          }
        },
          isInventory: isInventory,  // FEAT-126: カード表示切替のため渡す
        );
      },
    );
  }

  /// 【2026-08-07】ガチャチケット一覧の先頭に置く「排出確率」への導線。
  ///
  /// ## なぜチケットの一覧内なのか
  ///
  /// App Store Guideline 3.1.1 は *prior to purchase* の開示を要求する
  /// (FEAT-518)。Sabiowl では **実通貨 → ダイヤ → `ticket_weekly` (💎150) →
  /// 重み付き抽選** の経路が成立しているため、チケットを買う画面に導線が要る。
  ///
  /// 元の実装は AppBar のグローバルアイコンで、装備タブでもピースタブでも
  /// `%` が出ていた。FEAT-518 の指示書が指定していた配置は
  /// 「チケット購入セクションからのリンク」であり、本実装がそれに合わせたもの。
  ///
  /// ## 文言に新しい ARB キーを足していない
  ///
  /// ラベルは既存の `gachaOddsTitle` (排出確率 / Drop Rates) を再利用する。
  /// FEAT-489 の英文レビューを通っている文字列なので、新規に英語コピーを
  /// 書き起こすより安全 (6,700 語に 344 件の修正が必要だった実績がある)。
  Widget _buildOddsLinkHeader(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => context.push(AppRoutes.gachaOdds),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.percent,
                  size: 16, color: Colors.white.withValues(alpha: 0.70)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.gachaOddsTitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.80),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 18, color: Colors.white.withValues(alpha: 0.45)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _buy(
      BuildContext context, WidgetRef ref, ShopItem item) async {
    // 【BUG-99 hotfix (2026-06-13) → FEAT-318 再活性化】ガチャ専用 entry
    // (xp_boost_1.5x 等) は購入ダイアログを開かない。
    // 持ち物モードで xp_boost_1.5x がタップされた場合は「使う」ダイアログを開く
    // (FEAT-318 §8.2)。Shop モードや他の gacha_only アイテムは従来通り
    // サビ口調の hint SnackBar を返す。
    if (item.itemType == 'gacha_only') {
      if (_showInventory && item.id == 'xp_boost_1.5x') {
        await _showUseXpBoostDialog(context, ref, item);
        return;
      }
      final l10nSnack = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10nSnack.gamifShopGachaOnlyHintSabi_message),
        ),
      );
      return;
    }
    // 【FEAT-412 (2026-06-01)】確認ダイアログでも所持ダイヤ判定で動的色化。
    final currentDiamonds = ref.read(playerNotifierProvider).valueOrNull?.diamonds ?? 0;
    // 【FEAT-422 (2026-06-10)】AppBar 上部コイン HUD 廃止に伴い、確認ダイアログで
    // 所持コイン / 所持ダイヤを 1 行で常時表示するため shopState から coins を取得。
    final currentCoins = ref.read(shopNotifierProvider).valueOrNull?.coins ?? 0;
    final canAffordDiamond = currentDiamonds >= item.diamondPrice;
    // 【FEAT-497 (2026-08-04)】交換ピース。3 つ目の通貨なので、
    // 残高表示 / 購入ボタンの活性判定 / ボタン文言の 3 箇所すべてで分岐する。
    final currentPieces =
        ref.read(playerNotifierProvider).valueOrNull?.exchangePieces ?? 0;
    final canAffordPiece = currentPieces >= item.piecePrice;
    // 【FEAT-422 hotfix (2026-06-10)】価格 Row 撤去 + 購入ボタン ElevatedButton 化
    // (BUG-86) で diamondColor の参照箇所がすべて消滅したため未使用変数を削除。
    // ダイヤ不足の視覚警告は購入ボタンの disabled (半透明) + 所持行で表現される。
    final l10nBuy = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10nBuy.gamifShopPurchaseDialogTitle(item.emoji, item.name),
            style: const TextStyle(color: Colors.white)),
        // 【FEAT-413 (2026-06-01) → BUG-86 (2026-06-10)】縦並び大型ボタンは維持しつつ、
        // 上下を入れ替えて iOS HIG / Material 標準のメンタルモデル優先パターンに変更。
        // FEAT-413 当初は「誤タップ防止」優先で「やめる」を上に置く reverse パターンを
        // 採用したが、ユーザー報告「やめるボタンが下の方が自然」(2026-06-10) で直感との
        // 齟齬が判明し、業界標準パターンに揃え直した。
        // 設計:
        //   - 「購入する」を上 (主アクション ElevatedButton AppTheme.primary 系) で
        //     メンタルモデル整合 (主要アクション=上)、価格併記で最終確認シグナル
        //   - 「やめる」を下 (控えめ OutlinedButton) でキャンセル位置 = 標準
        //   - 物理距離 8px の縦並び自体は維持 (Material actions 横並び 8px の
        //     誤タップリスク減対策は機能継続)
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.effect,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 12),
            // 【FEAT-422 hotfix (2026-06-10)】価格 Row (「💎 N ダイヤ」「N コイン」)
            // を削除。購入ボタンに「N コインで購入する」「N で購入する」と価格が
            // 併記されているため重複表示だった。ダイヤ不足警告 (FEAT-412) は
            // 購入ボタンの disabled 状態 (= 押下不能 + 半透明) + 所持行で間接的に
            // ユーザーが認識可能なため、ここから撤去しても判断に支障なし。
            // 【FEAT-422 (2026-06-10)】上部 HUD 廃止に伴う代替表示。
            // 所持コイン + 所持ダイヤを 1 行で常時表示し、通貨混在アイテムでも
            // 意思決定材料を確認ダイアログ内で完結させる。価格 Row の真下に
            // 配置することで、購入ボタン押下前の最終確認シグナルになる。
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  l10nBuy.gamifShopOwnedLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.50),
                    fontSize: 11,
                  ),
                ),
                const Icon(Icons.monetization_on,
                    size: 13, color: AppTheme.gold),
                const SizedBox(width: 2),
                Text(
                  '$currentCoins',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                const Text('💎', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 2),
                Text(
                  '$currentDiamonds',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // 【FEAT-497】ピース残高はピース商品のときだけ出す。
                // 常時 3 通貨並べるとコイン / ダイヤ商品の判断材料が薄まるため。
                if (item.isPieceExchange) ...[
                  const SizedBox(width: 10),
                  const Text('🧩', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 2),
                  Text(
                    '$currentPieces',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 20),
            // ── 購入する (上、主アクション、価格併記で最終確認) ──────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                // 不足時は disabled (既存 _ShopItemCard で阻止済だが防御的)
                onPressed: (item.diamondPrice > 0 && !canAffordDiamond) ||
                        (item.isPieceExchange && !canAffordPiece)
                    ? null
                    : () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppTheme.primary.withValues(alpha: 0.3),
                  disabledForegroundColor: Colors.white60,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.isPieceExchange
                          ? '🧩'
                          : item.diamondPrice > 0
                              ? '💎'
                              : '🪙',
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      item.isPieceExchange
                          ? l10nBuy.gamifShopBuyWithPieceButton(item.piecePrice)
                          : item.diamondPrice > 0
                              ? l10nBuy.gamifShopBuyWithDiamondButton(item.diamondPrice)
                              : l10nBuy.gamifShopBuyWithCoinButton(item.price),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // ── やめる (下、控えめ、キャンセル標準位置) ──────────
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.30)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(l10nBuy.gamifShopCancelButton,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirm == true && context.mounted) {
      // 【2026-07-25】purchase() が Future<String?> に変更。null=成功、非 null=エラーメッセージ。
      // Backend の詳細エラー (「デイリーチケットはこれ以上お持ちになれません 🪶」等) を
      // そのまま SnackBar で表示。旧汎用「購入がうまくいきませんでした」は fallback のみ。
      final l10nBefore = AppLocalizations.of(context)!;
      final errorMessage =
          await ref.read(shopNotifierProvider.notifier).purchase(item.id, l10n: l10nBefore);
      if (!context.mounted) return;

      final ok = errorMessage == null;

      // 【SEC-12】チケット交換購入時はガチャ画面の枚数表示・ショートカットバッジを即時更新。
      // `_GachaShortcutButton` も watch しているため、invalidate で同期される。
      if (ok && (item.id == 'ticket_daily' ||
                  item.id == 'ticket_weekly' ||
                  item.id == 'ticket_monthly')) {
        ref.invalidate(gachaNotifierProvider);
      }

      final l10nAfter = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? (item.id.startsWith('ticket_')
                  ? l10nAfter.gamifShopTicketPurchaseToast(item.name)
                  : l10nAfter.gamifShopItemPurchaseToast(item.name))
              // 【2026-07-25】Backend 詳細メッセージを表示。ok=false 時は errorMessage が
              // 必ず non-null (Notifier が失敗時は必ず non-null 返却)。
              : errorMessage),
          backgroundColor: ok ? Colors.green : Colors.red,
        ),
      );
    }
  }

  /// 【FEAT-443 (2026-06-20)】持ち物リストでアイテムをタップした時の詳細ポップアップ。
  ///
  /// 表示内容: emoji + 名前 + レアリティラベル + 効果 + 所持数 + 売却価格 (or 売却不可)
  /// ボタン: 閉じる + 売却する (売却可能時のみ activate)
  ///
  /// 売却ルール (Backend `_calc_sell_price_coins` が単一真実値):
  ///   - Mobile は `item.sellPrice` (レスポンスの `sell_price`) を単純参照。
  ///   - `sellPrice > 0` で売却可、0 で売却不可 (ダイヤ購入 / gacha_only /
  ///     slot_expansion / streak_protection / consumable / 旧 Backend fallback)。
  ///   - 武器装備中: Backend で 400 拒否 → SnackBar でユーザーに通知。
  ///
  /// 【codebase_review 20260704 P3-#8 (2026-07-05)】旧実装 (`item.price ~/ 2` +
  /// _NON_SELLABLE_ITEM_TYPES 独自リスト) は Backend `_calc_sell_price_coins` と
  /// drift するリスクがあった (レビュー継続 P3) ため単一真実値に統一。
  /// ダイヤ購入か否かの表示分岐 (isDiamondItem) は UI 文言のみで残す。
  Future<void> _showInventoryDetail(
      BuildContext context, WidgetRef ref, ShopItem item) async {
    // 売却価格 / 可否は Backend が計算した値を単純参照。
    final sellPrice = item.sellPrice;
    final canSell = sellPrice > 0;
    // 「ダイヤで購入した」文言分岐のみ Mobile 側で判定 (UI 文脈のため OK)。
    final isDiamondItem = item.diamondPrice > 0;

    final l10nDetail = AppLocalizations.of(context)!;
    final shouldSell = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Row(
          children: [
            Text(item.emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(item.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  )),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.effect,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(l10nDetail.gamifShopOwnedLabel,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                Text(l10nDetail.gamifShopInventoryItemCount(item.ownedQuantity),
                    style: const TextStyle(
                      color: Colors.tealAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    )),
              ],
            ),
            const SizedBox(height: 6),
            if (canSell)
              Row(
                children: [
                  Text(l10nDetail.gamifShopSellPriceLabel,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  const Icon(Icons.monetization_on,
                      color: AppTheme.gold, size: 14),
                  const SizedBox(width: 2),
                  Text('$sellPrice',
                      style: const TextStyle(
                        color: AppTheme.gold,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      )),
                ],
              )
            else
              Text(
                isDiamondItem
                    ? l10nDetail.gamifShopNoDiamondSellSabi_message
                    : l10nDetail.gamifShopNoSellSabi_message,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
          ],
        ),
        // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の新ルール準拠。
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10nDetail.gamifShopCloseButton,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: canSell ? () => Navigator.pop(ctx, true) : null,
            style: TextButton.styleFrom(
              foregroundColor: canSell ? Colors.orange : Colors.white24,
            ),
            child: Text(l10nDetail.gamifShopSellButton),
          ),
        ],
      ),
    );

    if (shouldSell != true || !context.mounted) return;

    // 売却実行
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      final coinsGained = await ref
          .read(shopNotifierProvider.notifier)
          .sellItem(item.id);
      if (!context.mounted) return;
      final l10nSell = AppLocalizations.of(context)!;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10nSell.gamifShopSellSuccessToastSabi_message(item.name, coinsGained)),
          backgroundColor: Colors.green,
        ),
      );
    } on DioException catch (e) {
      if (!context.mounted) return;
      final l10nSell = AppLocalizations.of(context)!;
      final message = (e.response?.data as Map?)?['message'] as String? ??
          l10nSell.gamifShopSellErrorSabi_message;
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!context.mounted) return;
      final l10nSell = AppLocalizations.of(context)!;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10nSell.gamifShopSellErrorSabi_message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// 【FEAT-318 (2026-06-13 再活性化)】XP ブースト (xp_boost_1.5x) 使用ダイアログ。
  /// 持ち物モードで xp_boost_1.5x をタップした際に表示する (§8.2)。
  Future<void> _showUseXpBoostDialog(
      BuildContext context, WidgetRef ref, ShopItem item) async {
    final player = ref.read(playerNotifierProvider).valueOrNull;
    final isActive = player?.isXpBoostActive ?? false;
    final remaining = player?.xpBoostRemaining ?? Duration.zero;
    // 【BUG-116 (2026-06-14)】効果時間を 24h → 15min に変更 (PM 指示)。
    final remainingMinutes = remaining.inSeconds == 0
        ? 0
        : (remaining.inSeconds / 60).ceil();

    final l10nBoost = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('${item.emoji} ${item.name}',
            style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10nBoost.gamifShopItemOwnedCount(item.ownedQuantity),
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 8),
            if (isActive)
              Text(
                l10nBoost.gamifShopBoostActiveSabi_message(remainingMinutes),
                style: TextStyle(
                  color: Colors.orangeAccent.withValues(alpha: 0.9),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              )
            else
              Text(
                l10nBoost.gamifShopBoostDescriptionSabi_message,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isActive ? null : () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppTheme.primary.withValues(alpha: 0.3),
                  disabledForegroundColor: Colors.white60,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(l10nBoost.gamifShopUseButton,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.30)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(l10nBoost.gamifShopCancelButton,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirm != true || !context.mounted) return;

    try {
      final result =
          await ref.read(shopNotifierProvider.notifier).useXpBoost();
      if (!context.mounted) return;
      // 【BUG-116 (2026-06-14)】API key 変更: boosted_duration_hours →
      // boosted_duration_minutes (24h → 15min/stock)。
      final minutes = result['boosted_duration_minutes'] as int? ?? 15;
      final l10nAfterBoost = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10nAfterBoost.gamifShopBoostSuccessToastSabi_message(minutes)),
          backgroundColor: Colors.green,
        ),
      );
    } on DioException catch (e) {
      if (!context.mounted) return;
      final l10nErr = AppLocalizations.of(context)!;
      final message = (e.response?.data as Map?)?['message'] as String? ??
          l10nErr.gamifShopUseErrorSabi_message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }
}

// ── ガチャ誘導ショートカットボタン（AppBar actions 用）─────────────────────

class _GachaShortcutButton extends ConsumerStatefulWidget {
  const _GachaShortcutButton();

  @override
  ConsumerState<_GachaShortcutButton> createState() =>
      _GachaShortcutButtonState();
}

class _GachaShortcutButtonState extends ConsumerState<_GachaShortcutButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gachaAsync = ref.watch(gachaNotifierProvider);
    final totalTickets = gachaAsync.whenOrNull(
          data: (s) =>
              s.dailyTickets + s.weeklyTickets + s.monthlyTickets,
        ) ??
        0;

    // チケット保有時はパルスアニメーション、0枚時は停止
    if (totalTickets > 0 && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (totalTickets == 0 && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    final hasTickets = totalTickets > 0;
    final color = hasTickets ? AppTheme.primary : Colors.white38;
    final badgeText = totalTickets > 9 ? '9+' : '$totalTickets';

    return GestureDetector(
      onTap: () => context.push(AppRoutes.gacha),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
        child: ScaleTransition(
          scale: hasTickets ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // アイコン + ラベル
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, color: color, size: 22),
                  const SizedBox(height: 1),
                  Text(
                    AppLocalizations.of(context)!.gamifGachaPageTitle,
                    style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight:
                          hasTickets ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
              // チケット枚数バッジ
              if (hasTickets)
                Positioned(
                  top: -4,
                  right: -10,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B6B),
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: AppTheme.surface, width: 1.5),
                    ),
                    child: Center(
                      child: Text(
                        badgeText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// 【FEAT-328 (2026-05-27)】_DevToolsSection + _DevResetButton 撤去。
// ユーザー判断「dev_level_reset 利用予定なし」で dead code 整理。
// 旧実装: kDebugMode 限定で「レベル初期化」ボタン (赤い枠 + 確認ダイアログ +
// 成功時 player/statsNotifier invalidate) を表示していた。
// 代替: Lv リセットが必要な場合は Django shell から手動対応
// (player.level=1; player.current_exp=0; player.save())。

// ── ShopItemCard ─────────────────────────────────────────────────────────────

class _ShopItemCard extends StatelessWidget {
  final ShopItem item;
  final int coins;
  final int diamonds;  // 【FEAT-412 (2026-06-01)】所持ダイヤ数
  final int pieces;    // 【FEAT-497 (2026-08-04)】所持交換ピース
  /// 【FEAT-523 Phase 3】所持出陣チケット。`piece_battle_charge` の上限判定にのみ使う。
  final int battleCharges;
  final VoidCallback onBuy;
  final bool isInventory;  // FEAT-126
  const _ShopItemCard({
    required this.item,
    required this.coins,
    required this.diamonds,
    required this.pieces,
    required this.battleCharges,
    required this.onBuy,
    this.isInventory = false,  // FEAT-126
  });

  /// 【FEAT-412 (2026-06-01)】ダイヤ消費アイテムの「足りる時」色。
  /// FEAT-384 ATB バー水色と統一、Sabiowl 内既存色で UI 統一感維持。
  static const Color _diamondAffordColor = Color(0xFF4FC3F7);

  /// 【FEAT-497 (2026-08-04)】交換ピース消費アイテムの「足りる時」色。
  /// コイン (gold) / ダイヤ (水色) と区別がつく緑系にする。
  static const Color _pieceAffordColor = Color(0xFF66BB6A);

  /// 【FEAT-523 Phase 3】`piece_battle_charge` 1 回の付与枚数。
  /// 真実値は `backend/api/views/shop.py` の `_BATTLE_CHARGE_AMOUNT`。
  /// 上限判定 (`current + 5 > 30`) を再現するためだけに写している。
  static const int _battleChargeGrantAmount = 5;

  static const _rarityColors = {
    1: Colors.white54,
    2: Colors.blue,
    3: Colors.purple,
  };

  @override
  Widget build(BuildContext context) {
    final rarityColor = _rarityColors[item.rarity] ?? Colors.white54;
    final canAfford = coins >= item.price;

    final card = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: rarityColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Text(item.emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 【FEAT-298 hotfix 2026-05-25】Row 内のアイテム名が長文の場合、
                // 制約幅 182.7 px を超過して overflow していた（例: 回復薬 +
                // レアリティラベル「コンシューマブル」等で 15 px はみ出し）。
                // アイテム名を Flexible + ellipsis でラップして、長文時は省略表示。
                // レアリティラベル（短い）は右側に確実保持する優先順位設計。
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: rarityColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: rarityColor.withValues(alpha: 0.4)),
                      ),
                      child: Text(item.rarityLabel,
                          style:
                              TextStyle(color: rarityColor, fontSize: 10)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(item.effect,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 11)),
                if (item.ownedQuantity > 0)
                  Text('${AppLocalizations.of(context)!.gamifShopOwnedLabel}${item.ownedQuantity}',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 10)),
                // 【FEAT-429 (2026-06-12)】累進価格アイテム (legendary_slot_expand /
                // daily_quest_slot_expand) の累計購入回数表示。
                if (item.purchaseCount != null && item.maxPurchaseCount != null)
                  Text(AppLocalizations.of(context)!.gamifShopEquipPurchaseCount(item.purchaseCount!, item.maxPurchaseCount!),
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 10)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // FEAT-126: 持ち物モードでは所持数を表示
          if (isInventory)
            Text(
              AppLocalizations.of(context)!.gamifShopEquipOwnedWithUnit(item.ownedQuantity),
              style: const TextStyle(
                color: Colors.tealAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            )
          // 【FEAT-497 (2026-08-04)】交換ピース消費アイテムは 🧩 ボタン。
          // **ダイヤ判定より前**に置く。piece entry は diamondPrice=0 なので
          // 後ろに置くとコイン経路の「🪙 0」ボタンとして描画されてしまう
          // (Backend 側の分岐順序と同じ罠)。
          else if (item.isPieceExchange)
            Builder(builder: (_) {
              // 【FEAT-523 Phase 3 §3.2】ピースが足りていても、出陣チケットが
              // 上限に張り付いていたら Backend は必ず断る
              // (`shop.py` の `current + 5 > 30` → `shop_piece_battle_charge_max`)。
              // クライアントがこの条件を見ていなかったため、チケットを 26 枚以上
              // 持っていると **ボタンが活性で表示され、押して初めて断られる**状態
              // だった。`battle_charges` は習慣達成で自然に貯まるので、
              // **よく遊ぶユーザーほどこの状態に入る**。
              //
              // 対象は `piece_battle_charge` のカードのみ。`piece_xp_boost` /
              // `piece_character_ticket` には上限が無い。
              final atChargeCap = item.id == 'piece_battle_charge' &&
                  battleCharges + _battleChargeGrantAmount >
                      BattleConstants.maxBattleCharges;
              final canAffordPiece = pieces >= item.piecePrice && !atChargeCap;
              final color =
                  canAffordPiece ? _pieceAffordColor : Colors.redAccent;
              return ElevatedButton(
                onPressed: canAffordPiece ? onBuy : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: color.withValues(alpha: 0.15),
                  foregroundColor: color,
                  side: BorderSide(color: color, width: 1),
                  disabledBackgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                  disabledForegroundColor: Colors.redAccent.withValues(alpha: 0.6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🧩', style: TextStyle(fontSize: 11)),
                    const SizedBox(width: 3),
                    Text('${item.piecePrice}'),
                  ],
                ),
              );
            })
          // FEAT-129: ダイヤ消費アイテムは 💎 ボタンを表示
          // 【FEAT-412 (2026-06-01)】所持ダイヤ判定で動的色切替 + 不足時 disabled。
          // ユーザー報告「赤枠だと足りないように見える」採択。
          // - 足りる時 (canAffordDiamond=true): 青系 (#4FC3F7、FEAT-384 既存水色)、タップ可能
          // - 足りない時 (canAffordDiamond=false): 赤系 (Colors.redAccent)、disabled
          // 旧実装 AppTheme.secondary (#FF6584 薄赤ピンク) が「不足シグナル」と
          // 誤読される認知ノイズを構造解消。
          else if (item.diamondPrice > 0)
            Builder(builder: (_) {
              // 【FEAT-429 (2026-06-12)】累進価格アイテムが上限購入回数に達した場合、
              // 「上限到達」表示でボタンを無効化する。
              final atMax = item.purchaseCount != null &&
                  item.maxPurchaseCount != null &&
                  item.purchaseCount! >= item.maxPurchaseCount!;
              final canAffordDiamond = diamonds >= item.diamondPrice;
              final color = canAffordDiamond ? _diamondAffordColor : Colors.redAccent;
              return ElevatedButton(
                onPressed: (atMax || !canAffordDiamond) ? null : onBuy,
                style: ElevatedButton.styleFrom(
                  backgroundColor: color.withValues(alpha: 0.15),
                  foregroundColor: color,
                  side: BorderSide(color: color, width: 1),
                  disabledBackgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                  disabledForegroundColor: Colors.redAccent.withValues(alpha: 0.6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                child: atMax
                    ? Text(AppLocalizations.of(context)!.gamifShopEquipMaxLimitLabel)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('💎', style: TextStyle(fontSize: 11)),
                          const SizedBox(width: 3),
                          Text('${item.diamondPrice}'),
                        ],
                      ),
              );
            })
          else
            ElevatedButton(
              onPressed: canAfford ? onBuy : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.gold,
                foregroundColor: Colors.black,
                disabledBackgroundColor:
                    Colors.white.withValues(alpha: 0.1),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.monetization_on, size: 12),
                  const SizedBox(width: 2),
                  Text('${item.price}'),
                ],
              ),
            ),
        ],
      ),
    );

    // 【FEAT-318 hotfix (2026-06-13)】持ち物モードの gacha_only アイテム
    // (xp_boost_1.5x 等) はカードに「使う」ボタンがなく所持数 Text のみのため、
    // カード全体タップで onBuy (= _showUseXpBoostDialog) を起動できるようにする。
    //
    // 【FEAT-443 (2026-06-20)】持ち物モードの全アイテムをタップ可能化。
    // 親 (_buildItemList の itemBuilder) 側で「gacha_only → _buy 経由で使う / その他
    // → _showInventoryDetail」をディスパッチする (onBuy callback の意味を拡張)。
    if (isInventory) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onBuy,
        child: card,
      );
    }
    return card;
  }
}
