import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 【FEAT-280】オンライン / オフライン / fetch 中の状態を保持する Riverpod state。
///
/// SWR の各 Service / Notifier が API 結果に応じて `markOnline` / `markOffline`
/// を呼び出す。`home_page` の `OfflineIndicator` ウィジェットが watch して
/// 「オフライン表示中」帯の表示制御に使う。
class ConnectivityState {
  ConnectivityState({
    required this.isOnline,
    this.lastSuccessAt,
    this.lastErrorMessage,
    this.isFetching = false,
  });

  /// 直近の API 呼び出しが成功したか。
  /// true = オンライン（インジケータ非表示） / false = オフライン（橙色帯）。
  final bool isOnline;

  /// 直近の成功時刻。`null` のときは「まだ一度も成功していない」状態（初回起動オフライン等）。
  final DateTime? lastSuccessAt;

  /// 直近の失敗メッセージ（Dio Exception の文字列等）。デバッグ表示用、UI には出さない。
  final String? lastErrorMessage;

  /// fetch 中（cached 表示 + 裏で API 進行）。`true` のときインジケータに
  /// 「最新化中...」を併記する。
  final bool isFetching;

  ConnectivityState copyWith({
    bool? isOnline,
    DateTime? lastSuccessAt,
    String? lastErrorMessage,
    bool clearError = false,
    bool? isFetching,
  }) =>
      ConnectivityState(
        isOnline:         isOnline         ?? this.isOnline,
        lastSuccessAt:    lastSuccessAt    ?? this.lastSuccessAt,
        lastErrorMessage: clearError ? null : (lastErrorMessage ?? this.lastErrorMessage),
        isFetching:       isFetching       ?? this.isFetching,
      );

  factory ConnectivityState.initial() => ConnectivityState(isOnline: true);
}

class ConnectivityNotifier extends StateNotifier<ConnectivityState> {
  ConnectivityNotifier() : super(ConnectivityState.initial());

  /// API 呼び出し成功時。インジケータを「成功 + フェッチ完了」に。
  void markOnline() {
    state = state.copyWith(
      isOnline:      true,
      lastSuccessAt: DateTime.now(),
      clearError:    true,
      isFetching:    false,
    );
  }

  /// API 呼び出し失敗時（DioException / network エラー）。
  /// インジケータを「オフライン」に切り替える。
  void markOffline(String? errorMessage) {
    state = state.copyWith(
      isOnline:         false,
      lastErrorMessage: errorMessage,
      isFetching:       false,
    );
  }

  /// 「裏で API リクエスト中」を示す。cached + fetching → インジケータの
  /// 「最新化中...」ラベル表示に使う。
  void markFetching() {
    state = state.copyWith(isFetching: true);
  }
}

final connectivityProvider =
    StateNotifierProvider<ConnectivityNotifier, ConnectivityState>(
  (ref) => ConnectivityNotifier(),
);
