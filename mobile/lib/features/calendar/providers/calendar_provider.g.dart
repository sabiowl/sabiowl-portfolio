// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calendar_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$calendarServiceHash() => r'1b24f21a816d616bbc19220cebd3b8069d60e01d';

/// See also [calendarService].
@ProviderFor(calendarService)
final calendarServiceProvider = AutoDisposeProvider<CalendarService>.internal(
  calendarService,
  name: r'calendarServiceProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$calendarServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef CalendarServiceRef = AutoDisposeProviderRef<CalendarService>;
String _$googleCalendarSyncServiceHash() =>
    r'2162c07ef641c4a6163cd6d10cb3db5d9d36f842';

/// 【FEAT-268】Google Calendar 連携専用サービスのプロバイダー。
/// 旧 `calendarServiceProvider.syncGoogleCalendar()` 等の経路は本 provider に移行。
/// 【FEAT-426】予定本文を端末内に保存するため [LocalGoogleEventStore] を注入。
///
/// Copied from [googleCalendarSyncService].
@ProviderFor(googleCalendarSyncService)
final googleCalendarSyncServiceProvider =
    AutoDisposeProvider<GoogleCalendarSyncService>.internal(
      googleCalendarSyncService,
      name: r'googleCalendarSyncServiceProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$googleCalendarSyncServiceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef GoogleCalendarSyncServiceRef =
    AutoDisposeProviderRef<GoogleCalendarSyncService>;
String _$localGoogleEventStoreHash() =>
    r'cacf7eb2f169688803e235c7ec721ebac42908fd';

/// 【FEAT-426】Google カレンダー予定本文のローカル保存ストア。
/// アプリ全体で 1 つの SQLite 接続を共有する（autoDispose しない）。
///
/// Copied from [localGoogleEventStore].
@ProviderFor(localGoogleEventStore)
final localGoogleEventStoreProvider = Provider<LocalGoogleEventStore>.internal(
  localGoogleEventStore,
  name: r'localGoogleEventStoreProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$localGoogleEventStoreHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef LocalGoogleEventStoreRef = ProviderRef<LocalGoogleEventStore>;
String _$googleEventCompletionServiceHash() =>
    r'da592d9e37ae6b9af9deb58680b3671d56581e02';

/// 【FEAT-426】Google カレンダー予定の完了状態 (Multi-device 同期) サービス。
///
/// Copied from [googleEventCompletionService].
@ProviderFor(googleEventCompletionService)
final googleEventCompletionServiceProvider =
    AutoDisposeProvider<GoogleEventCompletionService>.internal(
      googleEventCompletionService,
      name: r'googleEventCompletionServiceProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$googleEventCompletionServiceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef GoogleEventCompletionServiceRef =
    AutoDisposeProviderRef<GoogleEventCompletionService>;
String _$streakDataHash() => r'f9f88ee54bd838f6460aa6a26f637580dd8f7ccf';

/// See also [streakData].
@ProviderFor(streakData)
final streakDataProvider = AutoDisposeFutureProvider<StreakData>.internal(
  streakData,
  name: r'streakDataProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$streakDataHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef StreakDataRef = AutoDisposeFutureProviderRef<StreakData>;
String _$statsDataHash() => r'ce15b635b5a480bdb945124fc5a0a4e79ec99c21';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

/// See also [statsData].
@ProviderFor(statsData)
const statsDataProvider = StatsDataFamily();

/// See also [statsData].
class StatsDataFamily extends Family<AsyncValue<StatsData>> {
  /// See also [statsData].
  const StatsDataFamily();

  /// See also [statsData].
  StatsDataProvider call(int year, int month) {
    return StatsDataProvider(year, month);
  }

  @override
  StatsDataProvider getProviderOverride(covariant StatsDataProvider provider) {
    return call(provider.year, provider.month);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'statsDataProvider';
}

/// See also [statsData].
class StatsDataProvider extends AutoDisposeFutureProvider<StatsData> {
  /// See also [statsData].
  StatsDataProvider(int year, int month)
    : this._internal(
        (ref) => statsData(ref as StatsDataRef, year, month),
        from: statsDataProvider,
        name: r'statsDataProvider',
        debugGetCreateSourceHash:
            const bool.fromEnvironment('dart.vm.product')
                ? null
                : _$statsDataHash,
        dependencies: StatsDataFamily._dependencies,
        allTransitiveDependencies: StatsDataFamily._allTransitiveDependencies,
        year: year,
        month: month,
      );

  StatsDataProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.year,
    required this.month,
  }) : super.internal();

  final int year;
  final int month;

  @override
  Override overrideWith(
    FutureOr<StatsData> Function(StatsDataRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: StatsDataProvider._internal(
        (ref) => create(ref as StatsDataRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        year: year,
        month: month,
      ),
    );
  }

  @override
  AutoDisposeFutureProviderElement<StatsData> createElement() {
    return _StatsDataProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is StatsDataProvider &&
        other.year == year &&
        other.month == month;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, year.hashCode);
    hash = _SystemHash.combine(hash, month.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin StatsDataRef on AutoDisposeFutureProviderRef<StatsData> {
  /// The parameter `year` of this provider.
  int get year;

  /// The parameter `month` of this provider.
  int get month;
}

class _StatsDataProviderElement
    extends AutoDisposeFutureProviderElement<StatsData>
    with StatsDataRef {
  _StatsDataProviderElement(super.provider);

  @override
  int get year => (origin as StatsDataProvider).year;
  @override
  int get month => (origin as StatsDataProvider).month;
}

String _$calendarHeatmapHash() => r'7b03d824acaba4d4cd25f8527937b09b6f9098aa';

/// See also [calendarHeatmap].
@ProviderFor(calendarHeatmap)
final calendarHeatmapProvider = AutoDisposeFutureProvider<HeatmapData>.internal(
  calendarHeatmap,
  name: r'calendarHeatmapProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$calendarHeatmapHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef CalendarHeatmapRef = AutoDisposeFutureProviderRef<HeatmapData>;
String _$calendarBootstrapHash() => r'ba2751ac33aa35a6f3cf605ac00f4e7d74b793fe';

/// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
///
/// 【FEAT-280】Stream 化で SWR パターンに対応:
///   1. キャッシュあれば即時 yield（白画面消し）
///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
///
/// Copied from [calendarBootstrap].
@ProviderFor(calendarBootstrap)
const calendarBootstrapProvider = CalendarBootstrapFamily();

/// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
///
/// 【FEAT-280】Stream 化で SWR パターンに対応:
///   1. キャッシュあれば即時 yield（白画面消し）
///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
///
/// Copied from [calendarBootstrap].
class CalendarBootstrapFamily
    extends Family<AsyncValue<CalendarBootstrapData>> {
  /// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
  ///
  /// 【FEAT-280】Stream 化で SWR パターンに対応:
  ///   1. キャッシュあれば即時 yield（白画面消し）
  ///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
  ///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
  ///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
  ///
  /// Copied from [calendarBootstrap].
  const CalendarBootstrapFamily();

  /// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
  ///
  /// 【FEAT-280】Stream 化で SWR パターンに対応:
  ///   1. キャッシュあれば即時 yield（白画面消し）
  ///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
  ///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
  ///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
  ///
  /// Copied from [calendarBootstrap].
  CalendarBootstrapProvider call(int year, int month, String date) {
    return CalendarBootstrapProvider(year, month, date);
  }

  @override
  CalendarBootstrapProvider getProviderOverride(
    covariant CalendarBootstrapProvider provider,
  ) {
    return call(provider.year, provider.month, provider.date);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'calendarBootstrapProvider';
}

/// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
///
/// 【FEAT-280】Stream 化で SWR パターンに対応:
///   1. キャッシュあれば即時 yield（白画面消し）
///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
///
/// Copied from [calendarBootstrap].
class CalendarBootstrapProvider
    extends AutoDisposeStreamProvider<CalendarBootstrapData> {
  /// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
  ///
  /// 【FEAT-280】Stream 化で SWR パターンに対応:
  ///   1. キャッシュあれば即時 yield（白画面消し）
  ///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
  ///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
  ///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
  ///
  /// Copied from [calendarBootstrap].
  CalendarBootstrapProvider(int year, int month, String date)
    : this._internal(
        (ref) =>
            calendarBootstrap(ref as CalendarBootstrapRef, year, month, date),
        from: calendarBootstrapProvider,
        name: r'calendarBootstrapProvider',
        debugGetCreateSourceHash:
            const bool.fromEnvironment('dart.vm.product')
                ? null
                : _$calendarBootstrapHash,
        dependencies: CalendarBootstrapFamily._dependencies,
        allTransitiveDependencies:
            CalendarBootstrapFamily._allTransitiveDependencies,
        year: year,
        month: month,
        date: date,
      );

  CalendarBootstrapProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.year,
    required this.month,
    required this.date,
  }) : super.internal();

  final int year;
  final int month;
  final String date;

  @override
  Override overrideWith(
    Stream<CalendarBootstrapData> Function(CalendarBootstrapRef provider)
    create,
  ) {
    return ProviderOverride(
      origin: this,
      override: CalendarBootstrapProvider._internal(
        (ref) => create(ref as CalendarBootstrapRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        year: year,
        month: month,
        date: date,
      ),
    );
  }

  @override
  AutoDisposeStreamProviderElement<CalendarBootstrapData> createElement() {
    return _CalendarBootstrapProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is CalendarBootstrapProvider &&
        other.year == year &&
        other.month == month &&
        other.date == date;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, year.hashCode);
    hash = _SystemHash.combine(hash, month.hashCode);
    hash = _SystemHash.combine(hash, date.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin CalendarBootstrapRef
    on AutoDisposeStreamProviderRef<CalendarBootstrapData> {
  /// The parameter `year` of this provider.
  int get year;

  /// The parameter `month` of this provider.
  int get month;

  /// The parameter `date` of this provider.
  String get date;
}

class _CalendarBootstrapProviderElement
    extends AutoDisposeStreamProviderElement<CalendarBootstrapData>
    with CalendarBootstrapRef {
  _CalendarBootstrapProviderElement(super.provider);

  @override
  int get year => (origin as CalendarBootstrapProvider).year;
  @override
  int get month => (origin as CalendarBootstrapProvider).month;
  @override
  String get date => (origin as CalendarBootstrapProvider).date;
}

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
