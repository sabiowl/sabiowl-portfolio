import 'package:flutter/material.dart';

import '../../../shared/widgets/sabi_loading_skeleton.dart';

/// 【FEAT-202】習慣ヘッダー領域（プレイヤー情報 + ステータス）のスケルトン。
///
/// 旧実装は「スケルトン」を名乗りながら中身が `CircularProgressIndicator` で、
/// 形状は何も伝わらないガワだけスケルトンだった。本実装で実カードの形状
/// （アバター + 名前 + レベル + EXP バー + ステータス 4 チップ）を Shimmer で
/// モックし、「もうすぐここに来ます」を視覚的に予告する。
class HeaderSkeleton extends StatelessWidget {
  const HeaderSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: const [
          // プロフィール行（アバター + 名前 + レベルバッジ）
          Row(
            children: [
              SabiSkeletonBox(width: 56, height: 56, borderRadius: 28),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SabiSkeletonBox(width: 120, height: 14),
                    SizedBox(height: 8),
                    SabiSkeletonBox(width: 80, height: 10),
                  ],
                ),
              ),
              SabiSkeletonBox(width: 60, height: 24, borderRadius: 12),
            ],
          ),
          SizedBox(height: 16),
          // EXP バー
          SabiSkeletonBox(
            width:  double.infinity,
            height: 8,
          ),
          SizedBox(height: 12),
          // ステータス 4 種チップ行（FEAT-201 で 4 値に統一: 運動/学習/健康/メンタル）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SabiSkeletonBox(width: 70, height: 32, borderRadius: 16),
              SabiSkeletonBox(width: 70, height: 32, borderRadius: 16),
              SabiSkeletonBox(width: 70, height: 32, borderRadius: 16),
              SabiSkeletonBox(width: 70, height: 32, borderRadius: 16),
            ],
          ),
        ],
      ),
    );
  }
}
