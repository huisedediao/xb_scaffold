import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'router_core.dart';

/// A go_router based [XBRouteDriver] example.
///
/// Copy this file into your app and customize the callbacks based on your
/// route naming/location conventions.
class XBGoRouterDriver implements XBRouteDriver {
  XBGoRouterDriver({
    required this.router,
    required this.locationForPage,
    required this.typeForLocation,
    this.stackLocations,
    this.rootLocation = '/',
  });

  /// Global go_router instance.
  final GoRouter router;

  /// Maps widget pages to go_router locations.
  ///
  /// Example: `DetailPage(id: 1) -> '/detail/1'`
  final String Function(Widget page) locationForPage;

  /// Maps location to logical page type key (`'$type'`).
  ///
  /// Example: `'/detail/1' -> 'DetailPage'`
  final String Function(String location) typeForLocation;

  /// Optional external stack provider.
  ///
  /// Return top-last stack locations, e.g. ['/', '/list', '/detail/1'].
  /// If null, this driver falls back to current location only.
  final List<String> Function()? stackLocations;

  /// Root location used by [popToRoot] and clear-stack operations.
  final String rootLocation;

  List<String> get _stack {
    final external = stackLocations?.call();
    if (external != null && external.isNotEmpty) {
      return external;
    }
    return <String>[_currentLocation];
  }

  String get _currentLocation {
    final uri = router.routeInformationProvider.value.uri;
    var ret = uri.path;
    if (uri.query.isNotEmpty) {
      ret = '$ret?${uri.query}';
    }
    return ret.isEmpty ? '/' : ret;
  }

  String _normalizeType(Type type) => '$type';

  @override
  Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]) {
    final location = locationForPage(newPage);
    return router.push<T>(location);
  }

  @override
  void pop<O extends Object?>([O? result]) {
    router.pop(result);
  }

  @override
  Future<T?> replace<T extends Object?>(Widget newPage, [int style = 0]) {
    final location = locationForPage(newPage);
    return router.pushReplacement<T>(location);
  }

  @override
  void popToRoot() {
    router.go(rootLocation);
  }

  @override
  Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
      [int style = 0]) {
    final location = locationForPage(newPage);
    router.go(location);
    return Future<T?>.value(null);
  }

  @override
  void popUntilType(Type type) {
    final expectedType = _normalizeType(type);
    final stack = _stack;

    // If external stack is unavailable, best-effort fallback.
    if (stack.length <= 1) {
      if (typeForLocation(_currentLocation) != expectedType) {
        router.go(rootLocation);
      }
      return;
    }

    for (int i = stack.length - 1; i >= 0; i--) {
      final location = stack[i];
      if (typeForLocation(location) == expectedType) {
        router.go(location);
        return;
      }
    }

    router.go(rootLocation);
  }

  @override
  bool isXBRoute(Route route) {
    // go_router does not produce xb_route metadata routes.
    return false;
  }

  @override
  bool topIsType(Type type) {
    final expectedType = _normalizeType(type);
    final stack = _stack;
    final topLocation = stack.isEmpty ? _currentLocation : stack.last;
    return typeForLocation(topLocation) == expectedType;
  }

  @override
  bool stackContainType(Type type) {
    final expectedType = _normalizeType(type);
    final stack = _stack;
    for (final location in stack) {
      if (typeForLocation(location) == expectedType) {
        return true;
      }
    }
    return false;
  }

  @override
  bool routeIsMapWidget({required Route route, required Widget widget}) {
    // Not meaningful in go_router mode.
    return false;
  }
}

/// Setup helper for quick integration.
///
/// Example:
/// ```dart
/// configureXBGoRouter(
///   router: appRouter,
///   locationForPage: (page) {
///     if (page is HomePage) return '/';
///     if (page is DetailPage) return '/detail/${page.id}';
///     throw ArgumentError('No location mapping for ${page.runtimeType}');
///   },
///   typeForLocation: (location) {
///     if (location.startsWith('/detail/')) return 'DetailPage';
///     if (location == '/') return 'HomePage';
///     return 'UnknownPage';
///   },
///   stackLocations: () => myRouteStack.value,
/// );
/// ```
void configureXBGoRouter({
  required GoRouter router,
  required String Function(Widget page) locationForPage,
  required String Function(String location) typeForLocation,
  List<String> Function()? stackLocations,
  String rootLocation = '/',
}) {
  configureXBRouteDriver(
    XBGoRouterDriver(
      router: router,
      locationForPage: locationForPage,
      typeForLocation: typeForLocation,
      stackLocations: stackLocations,
      rootLocation: rootLocation,
    ),
  );
}
