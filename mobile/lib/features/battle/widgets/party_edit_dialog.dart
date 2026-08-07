import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/toast_center.dart';     // 【FEAT-327】装備変更後の SnackBar
import '../../../core/theme/app_theme.dart';
import '../../gamification/models/gamification_models.dart' show CharacterStat;  // 【FEAT-390】stat 取得
import '../../gamification/providers/gamification_provider.dart' show statsNotifierProvider;  // 【FEAT-390】
import '../../habits/providers/habits_provider.dart' show playerNotifierProvider;
import '../constants/battle_constants.dart';  // 【FEAT-306 / FEAT-390】max HP + BattleDisplay
import '../models/job.dart';
import '../models/weapon_info.dart';            // 【FEAT-326】WeaponInfo
import 'equipment_selection_overlay.dart';      // 【FEAT-327】装備選択カード (Stack 重ね合わせ)
import 'job_choices.dart';                      // 【FEAT-431】JobChoice / kJobs (public 化)
import 'job_selection_overlay.dart';            // 【FEAT-431】ジョブ一覧カード (Stack 重ね合わせ)

import '../../../l10n/app_localizations.dart';

/// 【FEAT-304】PartyEditDialog — v1.0 編成ハブ（ジョブ + 装備閲覧 + アビリティ閲覧 + ステータス統合）。
///
/// 名称メモ（FEAT-289/290 整合性整理ターン 2026-05-25 PM 直接修正、機能レビュー P3-1 解消）:
///   旧コメント「v1.0 軽量版」は v1.1+ FEAT-310（パーティ 3+1 人化 + ジョブレベル + 5×5
///   アビリティ解禁 + 装備変更）が来た時に「v1.0 軽量」と相対表現が成立する前提だったが、
///   v1.0 単独で見ると 637 LOC は他の中核画面（home_page 1021 / settings 921）に肉薄する
///   サイズで「軽量」の自称と乖離。本ターンで「v1.0 編成ハブ」に改名、現時点の中身を
///   表す名称に統一。
///
/// v1.0 で実装している範囲（指示書 §1、現状の中身）:
///   - ジョブ閲覧（active_character.job、「キャラ = ジョブ」固定 — FEAT-430 (2026-06-12)）
///   - 装備閲覧（現在の starter_sword 表示） — 閲覧のみ、変更は v1.1+
///   - アビリティ閲覧（ジョブ別固定表示） — 閲覧のみ、変更は v1.1+
///   - ステータス確認動線（FEAT-306 で Lv/HP/EXP/coins/diamonds の _StatusSection を統合予定）
///
/// 【FEAT-430 (2026-06-12)】「キャラ = ジョブ」固定化:
///   旧 FEAT-390/304 のジョブ動的変更 (PATCH /api/player/active-job/) は v1.0 で
///   deactivate (410 Gone)。ジョブは `active_character.job` から取得し読み取り専用
///   表示する。v1.1+ 熟練度システム (doc/design/job_mastery_v1_1.md) で
///   「熟練度 Max ジョブの付け替え」として再活性化予定。
/// 【FEAT-431 (2026-06-13)】ジョブセクションは設定中ジョブ 1 枠のみ表示し、
///   タップで `JobSelectionOverlay`（全 8 ジョブ一覧モーダル）を開く構成に変更。
///
/// v1.1+ (FEAT-310) で拡張される範囲:
///   - パーティ 3+1 人化（Combatant 単数 → `List<Combatant>`）
///   - ジョブ熟練度 + 5×5 アビリティ解禁（50 アビリティ seed）
///   - 装備変更（武器 3-5 種追加 + PlayerWeapon 個別管理 + 装備選択カード階層 UI = Gemini guild_equipment_2.md）
///   - 通常 / 必殺スロット割り当て
///   v1.1 着手時は本 dialog を **拡張** する想定（新規 widget ではなく増築）、
///   その時点で 1,500+ LOC 想定。本 dialog 名は v1.1 でも維持（「編成ハブ」のまま、機能拡張のみ）。
///
/// 表示パターン:
///   - 開く: `showGeneralDialog<void>(...)` でフェード + スケール
///   - 閉じる: `Navigator.of(dialogContext).pop()` (CLAUDE.md「ShellRoute 配下の
///            Navigator.pop コンテキスト分離 FEAT-215」遵守、builder の引数を使う)
///
/// Pre-mortem 緩和:
///   - #1 dialog 内 navigation race → 本 dialog 内では navigation 一切しない (閉じるボタンの pop のみ)
///   - #2 ShellRoute Navigator.pop コンテキスト → `dialogContext` を `onClose` callback 経由で使う
///   - #4 「装備変更できない」UX 摩擦 → opacity 0.6 + サビ口調 v1.1 予告で明示
/// 【FEAT-327】 PartyEditDialog を `ConsumerStatefulWidget` 化:
///   - 旧: `ConsumerWidget` で装備変更は BottomSheet (WeaponSelectSheet) 経路
///   - 新: 内部 state `_isSelectingEquipment` + Stack 重ね合わせで
///         `EquipmentSelectionOverlay` を最手前に重ねる
///         (guild_equipment_2.md §1.2 仕様準拠)
class PartyEditDialog extends ConsumerStatefulWidget {
  const PartyEditDialog({super.key, required this.onClose});

