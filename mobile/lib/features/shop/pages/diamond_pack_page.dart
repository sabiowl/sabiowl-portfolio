import 'dart:async';  // 【2026-07-05 hotfix】unawaited()

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../habits/providers/habits_provider.dart';
import '../providers/iap_provider.dart';

/// 【FEAT-436 (2026-06-17)】ダイヤ購入画面 (v1.0.1 hot fix、iOS 先行)。
///
/// 商品 3 種 (【Apple ガイドライン 2.3.2 hotfix 2026-07-06】ボーナスは絶対値で管理):
///   - `diamond_pack_120`:  120 円 / 120 ダイヤ
///   - `diamond_pack_660`:  600 円 / 660 ダイヤ (+60 ダイヤ ボーナス)
///   - `diamond_pack_1440`: 1200 円 / 1440 ダイヤ (+240 ダイヤ ボーナス、2026-06-25 追加)
///
/// Android では Google Play Console 未加入のため、v1.0.2 まで「iOS のみ対応」
/// 案内画面を表示する。Mobile コード自体は両プラットフォーム対応の
/// `purchases_flutter` で共通化、設定で活性化フラグ 1 つで切替可能。
class DiamondPackPage extends ConsumerWidget {
  const DiamondPackPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(iapServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.shopDiamondPackPageTitle),
      ),
      body: !service.isAvailable
          ? const _AndroidComingSoon()
          : _IOSPurchaseBody(),
    );
  }
}

