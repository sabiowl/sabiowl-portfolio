import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/gamification_models.dart';
import '../providers/gamification_provider.dart';

/// 【FEAT-518 (2026-08-05)】ガチャ排出確率の開示画面。
///
/// App Store Review Guideline 3.1.1 は、有料で引ける randomized item の提供割合を
/// **購入前に** 開示することを求める。本画面はガチャ画面とショップの両方から到達できる。
///
/// 確率は Backend が正規化済みの値 (%) を返すため、ここでは割り算しない
/// (ticket_type ごとに weight 合計が違うので、クライアント計算は誤表示の温床になる)。
class GachaOddsPage extends ConsumerWidget {
  const GachaOddsPage({super.key});

  static const Map<String, Color> _rarityColors = {
    'N': Color(0xFF9E9E9E),
    'R': Color(0xFF42A5F5),
    'SR': AppTheme.rarityPurple,
    'SSR': AppTheme.gold,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final odds = ref.watch(gachaOddsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.gachaOddsTitle)),
      body: odds.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _OddsError(
          message: l10n.gachaOddsLoadFailedSabi_message,
          retryLabel: l10n.gachaOddsRetry,
          onRetry: () => ref.invalidate(gachaOddsProvider),
        ),
        data: (data) => _OddsBody(data: data, rarityColors: _rarityColors),
      ),
    );
  }
}

// ── 本体 ────────────────────────────────────────────────────
class _OddsBody extends StatelessWidget {
  const _OddsBody({required this.data, required this.rarityColors});

  final GachaOdds data;
  final Map<String, Color> rarityColors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          l10n.gachaOddsIntro,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13),
        ),
        const SizedBox(height: 16),
        for (final block in data.ticketTypes)
          _TicketTypeSection(block: block, rarityColors: rarityColors),
        if (data.notes.isNotEmpty) _NotesSection(notes: data.notes),
      ],
    );
  }
}

// ── チケット種別ごとのセクション ────────────────────────────
class _TicketTypeSection extends StatelessWidget {
  const _TicketTypeSection({required this.block, required this.rarityColors});

  final GachaOddsTicketType block;
  final Map<String, Color> rarityColors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      color: AppTheme.card,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              block.label,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _SubHeading(text: l10n.gachaOddsRaritySectionTitle),
            const SizedBox(height: 6),
            for (final r in block.raritySummary)
              _OddsRow(
                leading: _RarityBadge(rarity: r.rarity, colors: rarityColors),
                label: '',
                probability: r.probability,
              ),
            const SizedBox(height: 14),
            _SubHeading(text: l10n.gachaOddsRewardSectionTitle),
            const SizedBox(height: 6),
            for (final reward in block.rewards)
              _OddsRow(
                leading: _RarityBadge(rarity: reward.rarity, colors: rarityColors),
                label: '${reward.icon} ${reward.name}',
                // 【Pre-mortem #3】同名報酬 (Daily の経験値ボーナス 3 種) を
                // 区別できるよう detail を必ず併記する。
                sublabel: reward.detail,
                probability: reward.probability,
              ),
          ],
        ),
      ),
    );
  }
}

class _SubHeading extends StatelessWidget {
  const _SubHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: 0.6),
      ),
    );
  }
}

class _RarityBadge extends StatelessWidget {
  const _RarityBadge({required this.rarity, required this.colors});

  final String rarity;
  final Map<String, Color> colors;

  @override
  Widget build(BuildContext context) {
    final color = colors[rarity] ?? colors['N']!;
    return Container(
      width: 42,
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        rarity,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}

class _OddsRow extends StatelessWidget {
  const _OddsRow({
    required this.leading,
    required this.label,
    required this.probability,
    this.sublabel,
  });

  final Widget leading;
  final String label;
  final String? sublabel;
  final double probability;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: 10),
          // 【CLAUDE.md Flutter 落とし穴】Row 内のテキストは Expanded で囲まないと
          // 長い報酬名 (英語 locale で伸びる) で overflow する。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                  ),
                if (sublabel != null && sublabel!.isNotEmpty)
                  Text(
                    sublabel!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatPercent(probability),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// 小数第 2 位まで意味を持つ (Weekly キャラ = 0.50%)。
  /// 整数で割り切れる場合も桁を揃えたいので常に 2 桁で出す。
  static String _formatPercent(double v) => '${v.toStringAsFixed(2)}%';
}

// ── 注記 ────────────────────────────────────────────────────
class _NotesSection extends StatelessWidget {
  const _NotesSection({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      color: AppTheme.card,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SubHeading(text: l10n.gachaOddsNotesTitle),
            const SizedBox(height: 8),
            for (final note in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '・',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        note,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── エラー ──────────────────────────────────────────────────
class _OddsError extends StatelessWidget {
  const _OddsError({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: 16),
            // 【CLAUDE.md Flutter 落とし穴】Row 内の裸 ElevatedButton は UI が崩れるため
            // ここでは Column 直下に置く (幅は内容に従う)。
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              child: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
