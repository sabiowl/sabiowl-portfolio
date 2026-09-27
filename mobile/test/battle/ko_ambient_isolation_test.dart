// 【FEAT-526】KO 演出がアンビエントバトルの進行を止めないための契約テスト。
//
// 【2026-08-22 方針変更】当初の決定事項 2 は「**バトル画面だけ**。額縁は
// 『ながら見』の前景で、習慣チェック中の邪魔になる」だったが、実機を見た
// ユーザー判断で **額縁でも KO 演出を出す** ことになった。ただし全画面の値を
// そのまま持ち込むと「K.O.」が額縁 (約 344 x 240px) からはみ出し、暗転も
// 既存の暗幕 55% と合わせてほぼ真っ黒になるので **縮小版** を使う。
//
// 🔴 **本当に守らなければいけないのは「見た目」ではなく「進行」の方**
// (指示書 Pre-mortem #2)。
//
// 「演出が終わった」を `BattleSession` などの共有 state や ambient の終了判定に
// 持ち込むと、**フラグが立たないまま報酬処理も次の戦闘も始まらない**。
// ホーム画面のオートバトルが **静かに止まる** ので気付きにくい。
//
// そこで 3 方向から縛る:
//   A. 額縁は **縮小版のスタイル** で、ゲートは **ローカル state** で持つ
//   B. 完了フラグが **共有 state に存在しない**
//   C. アンビエントの終了判定が **status しか見ていない** (演出を待たない)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';

Combatant _dummy() => Combatant(
      id: 'x', name: 'x', spriteKey: 'sabi',
      maxHp: 10, currentHp: 10, atk: 1, spd: 1,
    );

Tactic _tactic() => Tactic.offense;

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path が見つからない (cwd 不一致?)');
  return f.readAsStringSync();
}

