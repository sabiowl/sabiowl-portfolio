import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../habits/providers/habits_provider.dart';
import '../models/weapon_info.dart';

/// 【FEAT-327】 装備選択 Overlay (`doc/instructions_from_gemini/guild_equipment_2.md`
/// §1.2 「カードが重なって見えるレイアウト (Stack構造)」仕様準拠 widget)。
///
/// PartyEditDialog 内に Stack で重ね合わせ表示される最手前カード。
/// 旧 `WeaponSelectSheet` (FEAT-326 BottomSheet 経路) は仕様逸脱だったため
/// 本 widget に置換される。
///
/// 構造 (guild_equipment_2.md §1.2):
///   - ヘッダー: ＜ 戻る | 装備の変更 | ×
///   - 現在装備中の固定枠: 「現在装備中: ⚔️ {name} (+{atk_bonus})」
///   - 所持装備一覧 (ListView スクロール): 各 ListTile に「装備する」ボタン
///   - 閉じる動線 3 経路: ＜ 戻る / × / カード外背景タップ
///
/// 設計判断:
///   - **Stack 重ね合わせ**: caller (PartyEditDialog) が Stack の最手前に
///     置き、`isSelectingEquipment` フラグで条件付き描画する。本 widget は
///     カード本体のみを返す (caller 側でレイアウト調整)。
///   - **`onEquip` / `onClose` callback**: 親 widget で状態管理を完結させる
///     ため、本 widget は state を持たず純粋に表示と callback 発火のみ。
///   - **カード外タップで閉じる**: `Stack` で背景に半透明レイヤーを敷き、
///     caller 側で `GestureDetector(onTap: onClose)` を背景に重ねる前提
///     (本 widget は内部でその責務を持たない、testability のため)。
class EquipmentSelectionOverlay extends ConsumerWidget {
  const EquipmentSelectionOverlay({
    super.key,
    required this.currentWeapon,
    required this.onClose,
    required this.onEquip,
  });

  /// 現在装備中の武器 (PartyEditDialog から渡される、null = 未装備)。
  /// ヘッダー下の「現在装備中: ⚔️ {name} (+{atk}) 」表示 +
  /// 所持武器リストの「装備中」/「装備する」ボタン分岐に使う。
  final WeaponInfo? currentWeapon;

  /// ヘッダーの「＜ 戻る」/「×」/カード外タップで発火。caller が
  /// `setState(() => _isSelectingEquipment = false)` で本 widget を畳む。
  final VoidCallback onClose;

  /// 「装備する」タップで発火 (装備中武器自身ではタップ無効、装備中の
  /// 武器以外でのみボタンが活性になる)。caller が `setEquippedWeapon`
  /// を呼んだ後、自身で `onClose` を発火させる責務を持つ。
  final void Function(WeaponInfo weapon) onEquip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final weaponsAsync = ref.watch(playerWeaponsProvider);
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.5),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, l10n),
            const Divider(color: Colors.white12, height: 1),
            _buildCurrentWeaponBanner(l10n),
            const Divider(color: Colors.white12, height: 1),
            Flexible(
              child: weaponsAsync.when(
                data: (weapons) => _buildWeaponList(weapons, l10n),
                loading: () => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(
                    child: CircularProgressIndicator(color: AppTheme.primary),
                  ),
                ),
                error: (_, __) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.battleEquipmentLoadErrorSabi_message,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── ヘッダー: ＜ 戻る | 装備の変更 | × ─────────────────────────────
  Widget _buildHeader(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.battleOverlayBackTooltip,
            icon: const Icon(Icons.chevron_left, color: Colors.white70),
            onPressed: onClose,
          ),
          Expanded(
            child: Text(
              l10n.battleEquipmentTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.battleOverlayCloseTooltip,
            icon: const Icon(Icons.close, size: 20, color: Colors.white70),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  // ── 現在装備中の固定枠 ──────────────────────────────────────────────
  Widget _buildCurrentWeaponBanner(AppLocalizations l10n) {
    final w = currentWeapon;
    final label = w != null
        ? l10n.battleEquipmentCurrentLabel(w.name, w.atkBonus)
        : l10n.battleEquipmentCurrentEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.primary.withValues(alpha: 0.12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 所持装備一覧 ListView (スクロール) ───────────────────────────────
  Widget _buildWeaponList(List<WeaponInfo> weapons, AppLocalizations l10n) {
    if (weapons.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.battleEquipmentEmptySabi_message,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: weapons.length,
      separatorBuilder: (_, __) =>
          const Divider(color: Colors.white12, height: 1),
      itemBuilder: (_, i) {
        final w = weapons[i];
        final isCurrent = currentWeapon?.id == w.id;
        return ListTile(
          leading: const Icon(Icons.shield_outlined, color: Colors.white70),
          title: Text(
            w.name,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.battleEquipmentAtkBonusLabel(w.atkBonus),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              // 【FEAT-379 (2026-05-29)】ソケット枠 (v1.0 は鍵アイコン + 予告)
              // Pre-mortem #3: 「予定」表現のみ、強い約束禁止
              if (w.socketCount > 0) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    ...List.generate(
                      w.socketCount,
                      (_) => const Padding(
                        padding: EdgeInsets.only(right: 2),
                        child: Icon(
                          Icons.lock_outline,
                          size: 12,
                          color: Colors.white30,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      // 【BUG-123 (2026-06-14)】時期を伏せる (PM 判断、期日コミット回避)
                      l10n.battleEquipmentComingSoon,
                      style: const TextStyle(
                        color: Colors.white30,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          isThreeLine: w.socketCount > 0,
          trailing: ElevatedButton(
            onPressed: isCurrent ? null : () => onEquip(w),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(80, 36),  // Row 内裸 ElevatedButton 防御
              backgroundColor:
                  isCurrent ? Colors.white24 : AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: Text(
              isCurrent ? l10n.battleEquipmentEquippedButton : l10n.battleEquipmentEquipButton,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }
}
