// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gamification_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$gamificationServiceHash() =>
    r'8e54fb0ff5ffa0a54265180367f66e8bbbc7c3cc';

/// See also [gamificationService].
@ProviderFor(gamificationService)
final gamificationServiceProvider =
    AutoDisposeProvider<GamificationService>.internal(
      gamificationService,
      name: r'gamificationServiceProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$gamificationServiceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef GamificationServiceRef = AutoDisposeProviderRef<GamificationService>;
String _$gachaOddsHash() => r'5c4a7dc4881e52a6973125abd5d61a15d2a6f8f5';

/// See also [gachaOdds].
@ProviderFor(gachaOdds)
final gachaOddsProvider = AutoDisposeFutureProvider<GachaOdds>.internal(
  gachaOdds,
  name: r'gachaOddsProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$gachaOddsHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef GachaOddsRef = AutoDisposeFutureProviderRef<GachaOdds>;
String _$statsNotifierHash() => r'bb44817ccd265cf076c784f5f7921eb28faf5f98';

/// See also [StatsNotifier].
@ProviderFor(StatsNotifier)
final statsNotifierProvider = AutoDisposeAsyncNotifierProvider<
  StatsNotifier,
  List<CharacterStat>
>.internal(
  StatsNotifier.new,
  name: r'statsNotifierProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$statsNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$StatsNotifier = AutoDisposeAsyncNotifier<List<CharacterStat>>;
String _$charactersNotifierHash() =>
    r'514a7042f223a2ae4fe09b745b9c6c971bc8d7bb';

/// See also [CharactersNotifier].
@ProviderFor(CharactersNotifier)
final charactersNotifierProvider = AutoDisposeAsyncNotifierProvider<
  CharactersNotifier,
  List<Character>
>.internal(
  CharactersNotifier.new,
  name: r'charactersNotifierProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$charactersNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$CharactersNotifier = AutoDisposeAsyncNotifier<List<Character>>;
String _$shopNotifierHash() => r'8f9d5bf8524612047d91f581fad6831070a6503d';

/// See also [ShopNotifier].
@ProviderFor(ShopNotifier)
final shopNotifierProvider =
    AutoDisposeAsyncNotifierProvider<ShopNotifier, ShopState>.internal(
      ShopNotifier.new,
      name: r'shopNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$shopNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ShopNotifier = AutoDisposeAsyncNotifier<ShopState>;
String _$gachaNotifierHash() => r'524952183de41b2f54ce2b509b9ebd325f41e623';

/// See also [GachaNotifier].
@ProviderFor(GachaNotifier)
final gachaNotifierProvider =
    AutoDisposeAsyncNotifierProvider<GachaNotifier, GachaStatus>.internal(
      GachaNotifier.new,
      name: r'gachaNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$gachaNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$GachaNotifier = AutoDisposeAsyncNotifier<GachaStatus>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