void main() {
  group('FEAT-526 A: 額縁は縮小版で、ゲートはローカル', () {
    test('額縁は KoEffectStyle.ambient を使う (全画面の値を持ち込まない)', () {
      final src = _read('lib/features/battle/widgets/mini_battle_arena.dart');
      expect(src.contains('KoEffectOverlay'), isTrue);
      expect(src.contains('KoEffectStyle.ambient'), isTrue,
          reason: '全画面の 64pt / ズーム 1.20 / 暗転 45% は額縁に収まらない');
      expect(src.contains('KoEffectStyle.fullscreen'), isFalse);
    });

    test('🔴 額縁の fadeOut ゲートは koEvent の有無で判定していない', () {
      // 前のバトルの決着済み state が残っていることがあるので、`koEvent` を見て
      // 閉じると **二度と消えなくなる** (battle_page で実際に起きた事故と同型)。
      final src = _read('lib/features/battle/widgets/mini_battle_arena.dart');
      final fadeOutAt = src.indexOf('SpriteAction.fadeOut');
      expect(fadeOutAt, greaterThan(-1), reason: 'fadeOut のゲートが見つからない');
      // 直前の `action:` から fadeOut まで = 三項演算子の条件式そのもの
      // (200 文字窓のような雑な切り出しだと、上のコメント文まで拾ってしまう)
      final gate = src.substring(
        src.lastIndexOf('action:', fadeOutAt),
        fadeOutAt,
      );
      expect(gate, contains('!_koPlaying'),
          reason: '閉じてよいのは「自分が再生中」のときだけ');
      expect(gate, isNot(contains('koEvent')));
    });

    test('🔴 額縁の演出状態はローカル state (共有 state に置かない)', () {
      final src = _read('lib/features/battle/widgets/mini_battle_arena.dart');
      expect(src, contains('bool _koPlaying = false;'),
          reason: '_MiniBattleArenaState のフィールドとして持つこと');
      expect(src, contains('class _MiniBattleArenaState'));
    });

    test('KO 演出を参照している実装ファイルは battle_page と額縁だけ', () {
      // 🔴 **ambient orchestrator がここに現れたら赤信号。**
      // 進行側が演出を知った時点で待ち合わせが生まれる。
      final referencing = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('ko_effect_overlay.dart')) continue;
        if (e.readAsStringSync().contains('KoEffectOverlay')) {
          referencing.add(e.path.split(Platform.pathSeparator).join('/'));
        }
      }
      referencing.sort();
      expect(referencing, [
        'lib/features/battle/pages/battle_page.dart',
        'lib/features/battle/widgets/mini_battle_arena.dart',
      ], reason: '演出の適用範囲が広がったら、その都度ここで気付けるようにする');
    });
  });

  group('FEAT-526 B: 🔴 ゲートのフラグは共有 state に無い', () {
    test('BattleSession に KO 演出の完了フラグが無い', () {
      // 共有 state に置いた瞬間、額縁側でフラグが立たず
      // **アンビエントバトルが静かに止まる**。
      final src = _read('lib/features/battle/providers/battle_provider.dart');
      expect(src.contains('koFinished'), isFalse);
      expect(src.contains('koEffectDone'), isFalse);
      expect(src.contains('KoEffectController'), isFalse);
    });

    test('BattleState が持つ KO 関連は koEvent 1 つだけ', () {
      // モデルに足してよいのは「いつ killing blow が入ったか」だけ (§4.2)。
      final src = _read('lib/features/battle/models/battle_state.dart');
      final koFields = RegExp(r'final\s+\w*[Kk]o\w*\??\s+(\w+);')
          .allMatches(src)
          .map((m) => m.group(1))
          .toList();
      expect(koFields, ['koEvent']);
    });

    test('フラグは battle_page のローカル state にある', () {
      final src = _read('lib/features/battle/pages/battle_page.dart');
      expect(RegExp(r'\n  bool _koPlaying = false;').hasMatch(src), isTrue,
          reason: '_BattlePageState のフィールドとして持つこと');
    });

    test('🔴 ゲートは koEvent の有無で判定していない (2026-08-22 実機報告)', () {
      // `battleSessionProvider` は autoDispose ではないので、**前のバトルの
      // 決着済み state がそのまま残っている**。それを見てゲートを閉じると、
      // 次のバトルに入った瞬間に「もう終わっている他人の KO」を待つことになり、
      // 敵が消えず報酬モーダルも出ない。
      final src = _read('lib/features/battle/pages/battle_page.dart');
      final gate = RegExp(r'bool get _koGateOpen =>([^;]*);').firstMatch(src);
      expect(gate, isNotNull, reason: 'ゲートは _koGateOpen で表現すること');
      expect(gate!.group(1), isNot(contains('koEvent')),
          reason: 'ゲートを閉じてよいのは「自分が再生中」のときだけ');
    });

    test('🔴 initState で KO 演出を発火しない (2026-08-22 実機報告)', () {
      // `startBattle()` は await されておらず、session のリセットは API 往復の
      // 後なので、mount 直後に読める state は **前のバトルのもの**。
      // そこで発火すると、アンビエントで勝った直後にギルドからバトルを始めたとき
      // **前のバトルの KO が流れてから新しいバトルが始まる**。
      final src = _read('lib/features/battle/pages/battle_page.dart');
      final initState = src.substring(
        src.indexOf('void initState()'),
        src.indexOf('Widget build(BuildContext context)'),
      );
      expect(initState.contains('_maybeFireKo('), isFalse,
          reason: 'KO の発火は ref.listen の遷移検知だけに任せること');
    });
  });

  group('FEAT-526 C: アンビエントの終了処理が演出を待たない', () {
    test('_awaitBattleCompletion は status だけをトリガーにしている', () {
      final src =
          _read('lib/features/battle/services/ambient_auto_battle_orchestrator.dart');
      expect(src.contains('BattleStatus.won'), isTrue);
      expect(src.contains('koEvent'), isFalse,
          reason: '演出の完了を待ち始めると、額縁側で永久に完了しない');
      expect(src.contains('KoEffect'), isFalse);
    });

    test('koEvent が立っていても status は won のまま = 終了判定に影響しない', () {
      // アンビエント側は `status == won` を見ているだけなので、
      // `koEvent` が増えても判定は 1 mm も変わらない —— を型で示す。
      final base = BattleState(
        player: _dummy(), enemy: _dummy(), tactic: _tactic(),
        status: BattleStatus.won, logLines: const [],
      );
      final withKo = base.copyWith(
        koEvent: KoEvent(damage: 10, isCritical: false),
      );
      expect(withKo.status, BattleStatus.won);
      expect(base.status, withKo.status);
    });

    test('BattleSession.copyWith は koEvent 付き state をそのまま運ぶ', () {
      final s = BattleState(
        player: _dummy(), enemy: _dummy(), tactic: _tactic(),
        status: BattleStatus.won, logLines: const [],
        koEvent: KoEvent(damage: 7, isCritical: true),
      );
      final session = const BattleSession().copyWith(state: s);
      expect(session.state!.koEvent!.damage, 7);
      expect(session.state!.koEvent!.isCritical, isTrue);
    });
  });

  // ── 【2026-08-22 実機報告】額縁の KO 演出が一度も出ていなかった ──────────
  //
  // 🔴 真因は額縁側ではなく **ホスト (`WorldFrameSection`) の出し入れ条件**だった。
  //
  // 旧実装:
  //     final inBattle = session.state != null
  //         && session.state!.status == BattleStatus.running;
  //
  // KO 演出は `koEvent` と **同じ state 更新**で始まる。その更新では `status` が
  // 同時に `won` へ変わるので、`inBattle` は false になり **`MiniBattleArena` は
  // 演出が 1 フレームも描かれないまま unmount される**。
  //
  // FEAT-526 の額縁テストは `MiniBattleArena` を直接 mount していたため、
  // **ホストの出し入れ条件を一度も通っていなかった** —— だから緑のまま実機で
  // 出なかった。ここではホスト側の条件を縛る。
  group('FEAT-526 D: 🔴 ホストは決着の瞬間に額縁を畳まない', () {
    String section() =>
        _read('lib/features/habits/widgets/world_frame/world_frame_section.dart');

    test('額縁の表示条件が status == running だけになっていない', () {
      final src = section();
      final gate = RegExp(r'final inBattle = ([\s\S]{0,400}?);').firstMatch(src);
      expect(gate, isNotNull, reason: '表示条件は inBattle で表現すること');
      final expr = gate!.group(1)!;
      expect(expr, contains('BattleStatus.running'));
      expect(expr, contains('koPending'),
          reason: 'running だけで畳むと KO 演出が描かれる前に unmount される');
    });

    test('畳んでよいかは「子からの合図」で決めている', () {
      final src = section();
      expect(src, contains('onKoDone: _onKoDone'),
          reason: 'MiniBattleArena に後片付けの合図を受け取る口を渡すこと');
      expect(src, contains('KoEvent? _koDoneFor;'),
          reason: 'どの決着まで畳んだかを覚えていないと、次のバトルで判定できない');
    });

    test('🔴 ホストは演出そのものを知らない (待ち合わせを作らない)', () {
      // Pre-mortem #2 の延長。ホストが知ってよいのは「もう畳んでよいか」だけで、
      // 演出の中身 (controller / 再生中フラグ) を持ち込むと待ち合わせが生まれる。
      final src = section();
      expect(src.contains('KoEffectController'), isFalse);
      expect(src.contains('KoEffectOverlay'), isFalse);
      expect(src.contains('_koPlaying'), isFalse);
    });

    test('合図が来なくても戻れる保険がある', () {
      // 合図が永久に来ないと、今度は **額縁が世界の絵の上に出たまま**になる。
      final src = _read('lib/features/battle/widgets/mini_battle_arena.dart');
      expect(src, contains('_koFallbackTimer'),
          reason: '演出が完了しなかった場合の強制復帰が要る');
      expect(RegExp(r'_koFallbackTimer\?\.cancel\(\);[\s\S]{0,200}?super\.dispose\(\);')
          .hasMatch(src), isTrue,
          reason: 'dispose で必ず cancel すること (BUG-66 系の Timer 残り)');
    });
  });

}
