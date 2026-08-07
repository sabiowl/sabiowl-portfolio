import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import './timeline_body.dart';

// ── 空の状態 ──────────────────────────────────────────────────────────────────

class TimelineEmptyState extends StatelessWidget {
  const TimelineEmptyState({super.key, required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          AddEventRow(onAdd: onAdd),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context)!.timelineEmptyStateSabi_message,
            style: TextStyle(
              color:    Colors.white.withValues(alpha: 0.2),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
