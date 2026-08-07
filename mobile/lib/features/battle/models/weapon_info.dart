/// 【FEAT-326】武器情報データクラス。
///
/// Backend `WeaponMaster` + `PlayerWeapon.is_equipped=True` の組み合わせを表現。
/// `Player.equippedWeapon` で参照し、`BattleOrchestrator` の damage 計算で
/// `atkBonus` を使う。`PartyEditDialog` の装備スロット表示にも使用。
///
/// 古い Backend (FEAT-326 未デプロイ環境) との後方互換のため、
/// `Player.equippedWeapon` は null 許容。null 時は `atkBonus ?? 10`
/// (旧 `BattleConstants.starterWeaponAtkBonus`) でフォールバック。
class WeaponInfo {
  final int id;
  final String key;
  final String name;
  final int atkBonus;
  /// 【FEAT-379 (2026-05-29)】武器ソケット数 (v1.0 は表示のみ、装着は v1.1+)。
  /// starter/bronze=1、iron/steel=2、mythril/dragon_slayer=3。
  /// 古い Backend との後方互換: default=1。
  final int socketCount;
  /// 【FEAT-379】ソケット装着結晶種別 (v1.0 は null 維持、v1.1+ で装着 UI 解禁)。
  final String? socket1CrystalType;
  final String? socket2CrystalType;
  final String? socket3CrystalType;

  const WeaponInfo({
    required this.id,
    required this.key,
    required this.name,
    required this.atkBonus,
    this.socketCount = 1,
    this.socket1CrystalType,
    this.socket2CrystalType,
    this.socket3CrystalType,
  });

  factory WeaponInfo.fromJson(Map<String, dynamic> json) {
    return WeaponInfo(
      id:       json['id']        as int,
      key:      json['key']       as String? ?? '',
      name:     json['name']      as String? ?? '',
      atkBonus: json['atk_bonus'] as int? ?? 10,
      socketCount:        json['socket_count']           as int?    ?? 1,
      socket1CrystalType: json['socket_1_crystal_type'] as String?,
      socket2CrystalType: json['socket_2_crystal_type'] as String?,
      socket3CrystalType: json['socket_3_crystal_type'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id':        id,
        'key':       key,
        'name':      name,
        'atk_bonus': atkBonus,
        'socket_count':           socketCount,
        'socket_1_crystal_type':  socket1CrystalType,
        'socket_2_crystal_type':  socket2CrystalType,
        'socket_3_crystal_type':  socket3CrystalType,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WeaponInfo
        && other.id == id
        && other.key == key
        && other.name == name
        && other.atkBonus == atkBonus
        && other.socketCount == socketCount;
  }

  @override
  int get hashCode => Object.hash(id, key, name, atkBonus, socketCount);

  @override
  String toString() => 'WeaponInfo($key: ATK +$atkBonus, sockets: $socketCount)';
}
