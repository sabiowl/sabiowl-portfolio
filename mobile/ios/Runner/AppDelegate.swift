import Flutter
import UIKit
import CoreHaptics

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// 【新規 (2026-06-26)】バトル必殺技演出用 Core Haptics エンジン。
  /// iOS 13+ + Taptic Engine 搭載端末でのみ有効。
  private var hapticEngine: CHHapticEngine?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // ── MethodChannel "sabiowl/battle_haptics" ハンドラ登録 ─────────────────
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "sabiowl/battle_haptics",
      binaryMessenger: controller.binaryMessenger
    )

    // Core Haptics 利用可否を起動時に判定 (端末非対応なら nil のまま)
    if #available(iOS 13.0, *), CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        hapticEngine = try CHHapticEngine()
        try hapticEngine?.start()
        // バックグラウンド復帰時に engine 再起動 (Apple 公式パターン)
        hapticEngine?.resetHandler = { [weak self] in
          do {
            try self?.hapticEngine?.start()
          } catch {
            NSLog("[BattleHaptics] engine reset failed: \(error.localizedDescription)")
          }
        }
        hapticEngine?.stoppedHandler = { _ in
          // 停止イベント (resignActive 等) は Dart 側で次回再生時に再起動する
        }
      } catch {
        NSLog("[BattleHaptics] engine init failed: \(error.localizedDescription)")
        hapticEngine = nil
      }
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "gaugeMax":
        result(self.playGaugeMax())
      case "buttonPress":
        result(self.playButtonPress())
      case "ultimateHit":
        result(self.playUltimateHit())
      // 【2026-06-27】通常攻撃 / クリ命中 (CLAUDE.md FEAT-296 「3 段防御 +
      // 強度別分離」哲学の延長、buttonPress→normalHit→gaugeMax→criticalHit→
      // ultimateHit の intensity 階段で差別化)。
      case "normalHit":
        result(self.playNormalHit())
      case "criticalHit":
        result(self.playCriticalHit())
      // 【FEAT-526】とどめの一撃。ultimateHit と違い **上昇して終わる**
      // (「強く当たった」ではなく「勝った」を返すため)。
      case "koFinish":
        result(self.playKoFinish())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 必殺ゲージ MAX (中程度 ~100ms 単発)
  // ──────────────────────────────────────────────────────────────────────────
  private func playGaugeMax() -> Bool {
    if #available(iOS 13.0, *), let engine = hapticEngine {
      do {
        // intensity 0.6 + sharpness 0.5 で「中程度の Von」
        let event = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
          ],
          relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        return true
      } catch {
        NSLog("[BattleHaptics] gaugeMax failed: \(error.localizedDescription)")
      }
    }
    // Fallback: UIImpactFeedbackGenerator medium
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
    return true
  }

  // ──────────────────────────────────────────────────────────────────────────
  // ボタン押下 (極軽い tap)
  // ──────────────────────────────────────────────────────────────────────────
  private func playButtonPress() -> Bool {
    if #available(iOS 13.0, *), let engine = hapticEngine {
      do {
        // intensity 0.25 + sharpness 0.4 で「ほぼ感じない極軽い tap」
        let event = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
          ],
          relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        return true
      } catch {
        NSLog("[BattleHaptics] buttonPress failed: \(error.localizedDescription)")
      }
    }
    // Fallback: UISelectionFeedbackGenerator (Apple 標準で最も軽い)
    let generator = UISelectionFeedbackGenerator()
    generator.prepare()
    generator.selectionChanged()
    return true
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 【2026-06-27】通常攻撃命中 (短い軽い tap、ターン制ATBで頻繁発火)
  //
  // CLAUDE.md FEAT-296 の強度階段 (buttonPress 0.25 → normalHit 0.35 →
  // gaugeMax 0.6) に整合。「コツン」と当たった存在感を最小強度で提供。
  // クリティカル (playCriticalHit、intensity 0.75) と明確に差別化される。
  // ──────────────────────────────────────────────────────────────────────────
  private func playNormalHit() -> Bool {
    if #available(iOS 13.0, *), let engine = hapticEngine {
      do {
        // intensity 0.35 + sharpness 0.5 で「軽い当たり感」
        let event = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
          ],
          relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        return true
      } catch {
        NSLog("[BattleHaptics] normalHit failed: \(error.localizedDescription)")
      }
    }
    // Fallback: UISelectionFeedbackGenerator (Apple 標準の軽い tap)
    let generator = UISelectionFeedbackGenerator()
    generator.prepare()
    generator.selectionChanged()
    return true
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 【2026-06-27】クリティカル命中 (短い強パルス、通常攻撃と明確に別感触)
  //
  // intensity 0.75 + sharpness 0.85 で「ガツン」と決まった感を演出。
  // 通常攻撃 (normalHit 0.35) より明らかに強く、ultimateHit (0.8 + 波形)
  // より短い単発で「クリの瞬間」を強調。必殺技と差別化される設計。
  // ──────────────────────────────────────────────────────────────────────────
  private func playCriticalHit() -> Bool {
    if #available(iOS 13.0, *), let engine = hapticEngine {
      do {
        let event = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85),
          ],
          relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        return true
      } catch {
        NSLog("[BattleHaptics] criticalHit failed: \(error.localizedDescription)")
      }
    }
    // Fallback: UIImpactFeedbackGenerator heavy (Apple 標準で最も強い impact)
    let generator = UIImpactFeedbackGenerator(style: .heavy)
    generator.prepare()
    generator.impactOccurred()
    return true
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 必殺技命中 (250-350ms 余韻ある「ヴヴーーーン」)
  //
  // 波形設計:
  //   t=0.00s, transient (intensity 1.0, sharpness 1.0)   ← 初撃 (鋭く強く)
  //   t=0.05s, continuous 0.20s (intensity 0.8, sharpness 0.5)  ← 余韻メイン「ヴーーー」
  //   t=0.25s, continuous 0.10s (intensity 0.4, sharpness 0.3)  ← 減衰末尾「ン」
  //
  // 合計 ~350ms、強度が段階的に減衰する余韻パターン。
  // ──────────────────────────────────────────────────────────────────────────
  private func playUltimateHit() -> Bool {
    if #available(iOS 13.0, *), let engine = hapticEngine {
      do {
        let initialBurst = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
          ],
          relativeTime: 0
        )
        let mainBody = CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
          ],
          relativeTime: 0.05,
          duration: 0.20
        )
        let tail = CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
          ],
          relativeTime: 0.25,
          duration: 0.10
        )
        let pattern = try CHHapticPattern(
          events: [initialBurst, mainBody, tail],
          parameters: []
        )
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        return true
      } catch {
        NSLog("[BattleHaptics] ultimateHit failed: \(error.localizedDescription)")
      }
    }
    // Fallback: UIImpactFeedbackGenerator chain で余韻を模倣
    let heavy = UIImpactFeedbackGenerator(style: .heavy)
    let medium = UIImpactFeedbackGenerator(style: .medium)
    let light = UIImpactFeedbackGenerator(style: .light)
    heavy.prepare()
    medium.prepare()
    light.prepare()
    heavy.impactOccurred()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
      heavy.impactOccurred()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      medium.impactOccurred()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
      light.impactOccurred()
    }
    return true
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 【FEAT-526 (2026-08-22)】とどめの一撃 (380ms「一撃 → 間 → 祝祭」)
  //
  // ultimateHit との違いは **終わり方**。ultimateHit は減衰して消える
  // (「強く当たった」)。こちらは上昇して終わる (「勝った」)。
  //
  // 波形設計:
  //   t=0.00s  transient  intensity 1.00 / sharpness 1.00  ← とどめの一撃「ドン」
  //     (0.06 - 0.18s は無音 = ヒットストップの「間」。ここがいちばん大事で、
  //      詰めるとただの連打になって「決めた」感が消える)
  //   t=0.18s  transient  intensity 0.55 / sharpness 0.70  ← 祝祭 1「タ」
  //   t=0.24s  transient  intensity 0.75 / sharpness 0.70  ← 祝祭 2「タ」
  //   t=0.31s  continuous 0.07s intensity 1.00 / sharpness 0.55 ← 祝祭 3「ターン」
  //
  // 合計 ~380ms。最後だけ continuous にして「ン」の伸びを作っている。
  // ──────────────────────────────────────────────────────────────────────────
  private func playKoFinish() -> Bool {
    if #available(iOS 13.0, *), let engine = hapticEngine {
      do {
        let finishingBlow = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
          ],
          relativeTime: 0
        )
        let celebration1 = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
          ],
          relativeTime: 0.18
        )
        let celebration2 = CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
          ],
          relativeTime: 0.24
        )
        let celebration3 = CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55),
          ],
          relativeTime: 0.31,
          duration: 0.07
        )
        let pattern = try CHHapticPattern(
          events: [finishingBlow, celebration1, celebration2, celebration3],
          parameters: []
        )
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        return true
      } catch {
        NSLog("[BattleHaptics] koFinish failed: \(error.localizedDescription)")
      }
    }
    // Fallback: 一撃 → 間 → 上昇 3 連 を UIImpactFeedbackGenerator で近似する。
    let heavy = UIImpactFeedbackGenerator(style: .heavy)
    let medium = UIImpactFeedbackGenerator(style: .medium)
    let light = UIImpactFeedbackGenerator(style: .light)
    heavy.prepare()
    medium.prepare()
    light.prepare()
    heavy.impactOccurred()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      light.impactOccurred()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      medium.impactOccurred()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) {
      heavy.impactOccurred()
    }
    return true
  }
}
