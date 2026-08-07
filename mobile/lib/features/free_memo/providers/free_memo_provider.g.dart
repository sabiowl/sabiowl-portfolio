// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'free_memo_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$freeMemoServiceHash() => r'a86d2ca6ece15f8e61e8bf733f32031becd8d853';

/// See also [freeMemoService].
@ProviderFor(freeMemoService)
final freeMemoServiceProvider = AutoDisposeProvider<FreeMemoService>.internal(
  freeMemoService,
  name: r'freeMemoServiceProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$freeMemoServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef FreeMemoServiceRef = AutoDisposeProviderRef<FreeMemoService>;
String _$freeMemoNotifierHash() => r'32e673627c33ca79fe06eb7ebe62f9f1084c09dc';

/// See also [FreeMemoNotifier].
@ProviderFor(FreeMemoNotifier)
final freeMemoNotifierProvider =
    AutoDisposeAsyncNotifierProvider<FreeMemoNotifier, List<FreeMemo>>.internal(
      FreeMemoNotifier.new,
      name: r'freeMemoNotifierProvider',
      debugGetCreateSourceHash:
          const bool.fromEnvironment('dart.vm.product')
              ? null
              : _$freeMemoNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$FreeMemoNotifier = AutoDisposeAsyncNotifier<List<FreeMemo>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
