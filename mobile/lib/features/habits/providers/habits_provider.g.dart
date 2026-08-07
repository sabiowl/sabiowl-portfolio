// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'habits_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$habitsServiceHash() => r'3c4a5af31e5499fe8d6d005d70c6265037c320f0';

/// See also [habitsService].
@ProviderFor(habitsService)
final habitsServiceProvider = AutoDisposeProvider<HabitsService>.internal(
  habitsService,
  name: r'habitsServiceProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$habitsServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef HabitsServiceRef = AutoDisposeProviderRef<HabitsService>;
String _$habitsSummaryHash() => r'3cf6ad83d2b0e97a67291d8b299a90b322448daf';

/// See also [habitsSummary].
@ProviderFor(habitsSummary)
final habitsSummaryProvider = AutoDisposeFutureProvider<HabitsSummary>.internal(
  habitsSummary,
  name: r'habitsSummaryProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$habitsSummaryHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef HabitsSummaryRef = AutoDisposeFutureProviderRef<HabitsSummary>;
String _$playerNotifierHash() => r'57931a2d2bcbf49c06fd0653fad7c44405113620';

/// See also [PlayerNotifier].
@ProviderFor(PlayerNotifier)
final playerNotifierProvider =
    AutoDisposeAsyncNotifierProvider<PlayerNotifier, Player>.internal(
      PlayerNotifier.new,
      name: r'playerNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$playerNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$PlayerNotifier = AutoDisposeAsyncNotifier<Player>;
String _$habitsNotifierHash() => r'366acbd4cc46a5b554845316fb94c5ae163cf0f7';

/// See also [HabitsNotifier].
@ProviderFor(HabitsNotifier)
final habitsNotifierProvider =
    AutoDisposeAsyncNotifierProvider<HabitsNotifier, List<Habit>>.internal(
      HabitsNotifier.new,
      name: r'habitsNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$habitsNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$HabitsNotifier = AutoDisposeAsyncNotifier<List<Habit>>;
String _$archivedHabitsNotifierHash() =>
    r'c4352d09c36720b7333715c77e2c7b546168a134';

/// See also [ArchivedHabitsNotifier].
@ProviderFor(ArchivedHabitsNotifier)
final archivedHabitsNotifierProvider = AutoDisposeAsyncNotifierProvider<
  ArchivedHabitsNotifier,
  List<Habit>
>.internal(
  ArchivedHabitsNotifier.new,
  name: r'archivedHabitsNotifierProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$archivedHabitsNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$ArchivedHabitsNotifier = AutoDisposeAsyncNotifier<List<Habit>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
