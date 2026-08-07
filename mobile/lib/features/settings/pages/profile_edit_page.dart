import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/error_formatter.dart';  // 【FEAT-407】生例外リーク防止
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/utils/character_asset.dart';  // FEAT-123
import '../../../core/utils/friend_id_formatter.dart';  // 【2026-07-02】12 桁化 + 4-4-4 表示
import '../../habits/models/player.dart';
import '../../habits/providers/habits_provider.dart';
import '../providers/settings_provider.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  final _nameController = TextEditingController();
  String _gender = 'f';
  bool _initialized = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _initFromPlayer(Player player) {
    if (_initialized) return;
    _nameController.text = player.name;
    _gender = player.gender;
    _initialized = true;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.settingsProfileEditPageEmptyNameSnackbar)),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(settingsServiceProvider)
          .updateProfile(name: name, gender: _gender);
      // プレイヤー情報を再取得
      ref.invalidate(playerNotifierProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.settingsProfileEditPageSaveSuccessSnackbarSabi_message)),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      // 【FEAT-407】生例外 '$e' 露出を formatApiError(e) 経由のサビ口調 fallback に修正
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(formatApiError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerAsync = ref.watch(playerNotifierProvider);

    playerAsync.whenData(_initFromPlayer);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.settingsProfileEditPageTitle),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(AppLocalizations.of(context)!.settingsProfileEditPageSaveButton,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: playerAsync.when(
        data: (player) => _buildForm(player),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text(AppLocalizations.of(context)!.settingsProfileEditPageErrorSabi_message,
              style: const TextStyle(color: Colors.red)),
        ),
      ),
    );
  }

  Widget _buildForm(Player player) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── アバター ───────────────────────────────────────
          // FEAT-123: アクティブキャラクターの画像を表示
          Center(
            child: CharacterAsset.circleWidget(
              identifier: player.activeCharacter?.imagePath,
              size: 88,
            ),
          ),
          const SizedBox(height: 28),

          // ── 名前 ───────────────────────────────────────────
          Text(l10n.settingsProfileEditPageNameLabel,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            maxLength: 20,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: l10n.settingsProfileEditPageNameHint,
              filled: true,
              // 【FEAT-293】AppTheme.surface は背景同化のため friend_add_page
              // と同じ半透明白 tint に統一。Android で視認性確保。
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                // 【FEAT-293】枠線 alpha 0.1 → 0.20 で視認性確保
                borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.20)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                    color: AppTheme.primary, width: 2),
              ),
              counterStyle:
                  const TextStyle(color: Colors.white38),
            ),
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          const SizedBox(height: 24),

          // ── 性別 ───────────────────────────────────────────
          // 【FEAT-233】3 値化: 'm' / 'f' / 'n' (回答しない)。
          // Backend の PlayerProfile.GENDER_CHOICES と完全整合。
          // 【2026-07-08 hotfix】旧 (label:'その他', value:'o') は Backend の
          // choices に存在せず PATCH で 400 rejection となる bug があった。
          // OnboardingPage (onboarding_page.dart:583-588) と用語 + value を統一。
          Text(l10n.settingsProfileEditPageGenderLabel,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          Row(
            children: [
              _GenderChoice(
                  label: l10n.settingsProfileEditPageGenderMale,
                  value: 'm',
                  selected: _gender == 'm',
                  onTap: () => setState(() => _gender = 'm')),
              const SizedBox(width: 12),
              _GenderChoice(
                  label: l10n.settingsProfileEditPageGenderFemale,
                  value: 'f',
                  selected: _gender == 'f',
                  onTap: () => setState(() => _gender = 'f')),
              const SizedBox(width: 12),
              _GenderChoice(
                  label: l10n.settingsProfileEditPageGenderNoAnswer,
                  value: 'n',
                  selected: _gender == 'n',
                  onTap: () => setState(() => _gender = 'n')),
            ],
          ),
          const SizedBox(height: 28),

          // ── フレンドID (読み取り専用) ──────────────────────
          Text(l10n.settingsProfileEditPageFriendIdLabel,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              children: [
                Text(
                  // 【2026-07-02】12 桁化に伴い 4-4-4 (「0000-0000-0000」) 表示。
                  formatFriendId(player.friendId),
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 15,
                      fontFamily: 'monospace'),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    // 【2026-07-02】コピーは常に `-` なしの raw 数字。
                    Clipboard.setData(ClipboardData(
                        text: stripFriendIdSeparators(player.friendId)));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(l10n.settingsProfileEditPageFriendIdCopiedSnackbar)),
                    );
                  },
                  child: const Icon(Icons.copy,
                      size: 18, color: Colors.white38),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(l10n.settingsProfileEditPageFriendIdReadOnlyNote,
              style: const TextStyle(color: Colors.white24, fontSize: 11)),
        ],
      ),
    );
  }
}

class _GenderChoice extends StatelessWidget {
  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  const _GenderChoice({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.2)
                : AppTheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? AppTheme.primary
                  : Colors.white.withValues(alpha: 0.1),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color:
                    selected ? AppTheme.primary : Colors.white54,
                fontSize: 13,
                fontWeight: selected
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
