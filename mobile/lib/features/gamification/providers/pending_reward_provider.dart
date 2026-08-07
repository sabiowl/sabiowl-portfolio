import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/gamification_models.dart';
import '../services/gamification_service.dart';
import '../../habits/providers/habits_provider.dart' show playerNotifierProvider;
import 'gamification_provider.dart';

class PendingRewardsNotifier
    extends StateNotifier<AsyncValue<List<PendingReward>>> {
  PendingRewardsNotifier(this._service, this._ref)
      : super(const AsyncValue.loading()) {
    _load();
  }

  final GamificationService _service;
  final Ref _ref;

  Future<void> _load() async {
    try {
      final list = await _service.fetchPendingRewards();
      // BUG-H: autoDispose で破棄された後の state 代入を防ぐ。
      if (!mounted) return;
      state = AsyncValue.data(
        list.map((e) => PendingReward.fromJson(e)).toList(),
      );
    } catch (e, st) {
      if (!mounted) return;
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> reload() => _load();

  /// 交換を実行する。成功時は true、失敗時は false を返す。
  Future<bool> exchange(int pendingId, String exchangeType) async {
    try {
      await _service.exchangeDuplicate(pendingId, exchangeType);
      await _load();
      // 【FEAT-497 (2026-08-04)】交換で増えた残高を PlayerProfile に反映する。
      //
      // 交換は `exchange_pieces` (or `allocatable_points`) を増やすが、旧実装は
      // pending 一覧を再取得するだけで player を invalidate していなかった。
      // ピースを受け取った直後に Shop の「ピース」タブを開くと **残高 0 のまま**
      // 見え、本 FEAT が解消しようとしている「使えない通貨」の印象そのものになる。
      _ref.invalidate(playerNotifierProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final pendingRewardsProvider = StateNotifierProvider.autoDispose<
    PendingRewardsNotifier, AsyncValue<List<PendingReward>>>(
  (ref) => PendingRewardsNotifier(ref.watch(gamificationServiceProvider), ref),
);
