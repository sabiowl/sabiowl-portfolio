// 【FEAT-493 (2026-07-25)】仮メモ API サービス。
import '../../../core/api/api_client.dart';
import '../models/free_memo.dart';

/// 【FEAT-498 §2.5 (2026-07-26)】trash pagination 用 page record。
/// memos = 取得したメモ、hasMore = 次 page 存在フラグ、
/// nextOffset = 次 fetch 時に使う offset (現 offset + memos.length)。
typedef MemoPage = ({List<FreeMemo> memos, bool hasMore, int nextOffset});

/// 【FEAT-503 アクション8 (2026-07-26)】通常一覧 (未削除) の fetch 結果。
/// backend の has_more (200 件上限で打切りあり) をクライアントへ通す。
/// pagination はしない (active では 200 件超は稀) が、末尾 1 行案内の判定に使う。
typedef MemoListResult = ({List<FreeMemo> memos, bool hasMore});

class FreeMemoService {
  const FreeMemoService(this._apiClient);
  final ApiClient _apiClient;

  /// 【FEAT-502 (2026-07-26)】通常一覧 (未削除メモ) 専用。
  /// 旧 `archived` 引数は削除 = 「削除済メモの取得口は fetchDeletedPage 1 本」を
  /// 構造保証 (archived の取得経路が 2 つあった曖昧さを解消)。
  /// 【FEAT-503 アクション8 (2026-07-26)】return 型を List → record に変更、
  /// backend の has_more を捨てずにクライアントへ通す (末尾 1 行案内の判定用)。
  Future<MemoListResult> fetchMemos() async {
    final res = await _apiClient.dio.get('/free-memos/');
    final data = res.data as Map<String, dynamic>;
    final list = (data['memos'] as List<dynamic>);
    final memos = list
        .map((j) => FreeMemo.fromJson(j as Map<String, dynamic>))
        .toList();
    final hasMore = (data['has_more'] as bool?) ?? false;
    return (memos: memos, hasMore: hasMore);
  }

  /// 【FEAT-498 §2.5 (2026-07-26) / FEAT-502 (2026-07-26)】削除済メモ (trash) の
  /// pagination 対応版。上限超え時に「もっと読み込む」button で offset を累積して
  /// 呼び出す前提。旧名 fetchArchivedPage → fetchDeletedPage に rename
  /// (semantic 透明化: user 削除 = deleted であって auto archive ではない)。
  /// 通常一覧 (memo 画面本体) は fetchMemos() の非 paginated 経路を維持。
  /// query param 名 `archived=true` は Backend 後方互換のため据置 (内部 filter は
  /// deleted_at)。
  Future<MemoPage> fetchDeletedPage({int offset = 0}) async {
    final res = await _apiClient.dio.get(
      '/free-memos/',
      queryParameters: {
        'archived': 'true',
        'offset': offset.toString(),
      },
    );
    final data = res.data as Map<String, dynamic>;
    final list = (data['memos'] as List<dynamic>);
    final memos = list
        .map((j) => FreeMemo.fromJson(j as Map<String, dynamic>))
        .toList();
    final hasMore = (data['has_more'] as bool?) ?? false;
    return (
      memos: memos,
      hasMore: hasMore,
      nextOffset: offset + memos.length,
    );
  }

  Future<FreeMemo> createMemo(String text) async {
    final res = await _apiClient.dio.post(
      '/free-memos/',
      data: {'text': text},
    );
    return FreeMemo.fromJson(res.data as Map<String, dynamic>);
  }

  Future<FreeMemo> updateMemo(int id, String text) async {
    final res = await _apiClient.dio.patch(
      '/free-memos/$id/',
      data: {'text': text},
    );
    return FreeMemo.fromJson(res.data as Map<String, dynamic>);
  }

  /// 【FEAT-500 → FEAT-502 (2026-07-26)】ソフト削除 (trash に移動、復元可能)。
  /// backend で deleted_at=now() が set され、GET /?archived=true で取得可能に。
  Future<void> deleteMemo(int id) async {
    await _apiClient.dio.delete('/free-memos/$id/');
  }

  /// 【FEAT-500 → FEAT-502 (2026-07-26)】trash からの復元 (deleted_at=null)。
  Future<FreeMemo> restoreMemo(int id) async {
    final res = await _apiClient.dio.post('/free-memos/$id/restore/');
    return FreeMemo.fromJson(res.data as Map<String, dynamic>);
  }

  /// 【FEAT-500 (2026-07-26)】完全削除 (hard、復元不可)。
  /// UI 側で確認 dialog を経てから呼び出す前提。
  Future<void> purgeMemo(int id) async {
    await _apiClient.dio.delete('/free-memos/$id/purge/');
  }

  /// 【FEAT-498 §2.6 (2026-07-31)】trash 一括完全削除 (deleted_at IS NOT NULL の全 memo)。
  ///
  /// UI 側で BUG-138 準拠 confirm dialog (「N 件のメモを完全に削除します。この操作は
  /// 取り消せません。」) を経てから呼ぶ前提。active memo (deleted_at IS NULL) は
  /// 影響を受けない (Backend で filter 保証)。
  ///
  /// Returns: response header `X-Purged-Count` の値 (削除件数、SnackBar 用)。
  /// header 欠落 / parse 失敗時は 0 fallback (Backend 未 deploy 環境の防御)。
  Future<int> purgeAllArchivedMemos() async {
    final res =
        await _apiClient.dio.delete('/free-memos/trash/purge-all/');
    final header = res.headers.value('x-purged-count');
    return int.tryParse(header ?? '') ?? 0;
  }

  /// メモを type ('event'/'todo'/'habit') に変換。メモ物理削除 + EXP 付与。
  /// 返り値: exp_gain (付与された EXP 量)
  ///
  /// 【20260729 review §3 C-2 対応 (Phase 2 消化)】旧 URL
  /// `/free-memos/$id/convert-to-$type/` から新 URL `/free-memos/$id/convert/`
  /// (body `{to_type}`) に移行。backend の互換 layer は残置 (FEAT-475 P3 #6 の
  /// 統合 view 経由で 旧 3 URL も同一 view を叩く)。docstring の
  /// 「Flutter 側は Phase 2 で新 URL 移行予定」記述は本移行で解消。
  Future<int> convertMemo(int id, String type) async {
    final res = await _apiClient.dio.post(
      '/free-memos/$id/convert/',
      data: {'to_type': type},
    );
    return (res.data as Map<String, dynamic>)['exp_gain'] as int? ?? 0;
  }
}