  /// dialog を閉じる callback。caller (guild_page) が `dialogContext` を渡して、
  /// 内側からは無条件に呼ぶだけにする（CLAUDE.md ShellRoute 整合性）。
  final VoidCallback onClose;

  @override
  ConsumerState<PartyEditDialog> createState() => _PartyEditDialogState();
}

class _PartyEditDialogState extends ConsumerState<PartyEditDialog> {
  /// 【FEAT-327】 装備選択 Overlay を最手前に重ねるかどうかのフラグ。
  /// `_WeaponSlotTile` タップで true、`EquipmentSelectionOverlay.onClose` で false。
  bool _isSelectingEquipment = false;

  /// 【FEAT-431】ジョブ選択 Overlay を最手前に重ねるかどうかのフラグ。
  /// 設定中ジョブ枠タップで true、JobSelectionOverlay.onClose で false。
  /// `_isSelectingEquipment` と排他 (Pre-mortem S1、open 側で互いを false にする)。
  bool _isSelectingJob = false;

  void _openEquipmentSelection() {
    setState(() {
      _isSelectingJob = false;
      _isSelectingEquipment = true;
    });
  }

  void _closeEquipmentSelection() {
    if (!mounted) return;
    setState(() => _isSelectingEquipment = false);
  }

  void _openJobSelection() {
    setState(() {
      _isSelectingEquipment = false;
      _isSelectingJob = true;
    });
  }

  void _closeJobSelection() {
    if (!mounted) return;
    setState(() => _isSelectingJob = false);
  }

