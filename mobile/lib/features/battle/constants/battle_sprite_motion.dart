/// 【FEAT-527 (2026-08-22)】バトルスプライトの攻撃モーション定義。
///
/// ## 何をするものか
///
/// 従来、攻撃は **絵ではなくコード**で表現していた。`CombatantSprite` が
/// `charge` で x 方向に ±8px 動かし、`slash` で白い斜線を重ねるだけで、
/// キャラクターの絵そのものは立ち絵 1 枚のまま静止していた。
///
/// 本クラスは「このキャラは攻撃フレームを持っているか」を一元的に答える。
/// 持っていれば `CombatantSprite` がフレームを差し替えて再生し、
/// 持っていなければ **従来どおりの Transform 演出** で動く。
///
/// ## 🔴 段階導入が前提
///
/// 素材は 1 体ずつ増える。**全キャラが揃うまで混在する**ので、
/// フォールバックが常に成立していることが本機能の前提条件になる。
/// [has] が false のキャラは 1 行も挙動が変わってはいけない。
///
/// ## タイミングを固定値にしている理由
///
/// 攻撃演出の時間軸は `BattleOrchestrator._triggerAttackEffect` が持っている。
///
///     t=0    : charge  (攻撃者) / recoil (被攻撃者) + ダメージ数値
///     t=200ms: slash   (斬撃線)
///     t=500ms: idle    に復帰 + ダメージ数値クリア
///
/// これらは `Duration(milliseconds: 200)` のような **固定値**で、
/// 倍速モード (`speedMultiplier`) の影響を受けない。ATB ゲージの進みだけが
/// 倍速で、演出の長さは変わらない既存仕様である。
///
/// したがってフレーム送りも固定値に揃える。[frameStep] × 4 = 400ms で
/// 500ms の窓に収まり、**3 枚目 (= [impactFrameIndex]) がちょうど t=200ms の
/// 斬撃と重なる**。ここを合わせないと「斬撃線が出たのに手はまだ振りかぶって
/// いる」というズレた絵になる。
library;

class BattleSpriteMotion {
  BattleSpriteMotion._();

  /// 攻撃フレームを持つ `spriteKey` の集合。
  ///
  /// **素材を追加したらここに 1 行足す。** ファイルを置いただけでは有効にならない
  /// のは意図的で、「置いたが未検証」の素材が黙って本番に出るのを防ぐため。
  static const Set<String> _withAttackFrames = {
    'aria',
    'sol',
    'lucia',
    'faye',
    'rune',
    'beatrix',
  };

  /// 総フレーム数。
  static const int frameCount = 4;

  /// 1 フレームの表示時間。`frameStep` × [frameCount] = 400ms。
  ///
  /// 倍速では変えない (上記 library docstring 参照)。
  static const Duration frameStep = Duration(milliseconds: 100);

  /// 命中フレーム (0 始まり)。`t = frameStep × 2 = 200ms` で
  /// `BattleOrchestrator` の `slash` と重なる。
  static const int impactFrameIndex = 2;

  /// フレーム再生の総時間。
  static Duration get totalDuration => frameStep * frameCount;

  /// [spriteKey] が攻撃フレームを持つか。
  static bool has(String spriteKey) => _withAttackFrames.contains(spriteKey);

  /// 待機時に使う立ち絵。
  ///
  /// 攻撃フレームと**同じ絵柄**で描かれた専用の立ち絵を使う。
  /// 既存の `<key>.webp` を使うと、攻撃のたびに絵柄が入れ替わって見える
  /// (頭身・装飾・オーラの有無が違うため)。
  static String idlePath(String spriteKey) =>
      'assets/images/battle/${spriteKey}_idle.webp';

  /// [index] 番目 (0 始まり) の攻撃フレーム。
  static String framePath(String spriteKey, int index) =>
      'assets/images/battle/${spriteKey}_attack_${index + 1}.webp';

  /// 再生位置 (0.0〜1.0) をフレーム番号に変換する。
  ///
  /// 終端 (1.0) は [frameCount] になってしまうので最終フレームに丸める。
  /// **最終フレームで止まる**のが正しい —— 攻撃後は `slash` の余韻を経て
  /// `idle` に戻るため、途中のフレームで止まると姿勢が飛ぶ。
  static int frameIndexFor(double progress) {
    final raw = (progress * frameCount).floor();
    return raw.clamp(0, frameCount - 1);
  }
}
