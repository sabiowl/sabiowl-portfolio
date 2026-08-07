/// 【FEAT-523 Phase 3 (2026-08-07)】交換ピースの積み上げを 2 画面で同じ表現にするための定数。
///
/// ## なぜ 1 箇所に置くのか
///
/// 「あと N 個で交換券」は **選ぶ画面 (重複ガチャの 2 択) と貯める画面 (ショップの
/// ピースタブ) の両方**に出す。片方だけ実装すると、選ぶときと貯めるときで
/// 表現が食い違う (FEAT-523 Pre-mortem #4)。文言は同じ ARB キーを、
/// しきい値は本定数を、双方から参照する。
///
/// ## 真実値は Backend
///
/// `backend/api/views/shop.py` の `_SHOP_CATALOG` にある
/// `piece_character_ticket` の `piece_price` が真実値。ここはその写しである。
/// **Backend 側を変えたらここも変えること。**
///
/// クライアントに写しを置いているのは、この表示のために新しい API も state も
/// 増やさない判断による (`playerNotifierProvider.exchangePieces` だけで完結する)。
/// ショップの実際の購入判定は `ShopItem.piecePrice` (Backend から来る値) を見ており、
/// 本定数は **進捗表示にしか使わない**ので、ずれても購入が壊れることはない。
class ExchangePieceConstants {
  ExchangePieceConstants._();

  /// キャラ交換券 1 枚に必要なピース数。
  ///
  /// FEAT-497 の設計は「重複 5 回でキャラ交換券 1 枚」= 100 ピース × 5。
  static const int ticketPieceCost = 500;

  /// 交換券まであと何個か。到達済みなら 0。
  static int remainingToTicket(int pieces) {
    if (pieces >= ticketPieceCost) return 0;
    return ticketPieceCost - pieces;
  }
}