/// Android 専用: 「iOS のみ対応」案内画面。
/// v1.0.2 で Play Console 加入後に削除予定。
class _AndroidComingSoon extends StatelessWidget {
  const _AndroidComingSoon();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.smartphone, size: 56, color: Colors.white24),
            const SizedBox(height: 20),
            Text(
              l10n.shopDiamondPackAndroidComingSoonTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.shopDiamondPackAndroidComingSoonBodySabi_message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// iOS 用購入画面本体。商品リスト取得 → 各商品の購入ボタン → 購入確認ダイアログ。
class _IOSPurchaseBody extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final offeringsAsync = ref.watch(iapOfferingsProvider);
    // 【2026-07-05 hotfix】現在購入中の package identifier (null = なし)。
    // 旧実装の bool では 660 選択時に 120/1440 の 2 カードも spinner 化して
    // いた不具合を、identifier 単位の一致判定で構造解消する。
    final inFlightPackageId = ref.watch(iapPurchaseInFlightProvider);

    return offeringsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: AppTheme.primary),
      ),
      error: (e, st) => _ErrorView(
        message: l10n.shopDiamondPackStoreErrorSabi_message,
        onRetry: () => ref.invalidate(iapOfferingsProvider),
      ),
      data: (packages) {
        if (packages.isEmpty) {
          return _ErrorView(
            message: l10n.shopDiamondPackEmptySabi_message,
            onRetry: () => ref.invalidate(iapOfferingsProvider),
          );
        }
        // いずれかの package が購入中か (他カードのタップ抑止のため参照)
        final anyPurchaseInFlight = inFlightPackageId != null;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── イントロ ──────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(
                  l10n.shopDiamondPackIntroSabi_message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── 商品リスト ──────────────────────
              for (final package in packages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _PackageCard(
                    package: package,
                    // 自 package が購入中なら spinner + タップ無効化。
                    isThisInFlight: inFlightPackageId == package.identifier,
                    // 他 package が購入中の間は自 package も並列購入不可 (二重起動防止)。
                    anyPurchaseInFlight: anyPurchaseInFlight,
                    onPurchase: () => _confirmAndPurchase(context, ref, package),
                  ),
                ),

              const SizedBox(height: 16),

              // ── 注意書き ─────────────────────────
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Text(
                  l10n.shopDiamondPackNotes,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 購入前確認 → 購入起動 → 完了処理。
  Future<void> _confirmAndPurchase(
    BuildContext context,
    WidgetRef ref,
    Package package,
  ) async {
    HapticFeedback.lightImpact();

    // 【FEAT-489 Phase 2E】await をまたぐので l10n は最初に capture する
    // (develop.md §Phase 2C 知見 4 / use_build_context_synchronously)。
    final l10n = AppLocalizations.of(context)!;

    // 購入前確認ダイアログ (Pre-mortem S10 子供誤購入対策と同精神)
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(l10n.shopDiamondPackConfirmDialogTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          // product / price はストア由来の値をそのまま流し込む (§2.1: 価格文字列は
          // Apple が locale / 通貨を解決済み、こちらで整形しない)。
          l10n.shopDiamondPackConfirmDialogBodySabi_message(
            package.storeProduct.title,
            package.storeProduct.priceString,
          ),
          style: const TextStyle(
              color: Colors.white70, fontSize: 13, height: 1.6),
        ),
        actions: [
          // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の新ルール準拠。
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.shopDiamondPackConfirmCancelButton,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.shopDiamondPackConfirmPurchaseButton),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    HapticFeedback.mediumImpact();

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    // 【2026-07-05 hotfix】自 package の identifier を State に設定し、UI 側で
    // 一致した package カードのみ spinner + タップ抑止する。
    ref.read(iapPurchaseInFlightProvider.notifier).state = package.identifier;

    try {
      await ref.read(iapServiceProvider).purchasePackage(package);

      // 【2026-07-05 hotfix】Apple Pay 完了 = ユーザー操作の待ち時間はここで終わり。
      // 旧実装は Backend webhook 処理を待つ hardcoded 1500ms wait を await して
      // いたため、UI 上の spinner が Apple Pay 完了後さらに 1.5 秒残っていた
      // (Render cold start 中は追加で数十秒)。spinner はここで即座に解除し、
      // ダイヤ残高の反映は非同期タスクで行う (ユーザーは SnackBar で予告済)。
      ref.read(iapPurchaseInFlightProvider.notifier).state = null;

      if (!context.mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.shopDiamondPackPurchaseAcceptedSabi_message),
          duration: const Duration(seconds: 4),
        ),
      );

      // 【2026-07-05 hotfix】残高再フェッチは spinner 解除後に非同期で実行。
      // 1500ms は RevenueCat webhook → Backend 処理 → DB commit の経験則の
      // 見積り時間 (Render Starter で通常 300-800ms、余裕として 1.5 倍)。
      // Render cold start (最大 60 秒) の場合はここでは反映されないが、
      // 次回のホーム画面訪問時等の invalidate で最終的に整合する。
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        // ignore: invalid_use_of_visible_for_testing_member — hotfix scope 内
        ref.invalidate(playerNotifierProvider);
      }());
    } on PlatformException catch (e) {
      // 【FEAT-436 hotfix (2026-06-17)】purchases_flutter ^10 では購入失敗が
      // PlatformException で投げられる (旧 ^8 系 PurchasesError 直接 catch は撤回、
      // メジャー間互換性のため PurchasesErrorHelper.getErrorCode を経由する公式
      // パターンに統一)。キャンセルはユーザー意図的なのでサイレント、それ以外は
      // エラー SnackBar 表示。
      final errorCode = PurchasesErrorHelper.getErrorCode(e);
      final isCancel = errorCode == PurchasesErrorCode.purchaseCancelledError;
      if (!context.mounted) return;
      if (!isCancel) {
        debugPrint('[DiamondPackPage] purchase failed (code=$errorCode): $e');
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(l10n.shopDiamondPackPurchaseFailedSabi_message),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[DiamondPackPage] purchase failed: $e\n$st');
      if (!context.mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.shopDiamondPackPurchaseFailedSabi_message),
        ),
      );
    } finally {
      // 成功経路では既に null 化済 (no-op)、失敗/キャンセル時はここで初めて null 化。
      // context.mounted の判定は不要 (State 変更は widget 破棄後でも安全)。
      ref.read(iapPurchaseInFlightProvider.notifier).state = null;
    }
  }
}

