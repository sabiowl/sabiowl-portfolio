// 【FEAT-499 (2026-07-26)】音声入力共通サービス層。
//
// フリーメモ（FEAT-499）で先行導入、将来 FEAT-492（Habit/ToDo/Event 3 画面）と共有。
//
// 設計方針:
// - listen() は Future<String> を返す（Completer 経由でコールバック API をラップ）
// - stop() で手動停止 → STT が finalResult を onResult に送信 → listen() が解決
// - cancel() は dispose 時の緊急停止用（認識結果を破棄）
// - _permanentError フラグ: permanent エラー後のみ SpeechToText を再作成してリセット
//
// Android 互換性 (2026-07-26):
// - 旧実装は listen() のたびに SpeechToText を再作成していたため、
//   _startVoiceInput() の initialize() と listen() 内の initialize() で
//   二重 SpeechRecognizer 作成が発生。Android は同時 1 セッション制限があり、
//   Samsung Galaxy では error_speech_timeout (permanent: true) が即座に fire していた。
// - 対策: permanent error 時のみ _stt を再作成。通常の listen() では同一インスタンスを
//   再利用することで Android SpeechRecognizer のコンフリクトを回避。
import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:speech_to_text/speech_to_text.dart';

class VoiceInputService {
  static final VoiceInputService _instance = VoiceInputService._();
  static VoiceInputService get instance => _instance;
  VoiceInputService._() : _stt = SpeechToText();

  /// 【FEAT-501 B (2026-07-26)】テスト用 seam。fake SpeechToText を注入して
  /// listen/initialize の契約 (TypeError 経路 / 中間結果フォールバック / timeout /
  /// permanent error 後の再生成) をユニットテスト化する。本番経路では singleton
  /// (instance) のみを使い、本コンストラクタは触らない (@visibleForTesting)。
  @visibleForTesting
  VoiceInputService.forTest(SpeechToText stt) : _stt = stt;

  /// 【FEAT-501 B (2026-07-26)】permanent error 後の SpeechToText 再生成に使う
  /// factory。本番は SpeechToText() を返す。テストでは 2 つ目の fake を返すよう
  /// 差し替え、「permanent error → 次の initialize で再生成」契約を検証する
  /// (@visibleForTesting)。
  @visibleForTesting
  SpeechToText Function() sttFactory = SpeechToText.new;

  SpeechToText _stt;
  bool _initialized = false;
  // permanent error 後は次の initialize() で新しいインスタンスを作成してリセット
  bool _permanentError = false;
  Completer<String>? _listenCompleter;
  String? _lastError;
  // 直前 listen セッションの最新中間認識テキスト。onStatus フォールバックで使用。
  // Samsung では onResults(最終) が空になるケースがあるため、中間結果をインスタンス変数で保持。
  String _lastPartialWords = '';

  bool get isListening => _stt.isListening;

  /// 直前の listen() で発生したエラー文字列。
  /// 正常完了・手動停止時は null。'initialization_failed' / 'listen_not_started'
  /// / 'listen_exception' は起動失敗、それ以外は STT エラーコード。
  String? get lastError => _lastError;

