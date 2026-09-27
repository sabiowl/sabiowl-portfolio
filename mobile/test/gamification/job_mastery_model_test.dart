// 【2026-08-09】JobMastery の EXP 意味論を固定する。
//
// ## なぜ必要か
//
// `exp_to_next` という API field 名は「次の Lv までの**残り**」と読めるが、
// Backend が入れているのは `calc_job_mastery_exp_to_next(level)` =
// **そのレベルを突破するのに必要な総量**で、貯めた分は引かれていない
// (`views/job_mastery.py` / `services/battle_finish_service.py`)。
//
// この取り違えが実際に 2 つのバグを生んだ (2026-08-09 にユーザー報告から発覚):
//
//   1. `expProgress` が `exp / (exp + expToNext)` —— 分母が二重に膨らみ、
//      Lv 1 で 1 勝した状態 (exp=5 / expToNext=10) のバーが 50% ではなく **33%**
//   2. 表示文言が「あと {expToNext} EXP」—— 上記の状態で「あと 10 EXP」と出ていた
//      (正しくは 5)
//
// しかも `job_selection_overlay_test.dart` の S6 が「あと 30 EXP」を期待しており、
// **バグを正解として固定していた**。名前から意味を推測できない以上、
// 数値例で縛る以外に再発を止める手段がない。
//
// 実行方法:
// ```powershell
// cd mobile; flutter test test/gamification/job_mastery_model_test.dart
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/gamification/models/job_mastery.dart';

JobMastery _m({
  required int level,
  required int exp,
  required int expToNext,
  bool isMaxed = false,
}) =>
    JobMastery(
      jobId: 'dark_mage',
      jobName: '闇魔導士',
      level: level,
      exp: exp,
      expToNext: expToNext,
      isMaxed: isMaxed,
    );

void main() {
  group('JobMastery: exp / expToNext の意味論', () {
    test('expToNext は「必要な総量」。expProgress は exp / expToNext', () {
      // Lv 1 で小ボスに 1 勝 = 5 EXP。Lv 1→2 の必要量は 10 (= 1*1*2 + 1*4 + 4)。
      final m = _m(level: 1, exp: 5, expToNext: 10);

      expect(m.expProgress, 0.5,
          reason: '5 / 10 = 50%。旧実装の 5 / (5 + 10) = 33% ではない');
    });

    test('残りは expRemaining で求める (expToNext ではない)', () {
      final m = _m(level: 1, exp: 5, expToNext: 10);

      expect(m.expRemaining, 5,
          reason: '「あと N EXP」に使えるのは expToNext ではなく expToNext - exp');
      expect(m.expToNext, 10,
          reason: 'expToNext 自体は総量のまま (残量に書き換えない)');
    });

    test('Lv 内進捗が 0 のときは 0%', () {
      // Lv アップ直後。Backend が必要量を差し引くので exp は 0 に戻る。
      final m = _m(level: 2, exp: 0, expToNext: 20);

      expect(m.expProgress, 0.0);
      expect(m.expRemaining, 20);
    });

    test('Max では 100% 固定、残りは 0', () {
      // Backend は Max 到達時に exp を 0 へキャップし exp_to_next も 0 を返す。
      final m = _m(level: 10, exp: 0, expToNext: 0, isMaxed: true);

      expect(m.expProgress, 1.0,
          reason: 'Max は満タン表示。0 / 0 で NaN にしない');
      expect(m.expRemaining, 0);
    });

    test('想定外の値でも 0.0-1.0 に収まる', () {
      // Backend 側の計算式を変えた過渡期など、exp > expToNext があり得る。
      // バーが 1.0 を超えると LinearProgressIndicator が assertion で落ちる。
      final m = _m(level: 3, exp: 999, expToNext: 34);

      expect(m.expProgress, 1.0);
      expect(m.expRemaining, 0, reason: '負の残量を出さない');
    });

    test('exp_to_next が欠落した旧レスポンスでも落ちない', () {
      final m = JobMastery.fromJson(const {
        'job_id': 'warrior',
        'job_name': '戦士',
        'level': 1,
        'exp': 0,
      });

      expect(m.expToNext, 0);
      expect(m.expProgress, 1.0, reason: 'ゼロ除算を避けるための既定');
    });
  });
}