  Future<void> _onEquipFromOverlay(WeaponInfo weapon) async {
    final success = await ref
        .read(playerNotifierProvider.notifier)
        .setEquippedWeapon(weapon.id, localWeapon: weapon);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (success) {
      ToastCenter.showSuccess(
        l10n.battlePartyWeaponEquippedToastSabi_message(weapon.name),
      );
    } else {
      ToastCenter.showWarning(
        l10n.battlePartyEquipErrorSabi_message,
      );
    }
    _closeEquipmentSelection();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playerAsync = ref.watch(playerNotifierProvider);
    final media = MediaQuery.of(context);

    // 【FEAT-327】 guild_equipment_2.md §1.1「階層構造」仕様準拠:
    //   - レイヤー 1 (背面): 既存「編成・装備」ダイアログ本体
    //   - レイヤー 2 (最手前): EquipmentSelectionOverlay (一回り小さい)
    //   背面のカードが上下左右にはみ出して見えるよう、Overlay には大きめマージンを付与する。
    return Stack(
      alignment: Alignment.center,
      children: [
        // ── レイヤー 1: 既存ダイアログ本体 ───────────────────────────
        Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width:  media.size.width - 48,         // 左右マージン 24px
              height: media.size.height * 0.75,      // 75% (Gemini 仕様 70-80% 内)
              decoration: BoxDecoration(
                color: AppTheme.sheetBackground,
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.4),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── タイトル ─────────────────────────────────────────
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.battlePartyTitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                        tooltip: l10n.battleOverlayCloseTooltip,
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 16),

                  // ── スクロール本体 ────────────────────────────────────
                  Expanded(
                    child: SingleChildScrollView(
                      child: playerAsync.when(
                        loading: () => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: CircularProgressIndicator(color: AppTheme.primary),
                          ),
                        ),
                        error: (_, __) => Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            l10n.battlePartyLoadErrorSabi_message,
                            style: const TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        data: (player) => _DialogBody(
                          player: player,
                          // 【FEAT-327】装備枠タップで Overlay 起動
                          onEquipmentTap: _openEquipmentSelection,
                          // 【FEAT-431】ジョブ枠タップで JobSelectionOverlay 起動
                          onJobTap: _openJobSelection,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),
                  // ── 閉じるボタン ────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: widget.onClose,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(l10n.battlePartyCloseButton),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── レイヤー 2: 装備選択 Overlay (条件付き描画) ──────────────
        // 【FEAT-327】 guild_equipment_2.md §1.1 「最手前 (レイヤー2): 中間の
        // 編成・装備ダイアログよりも一回り小さく」設計。背面のカードがはみ出し
        // て見えるよう、左右 horizontal 24 (=合計 48 はみ出し) / 上下 vertical 64
        // のマージンを取る。カード外背景タップで `onClose` を発火する 3 経路目を
        // 提供 (ヘッダー「＜ 戻る」/「×」とあわせて閉じる動線 3 経路、§1.2 準拠)。
        if (_isSelectingEquipment)
          Positioned.fill(
            child: Stack(
              children: [
                // 半透明マスク + 背景タップ閉じ動線
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeEquipmentSelection,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                // 一回り小さい装備選択カード (中央配置、左右 24 / 上下 64 はみ出し)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 64,
                  ),
                  child: GestureDetector(
                    // カード内タップは閉じない (背景タップとの差別化)
                    onTap: () {},
                    child: playerAsync.when(
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                      data: (player) => EquipmentSelectionOverlay(
                        currentWeapon: player.equippedWeapon,
                        onClose: _closeEquipmentSelection,
                        onEquip: _onEquipFromOverlay,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ── レイヤー 2: ジョブ一覧 Overlay (条件付き描画) ──────────────
        // 【FEAT-431】 EquipmentSelectionOverlay と同パターン。設定中ジョブ枠
        // タップで Stack 最手前に重ねる。閲覧専用 (FEAT-430 哲学維持)、
        // カード外背景タップで `onClose` を発火する 3 経路目を提供。
        if (_isSelectingJob)
          Positioned.fill(
            child: Stack(
              children: [
                // 半透明マスク + 背景タップ閉じ動線
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeJobSelection,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                // 一回り小さいジョブ一覧カード (中央配置、左右 24 / 上下 64 はみ出し)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 64,
                  ),
                  child: GestureDetector(
                    // カード内タップは閉じない (背景タップとの差別化)
                    onTap: () {},
                    child: playerAsync.when(
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                      data: (player) => JobSelectionOverlay(
                        currentJob: player.activeCharacter?.job ?? Job.fallback,
                        currentCharacterName: player.activeCharacter?.name,
                        onClose: _closeJobSelection,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DialogBody extends ConsumerWidget {
  const _DialogBody({
    required this.player,
    required this.onEquipmentTap,
    required this.onJobTap,
  });

  // ignore: library_private_types_in_public_api
  final dynamic player; // Player 型 (循環 import 回避のため dynamic)

  /// 【FEAT-327】 装備枠タップ時の callback。caller (_PartyEditDialogState) で
  /// `_isSelectingEquipment = true` 設定 → Overlay 起動。
  final VoidCallback onEquipmentTap;

  /// 【FEAT-431】 ジョブ枠タップ時の callback。caller (_PartyEditDialogState) で
  /// `_isSelectingJob = true` 設定 → JobSelectionOverlay 起動。
  final VoidCallback onJobTap;

  String _resolveInitialJobName(AppLocalizations l10n) {
    // active_character.job (= キャラの初期ジョブ) を表示。
    // 【FEAT-304】v1.0 編成ハブでは initial job は表示用ヒントとしてのみ使用 (絵柄イメージ)。
    // active_character.role が初期ジョブ名相当（既存 API 構造から推定）。
    final char = player.activeCharacter;
    if (char == null) return l10n.battlePartyJobNotSet;
    return char.role.isEmpty ? l10n.battlePartyJobInitialLabel : char.role;
  }

  /// 【FEAT-430】「キャラ = ジョブ」固定化、active_character.job が唯一の真実値。
  String? get _activeJobId {
    final char = player.activeCharacter;
    final job = char?.job as Job?;
    return job?.jobId;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-390】stats を watch して studyLv / mentalLv を _StatusSection に渡す。
    final statsAsync = ref.watch(statsNotifierProvider);
    final stats = statsAsync.valueOrNull ?? const <CharacterStat>[];
    final statLevels = <String, int>{
      for (final s in stats) s.name: s.level,
    };
    final studyLv  = statLevels['学習力'] ?? 0;
    final mentalLv = statLevels['精神力'] ?? 0;

    // 【FEAT-430】表示用 Job の解決: 「キャラ = ジョブ」固定化、
    // active_character.job が唯一の真実値 (null なら warrior フォールバック)。
    final effectiveJob = (player.activeCharacter?.job as Job?) ?? Job.fallback;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── ステータス (FEAT-306 新規、_GuildHeader 撤廃後の集約先) ──────
        // Lv / HP / EXP バー / coins / diamonds を一望、HP 確認動線として機能。
        // 【FEAT-430】effectiveJob (キャラ固定ジョブ) / studyLv / mentalLv を渡して ATK/ATB 表示。
        _StatusSection(
          player: player,
          selectedJob: effectiveJob,
          studyLv: studyLv,
          mentalLv: mentalLv,
        ),
        const SizedBox(height: 16),
        // ── キャラ表示 (現在のジョブをヘッダーレベルで強調表示) ────────
        _CharacterSummary(
          player: player,
          initialJobName: _resolveInitialJobName(l10n),
          currentJobName: effectiveJob.jobName,
        ),
        const SizedBox(height: 16),

        // ── v1.1+ 熟練度システム予告バナー ─────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.20), width: 0.8),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: AppTheme.primary.withValues(alpha: 0.85)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.battlePartyJobHintSabi_message,
                  style: TextStyle(
                    color: AppTheme.primary.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── ジョブ (キャラ固定、v1.0 では閲覧のみ) ───────────────────
        // 【FEAT-431】全 13(8) ジョブの横スクロール露出を廃止、設定中ジョブ
        // 1 枠のみ表示 + 「>」マークタップで JobSelectionOverlay (一覧モーダル) を開く。
        _SectionLabel(icon: Icons.shield, label: l10n.battlePartySectionJob),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onJobTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.card,
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.5),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Builder(
                    builder: (_) {
                      final job = kJobs.firstWhere(
                        (j) => j.id == _activeJobId,
                        orElse: () => kJobs.first,  // フォールバック
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            job.localizedName(l10n),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            job.localizedDescription(l10n),
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 9,
                              height: 1.3,
                            ),
                            maxLines: 3,
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: AppTheme.primary.withValues(alpha: 0.85),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.battlePartyJobDetailHint,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 16),

        // ── 装備 (FEAT-326: 装備変更動作化、v1.0 内で完成) ────────────────
        _SectionLabel(icon: Icons.handyman, label: l10n.battlePartySectionEquip),
        const SizedBox(height: 6),
        _WeaponSlotTile(
          weapon: player.equippedWeapon,
          onTap: onEquipmentTap,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.battlePartyEquipDetailHint,
          style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 16),

        // ── アビリティ (v1.0 閲覧のみ、ジョブ別表示) ──────────────
        _SectionLabel(icon: Icons.auto_awesome, label: l10n.battlePartySectionAbility),
        const SizedBox(height: 6),
        Opacity(
          opacity: 0.6,
          child: _AbilityPreview(jobId: _activeJobId),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.battlePartyAbilityHintSabi_message,
          style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _CharacterSummary extends StatelessWidget {
  const _CharacterSummary({
    required this.player,
    required this.initialJobName,
    required this.currentJobName,
  });

  // ignore: library_private_types_in_public_api
  final dynamic player;
  final String initialJobName;

  /// 【FEAT-430】「キャラ = ジョブ」固定化、現在のジョブをヘッダーレベルで表示。
  final String currentJobName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final char = player.activeCharacter;
    final imagePath = char != null && char.key != null && (char.key as String).isNotEmpty
        ? 'assets/images/characters/character_${char.key}.webp'
        : null;

    return Row(
      children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: AppTheme.surface,
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.6),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: imagePath != null
              ? Image.asset(
                  imagePath,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.person, size: 32, color: Colors.white38,
                  ),
                )
              : const Icon(Icons.person, size: 32, color: Colors.white38),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (char?.name as String?) ?? player.name as String,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              // 【FEAT-430】現在のジョブをヘッダーレベルで強調表示。
              Row(
                children: [
                  const Icon(Icons.shield, size: 13, color: AppTheme.primaryLight),
                  const SizedBox(width: 4),
                  Text(
                    currentJobName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                l10n.battlePartyInitialJobDisplay(initialJobName),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppTheme.primaryLight),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// アビリティ閲覧プレビュー (ジョブ別固定表示、v1.1 で動的化予定)。
class _AbilityPreview extends StatelessWidget {
  const _AbilityPreview({required this.jobId});

  final String? jobId;

  Map<String, String> _abilitiesFor(AppLocalizations l10n, String? jid) {
    // 通常 / 必殺の簡易説明。jobId 不明 (null) なら general を表示。
    // 【FEAT-391 (2026-05-30)】8 ジョブ対応に更新 (5 ジョブ → 8 ジョブ)
    final kNormal = l10n.battleAbilityKeyNormal;
    final kUlt    = l10n.battleAbilityKeyUltimate;
    switch (jid) {
      case 'warrior':
        return {kNormal: l10n.battleAbilityDescNormalWarrior,   kUlt: l10n.battleAbilityDescUltimateWarrior};
      case 'assassin':
        return {kNormal: l10n.battleAbilityDescNormalAssassin,  kUlt: l10n.battleAbilityDescUltimateAssassin};
      case 'blue_mage':
        return {kNormal: l10n.battleAbilityDescNormalBlueMage,  kUlt: l10n.battleAbilityDescUltimateBlueMage};
      case 'healer':
        return {kNormal: l10n.battleAbilityDescNormalHealer,    kUlt: l10n.battleAbilityDescUltimateHealer};
      case 'knight':
        return {kNormal: l10n.battleAbilityDescNormalKnight,    kUlt: l10n.battleAbilityDescUltimateKnight};
      case 'archer':
        return {kNormal: l10n.battleAbilityDescNormalArcher,    kUlt: l10n.battleAbilityDescUltimateArcher};
      case 'monk':
        return {kNormal: l10n.battleAbilityDescNormalMonk,      kUlt: l10n.battleAbilityDescUltimateMonk};
      case 'dark_mage':
        return {kNormal: l10n.battleAbilityDescNormalDarkMage,  kUlt: l10n.battleAbilityDescUltimateDarkMage};
      default:
        return {kNormal: l10n.battleAbilityDescNormalDefault,   kUlt: l10n.battleAbilityDescUltimateDefault};
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = _abilitiesFor(l10n, jobId);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.card,
        border: Border.all(color: Colors.white24, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entries.entries.map((e) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 38,
                  child: Text(
                    e.key,
                    style: const TextStyle(
                      color: AppTheme.primaryLight,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    e.value,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 【FEAT-306】_StatusSection — _GuildHeader 撤廃後の HP/Lv/EXP/diamonds 集約先
// ═════════════════════════════════════════════════════════════════════════════

/// PartyEditDialog 上部に表示するプレイヤーステータスサマリ。
///
/// 表示要素:
///   - Lv（player.level）
///   - HP バー（max HP = BattleConstants.playerBaseHp + level × playerHpPerLevel、
///     戦闘外は満タン表示。_GuildHeader 旧実装と同公式）
///   - EXP バー（currentExp / maxExp）
///   - 💎 diamonds 残高
///
/// **coins 表示は本 FEAT スコープ外**: Player モデルに coins フィールドが
/// 存在しないため、本 FEAT で導入すると Player/serializer/API 拡張が必要に
/// なる。指示書 §2.2 の「💎 / 🪙」見本は将来案、v1.0 は diamonds のみ表示
/// （v1.1 で Player.coins 追加時に行を増やすだけで済む構造）。
class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.player,
    // 【FEAT-390】ATK/ATB 表示用の Job (楽観 UI 対応)。null = Job.fallback を使用。
    this.selectedJob,
    // 【FEAT-390】学習力 / 精神力レベル (FEAT-333 stat 連動)
    this.studyLv = 0,
    this.mentalLv = 0,
  });

  // ignore: library_private_types_in_public_api
  final dynamic player; // Player 型 (循環 import 回避のため dynamic、既存パターン)

  /// 【FEAT-390】ATK/ATB 計算に使用するジョブ。
  // ignore: library_private_types_in_public_api
  final Job? selectedJob; // Job 型 (循環 import 回避のため dynamic は不要、直接 Job を使用)

  /// 【FEAT-390】学習力レベル (0 = stat 未取得 or Lv 0)。
  final int studyLv;

  /// 【FEAT-390】精神力レベル (0 = stat 未取得 or Lv 0)。
  final int mentalLv;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final int level = player.level as int;
    final int currentExp = player.currentExp as int;
    final int maxExp = player.maxExp as int;
    final int diamonds = player.diamonds as int;
    final int maxHp = BattleConstants.playerBaseHp
        + level * BattleConstants.playerHpPerLevel;
    final double expPct =
        maxExp == 0 ? 0.0 : (currentExp / maxExp).clamp(0.0, 1.0);

    // 【FEAT-390】ATK / ATB の表示値計算。
    final int weaponAtk = (player.equippedWeapon?.atkBonus as int?) ?? 10;
    final Job job = selectedJob ?? Job.fallback;
    final int displayAtk = BattleDisplay.computeAtk(
      level:               level,
      weaponAtk:           weaponAtk,
      studyLv:             studyLv,
      attackPowerModifier: job.attackPowerModifier,
    );
    final double displayAtb = BattleDisplay.computeAtb(
      atbSpeedModifier: job.atbSpeedModifier,
      mentalLv:         mentalLv,
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        border: Border.all(color: Colors.white24, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Lv + diamonds 行 ─────────────────────────────────
          Row(
            children: [
              const Icon(Icons.military_tech,
                  size: 18, color: AppTheme.primaryLight),
              const SizedBox(width: 6),
              Text(
                'Lv. $level',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              const Text('💎',
                  style: TextStyle(fontSize: 14)),
              const SizedBox(width: 4),
              Text(
                '$diamonds',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ── HP バー（戦闘外は満タン固定） ────────────────────
          _StatBar(
            label: 'HP',
            color: Colors.redAccent,
            value: 1.0,
            valueText: '$maxHp / $maxHp',
          ),
          const SizedBox(height: 6),
          // ── EXP バー ─────────────────────────────────────────
          _StatBar(
            label: 'EXP',
            color: AppTheme.expColor,
            value: expPct,
            valueText: '$currentExp / $maxExp',
          ),
          // ── 【FEAT-390】攻撃力 / ATB 行 ──────────────────────
          const SizedBox(height: 10),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 8),
          Row(
            children: [
              // ── 攻撃力 ───────────────────────────────────────
              const Icon(Icons.flash_on, size: 14, color: Colors.orangeAccent),
              const SizedBox(width: 4),
              Text(
                l10n.battlePartyAtkStatLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(width: 6),
              Text(
                '$displayAtk',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // ── ATB ──────────────────────────────────────────
              const Icon(Icons.bolt, size: 14, color: Colors.cyanAccent),
              const SizedBox(width: 4),
              const Text(
                'ATB',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(width: 6),
              Text(
                BattleDisplay.formatAtb(displayAtb),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// _StatusSection 内の単一の進捗バー行（HP / EXP 共通）。
class _StatBar extends StatelessWidget {
  const _StatBar({
    required this.label,
    required this.color,
    required this.value,
    required this.valueText,
  });

  final String label;
  final Color color;
  final double value;
  final String valueText;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value,
              backgroundColor: Colors.white.withValues(alpha: 0.10),
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 8,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          valueText,
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
      ],
    );
  }
}


/// 【FEAT-326 → FEAT-327】装備スロット表示 (タップで親の EquipmentSelectionOverlay 起動)。
///
/// 旧 FEAT-326 では本タイル内で `WeaponSelectSheet.show()` を直接呼んでいたが、
/// FEAT-327 で guild_equipment_2.md §1.2 「Stack 重ね合わせ」仕様準拠のため、
/// 親 (`_PartyEditDialogState`) で `_isSelectingEquipment` フラグを管理する設計に
/// 変更。本タイルは `onTap` callback を発火するだけで責務を持たない。
///
/// 未装備 (PlayerWeapon 0 件の極端ケース) でも「未装備」と表示してタップ可能、
/// EquipmentSelectionOverlay 側で「Shop で購入してくださいね」ガイドを出す設計。
class _WeaponSlotTile extends StatelessWidget {
  const _WeaponSlotTile({required this.weapon, required this.onTap});

  final WeaponInfo? weapon;

  /// 【FEAT-327】 親 _PartyEditDialogState の `_openEquipmentSelection` を発火する
  /// callback。本 widget は Sheet / Dialog 起動の責務を持たず、純粋に表示と
  /// `onTap` 発火のみ (Pre-mortem #1 BUG-65 系 dialog/navigation race 構造防止)。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = weapon;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.card,
            border: Border.all(color: Colors.white24, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              const Icon(Icons.handyman_outlined, size: 18, color: Colors.white70),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w != null
                      ? l10n.battlePartyWeaponSlotEquipped(w.name, w.atkBonus)
                      : l10n.battlePartyWeaponSlotUnequipped,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.white60),
            ],
          ),
        ),
      ),
    );
  }
}
