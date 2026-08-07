import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Google / Apple サインインボタン共通ウィジェット
class SocialSignInButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool isLoading;
  final VoidCallback? onPressed;
  final Color? backgroundColor;

  const SocialSignInButton({
    super.key,
    required this.icon,
    required this.label,
    this.isLoading = false,
    this.onPressed,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor ?? const Color(0xFF2A2A3E),
          disabledBackgroundColor:
              (backgroundColor ?? const Color(0xFF2A2A3E)).withValues(alpha: 0.5),
          elevation: 0,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Google ロゴ（白丸に青い "G"）
class GoogleLogoIcon extends StatelessWidget {
  const GoogleLogoIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: const Text(
        'G',
        style: TextStyle(
          color: Color(0xFF4285F4),
          fontWeight: FontWeight.bold,
          fontSize: 15,
        ),
      ),
    );
  }
}

/// Apple ロゴ（HIG 準拠の Apple silhouette icon、FontAwesome 経由）。
///
/// 【FEAT-289】旧実装は U+F8FF（Apple Private Use Area の Apple ロゴ文字）を
/// `Text('')` で表示していたが、Sabiowl の theme でカスタムフォント（Noto Sans JP）
/// を全体適用しているため iOS でも該当グリフが解決されず**空欄**で描画される
/// 不具合があった。FontAwesomeIcons.apple は brand icon 用フォントを明示的に
/// 同梱するため、theme のカスタムフォントに干渉されず確実に描画される。
class AppleLogoIcon extends StatelessWidget {
  const AppleLogoIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return const FaIcon(
      FontAwesomeIcons.apple,
      size:  22,
      color: Colors.white,
    );
  }
}