  /// 権限確認 + STT 初期化。
  /// 戻り値: true = 利用可能、false = 権限拒否 or 非対応デバイス。
  Future<bool> initialize() async {
    // permanent error 後は新しいインスタンスで完全リセット（Android SpeechRecognizer を刷新）
    // 【FEAT-501 B】再生成は sttFactory 経由 (テストで差し替え可能)。
    if (_permanentError) {
      _stt = sttFactory();
      _initialized = false;
      _permanentError = false;
    }

    if (_initialized && _stt.isAvailable) return true;

    _initialized = await _stt.initialize(
      debugLogging: kDebugMode,
      onStatus: (status) {
        debugPrint('[VoiceInputService] STT status: $status');
        // STT 停止時（エラー or 正常終了）に Completer を完了させる。
        // 正常終了では onResult(finalResult: true) が先に完了させるため no-op になる。
        // 100ms 猶予は onResult が先に発火するのを確実に待つため。
        if (status == 'notListening' || status == 'done') {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
              // Samsung では onResults(最終) が空になるため、
              // 中間認識結果 _lastPartialWords をフォールバックとして使用。
              _listenCompleter!.complete(_lastPartialWords);
            }
          });
        }
      },
      onError: (error) {
        _lastError = error.errorMsg;
        debugPrint(
          '[VoiceInputService] STT error: ${error.errorMsg}'
          ' (permanent: ${error.permanent})',
        );
        if (error.permanent) {
          // permanent error = 次回 listen() で新しい SpeechToText インスタンスが必要
          _permanentError = true;
        }
      },
    );
    return _initialized && _stt.isAvailable;
  }

  /// 録音開始 → 認識完了まで待ち、認識テキストを返す。
  ///
  /// 空文字 = 無音 / 認識失敗 / 手動 cancel。
  /// 発生したエラーは [lastError] で参照可能（null = エラーなし）。
  /// [timeout] 経過後は自動停止（デフォルト 30 秒）。
  /// [onPartial] は中間結果のコールバック（optional、UI プレビュー用）。
  /// [onSoundLevel] は音量 (dB) の変化コールバック（optional、波形連動 UI 用）。
  ///   speech_to_text v7.3 の SpeechSoundLevelChange 経由。
  ///   Apple Speech の値域は概ね -2〜10 (dB)、Android は端末依存。
  Future<String> listen({
    Duration timeout = const Duration(seconds: 30),
    void Function(String partial)? onPartial,
    void Function(double level)? onSoundLevel,
  }) async {
    _lastError = null;

    // _startVoiceInput() で initialize() 済みの場合は同一インスタンスを再利用。
    // permanent error フラグが立っている場合は initialize() 内で再作成。
    if (!await initialize()) {
      _lastError = 'initialization_failed';
      return '';
    }

    // 前回の未完了 listen があれば中断（多重呼び出し防止）
    if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
      _listenCompleter!.complete('');
    }
    _listenCompleter = Completer<String>();
    // 【FEAT-501 A (2026-07-26)】ローカル捕捉。cancel() が _listenCompleter を
    // null にした後に遅延 onResult が到達しても、この local completer 経由なら
    // null check 例外にならず安全に isCompleted 判定できる (S2 予防)。
    final completer = _listenCompleter!;
    _lastPartialWords = '';

    bool started;
    try {
      started = await _stt.listen(
        onResult: (result) {
          _lastPartialWords = result.recognizedWords;
          debugPrint(
            '[VoiceInputService] onResult: "$_lastPartialWords"'
            ' (final: ${result.finalResult})',
          );
          if (!result.finalResult) {
            onPartial?.call(_lastPartialWords);
          } else {
            if (!completer.isCompleted) {
              completer.complete(_lastPartialWords);
            }
          }
        },
        // 【FEAT-499 v1.0 増分 (2026-07-26)】音量 callback を波形 UI へ橋渡し。
        // Apple Speech は -2〜10 (dB)、Android は端末依存で 0〜10 程度。
        // 呼出元 (memo_page.dart) で clamp + 平滑化を行う。
        onSoundLevelChange: onSoundLevel,
        // speech_to_text v7: 旧 named params は SpeechListenOptions に集約。
        // pauseFor: Samsung 等で即時 error_speech_timeout が発生するケースへの対策。
        //   pauseFor がないと SpeechRecognizer が停止条件を見つけられず即タイムアウトする場合がある。
        // listenMode: deviceDefault — dictation は Samsung 等で即時失敗の原因になるケースあり。
        // localeId: 省略 — 端末の既定言語を使用（日本語設定なら ja_JP が自動適用）。
        //
        // 【FEAT-499 §2-1 B案 (2026-07-26)】onDevice は意図的に未指定 (既定 false)。
        // 意味: OS が端末内 / ネットワーク認識を状況に応じて選択する。
        //   - onDevice: true にすると端末内モデル未導入端末で listen 自体が失敗するため
        //     (speech_to_text package doc: "it cannot do this the listen attempt will fail")、
        //     v1.0.4 は機能提供性を優先して未指定を選択した。
        //   - プライバシー開示は sabiowl-home-pages/privacy_policy.md 第 2 条
        //     「音声入力（仮メモ機能）」で明示済 (「当社のサーバーが音声そのものを
        //     受け取ることはありません」)。
        //   - 再検討タイミング: v1.1 の FEAT-492 (Habit/ToDo/Event 3 画面横展開) と併せて
        //     on-device 強制 + フォールバック実装の A案を評価する。
        listenOptions: SpeechListenOptions(
          listenFor: timeout,
          pauseFor: const Duration(seconds: 5),
          cancelOnError: true,
          listenMode: ListenMode.deviceDefault,
        ),
      );
    } on TypeError {
      // 【Samsung Galaxy S22 固有バグ (2026-07-26)】speech_to_text v7 が
      // Samsung の platform channel から null を受け取り、bool へのキャストに失敗する。
      // ただし Android SpeechRecognizer は正常に起動している（rmsDB ログで確認済み）。
      // ここで return '' すると UI はアイドルに戻るが認識処理はバックグラウンドで継続、
      // ユーザーは話す機会を失う。
      // 対策: started=true として扱い、onResult/onStatus 経由の Completer 解決を待つ。
      debugPrint('[VoiceInputService] _stt.listen() returned null (Samsung quirk) — treating as started');
      started = true;
    } catch (e) {
      debugPrint('[VoiceInputService] _stt.listen() threw: $e');
      _lastError = 'listen_exception';
      if (!completer.isCompleted) {
        completer.complete('');
      }
      return '';
    }

    if (!started) {
      _lastError ??= 'listen_not_started';
      if (!completer.isCompleted) {
        completer.complete('');
      }
    }

    // 【FEAT-501 A (2026-07-26)】timeout 追加。listenFor (timeout) + 5s 余裕。
    // プラットフォームが onResult も onStatus も返さない case (Samsung TypeError
    // 経路で started=true にした後の無応答等) に対する脱出路。これが無いと
    // Future が永久未解決 → UI が processing 状態に固定、停止 button も disabled、
    // 画面を離れる以外の脱出手段が無かった (S1 予防)。onTimeout で
    // _lastPartialWords を返す = 途中まで聞けていれば捨てない。
    return completer.future.timeout(
      timeout + const Duration(seconds: 5),
      onTimeout: () {
        _lastError ??= 'listen_timeout';
        _stt.cancel();
        return _lastPartialWords;
      },
    );
  }

  /// 録音を停止。STT が残音声を処理し finalResult を onResult に送信、
  /// listen() の Future が解決される。
  void stop() {
    if (_stt.isListening) {
      _stt.stop();
    }
  }

  /// 録音を中断（認識結果を破棄）。dispose 時の緊急停止用。
  void cancel() {
    if (_stt.isListening) {
      _stt.cancel();
    }
    if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
      _listenCompleter!.complete('');
    }
    _listenCompleter = null;
  }
}