/// 商品カード 1 件。商品名 + 価格 + ボーナス表示 + 購入ボタン。
///
/// 【2026-07-05 hotfix】旧 `bool inFlight` (グローバル購入中フラグ) を
/// `bool isThisInFlight` (自 package が購入中) + `bool anyPurchaseInFlight`
/// (いずれかが購入中 → タップ抑止用) に分離。spinner は自 package のみ、
/// タップ抑止は全 package (二重起動防止) という「見た目と挙動の分離」に
/// より、660 選択で 120/1440 も spinner 化する不具合を構造解消した。
class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.package,
    required this.isThisInFlight,
    required this.anyPurchaseInFlight,
    required this.onPurchase,
  });

  final Package package;
  final bool isThisInFlight;
  final bool anyPurchaseInFlight;
  final VoidCallback onPurchase;

  /// 価格表示。
  ///
  /// 【FEAT-514 (2026-08-02)】**ストアが返す localized price string を常に正**とする。
  ///
  /// 旧実装 (2026-07-05 hotfix) は「Sabiowl v1.0.1 は日本 App Store のみで販売する」
  /// 前提で、通貨コードが JPY 以外のとき `package.identifier` から導出した
  /// 日本円固定価格を表示していた。当時は TestFlight Sandbox テスターの地域が
  /// 既定「United States」のままドル表示になる事象への防御として妥当だったが、
  /// v1.1 で英語圏 storefront (US / UK / AU / CA / EU) を開くとこの前提が反転し、
  /// **実ユーザーは現地通貨で課金されるのに画面には日本円が出る**という価格の
  /// 誤表示になる (App Store review の指摘対象 + ユーザー信頼の毀損)。
  ///
  /// 通貨記号・桁区切り・税込/税別の扱いは Apple / Google が storefront ごとに
  /// 解決済みなので、アプリ側で整形も上書きもしない。Sandbox テスターに現地通貨
  /// 以外の表示が出る事象はアプリで隠すべきものではなく、テスター側の地域設定
  /// (Japan) で解決する (旧 hotfix コメント自身が「真の原因は Apple 側の地域設定」
  /// と記していたとおり)。
  ///
  /// ⚠️ **ここに通貨記号のリテラルを書かないこと**。storefront を増やすたびに
  /// 固定価格が復活する再発を、`test/i18n_coverage_test.dart` の check E が
  /// source レベルで検出する。
  String get _priceString => package.storeProduct.priceString;

  /// `package.identifier` から商品情報を導出 (FEAT-436 §1.1 と一致)。
  ///
  /// 【Apple ガイドライン 2.3.2 hotfix (2026-07-06)】旧 `bonusPct` (10 / 20 %
  /// 表記) から `bonusAmount` (絶対値 60 / 240 ダイヤ表記) に変更。
  /// Apple reject (2026-07-06) で App Store Connect の Display Name の
  /// 「10% お得」「20% お得」表現を価格言及として指摘された関連で、
  /// アプリ内 UI も予防的に % 表記を廃止 (数量ボーナスは価格ではないが、
  /// 「%」の視覚語彙が同じ reviewer 判定を招くリスクを回避)。
  ///
  /// 【FEAT-489 Phase 2E】label を l10n 解決するため [l10n] を引数で受け取る。
  /// **`package.identifier` の switch は locale に依存しない** — RevenueCat の
  /// product identifier なので絶対に翻訳しないこと (§2.1 触ってはいけないもの)。
  ({int diamonds, int? bonusAmount, String label}) _productInfo(
      AppLocalizations l10n) {
    switch (package.identifier) {
      case 'diamond_pack_120':
        return (
          diamonds: 120,
          bonusAmount: null,
          label: l10n.shopDiamondPackLabel(120),
        );
      case 'diamond_pack_660':
        // 600 円 baseline 600 ダイヤ + 60 ダイヤ ボーナス = 660 ダイヤ
        return (
          diamonds: 660,
          bonusAmount: 60,
          label: l10n.shopDiamondPackLabel(660),
        );
      // 【新規 (2026-06-25)】1200 円 / 1440 個 (+240 ダイヤ ボーナス) 枠。
      case 'diamond_pack_1440':
        // 1200 円 baseline 1200 ダイヤ + 240 ダイヤ ボーナス = 1440 ダイヤ
        return (
          diamonds: 1440,
          bonusAmount: 240,
          label: l10n.shopDiamondPackLabel(1440),
        );
      default:
        // 未知の Package (RevenueCat ダッシュボード変更時の forward-compat)。
        // ストアの localized title をそのまま使う (Apple が locale 解決済み)。
        return (
          diamonds: 0,
          bonusAmount: null,
          label: package.storeProduct.title,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final info = _productInfo(l10n);
    final isBonus = info.bonusAmount != null;

    return Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        // タップ抑止はいずれかの package が購入中の間 (二重起動防止)。
        onTap: anyPurchaseInFlight ? null : onPurchase,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isBonus
                  ? AppTheme.primary.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.18),
              width: isBonus ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              // ── アイコン ──────────────────────
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('💎', style: TextStyle(fontSize: 30)),
              ),
              const SizedBox(width: 14),

              // ── テキスト ──────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          info.label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isBonus) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            // 【Apple ガイドライン 2.3.2 hotfix (2026-07-06)】
                            // 旧 '+${bonusPct}%' → '+N ダイヤ' 絶対値表記に。
                            // 価格言及と誤解される「%」を全廃、数量のみ提示。
                            child: Text(
                              l10n.shopDiamondPackBonusBadge(info.bonusAmount!),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _priceString,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),

              // ── 購入ボタン / 進行中スピナー ─────
              // 【2026-07-05 hotfix】spinner は自 package が購入中の時のみ表示。
              if (isThisInFlight)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.primary,
                  ),
                )
              else
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white38,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// エラー時の汎用画面 (リトライボタン付き)。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(
                  AppLocalizations.of(context)!.shopDiamondPackRetryButton),
            ),
          ],
        ),
      ),
    );
  }
}
