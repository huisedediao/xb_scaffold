import 'dart:convert';

import 'package:flutter/widgets.dart';

class XBUmeWidgetLocatorResult {
  const XBUmeWidgetLocatorResult({
    required this.pickedElement,
    required this.resolvedElement,
    required this.pickedWidgetType,
    required this.resolvedWidgetType,
    required this.file,
    required this.line,
    required this.column,
    required this.ancestorPath,
    required this.rawCreationLocation,
    required this.resolveStrategy,
    required this.resolvedRect,
    required this.parentWidgetType,
    required this.parentFile,
    required this.parentLine,
    required this.parentColumn,
    required this.parentResolveStrategy,
  });

  final Element pickedElement;
  final Element resolvedElement;
  final String pickedWidgetType;
  final String resolvedWidgetType;
  final String? file;
  final int? line;
  final int? column;
  final String ancestorPath;
  final String? rawCreationLocation;
  final String resolveStrategy;
  final Rect? resolvedRect;
  final String? parentWidgetType;
  final String? parentFile;
  final int? parentLine;
  final int? parentColumn;
  final String? parentResolveStrategy;

  bool get hasLocation =>
      (file != null && file!.isNotEmpty) && line != null && column != null;

  bool get hasParentLocation =>
      (parentFile != null && parentFile!.isNotEmpty) &&
      parentLine != null &&
      parentColumn != null;
}

class XBUmeWidgetLocatorResolver {
  const XBUmeWidgetLocatorResolver();

  XBUmeWidgetLocatorResult resolve(Element pickedElement) {
    final chain = _normalizeChainLeafToRoot(pickedElement);
    final snapshots = chain.map(_buildSnapshot).toList(growable: false);
    final resolved = _resolvePreferredSnapshot(snapshots);
    final parent = _resolveParentSnapshot(snapshots, resolved.snapshot);

    final pathNames = chain.reversed
        .map((entry) => '${entry.widget.runtimeType}')
        .toList(growable: false);

    return XBUmeWidgetLocatorResult(
      pickedElement: pickedElement,
      resolvedElement: resolved.snapshot.element,
      pickedWidgetType: '${pickedElement.widget.runtimeType}',
      resolvedWidgetType: resolved.snapshot.widgetType,
      file: resolved.snapshot.file,
      line: resolved.snapshot.line,
      column: resolved.snapshot.column,
      ancestorPath: pathNames.join(' > '),
      rawCreationLocation: resolved.snapshot.rawCreationLocation,
      resolveStrategy: resolved.strategy,
      resolvedRect: resolved.snapshot.globalRect,
      parentWidgetType: parent?.snapshot.widgetType,
      parentFile: parent?.snapshot.file,
      parentLine: parent?.snapshot.line,
      parentColumn: parent?.snapshot.column,
      parentResolveStrategy: parent?.strategy,
    );
  }

  List<Element> _normalizeChainLeafToRoot(Element pickedElement) {
    final rawChain = pickedElement.debugGetDiagnosticChain();
    if (rawChain.isEmpty) {
      return <Element>[pickedElement];
    }

    if (identical(rawChain.first, pickedElement)) {
      return List<Element>.from(rawChain, growable: false);
    }

    if (identical(rawChain.last, pickedElement)) {
      return rawChain.reversed.toList(growable: false);
    }

    final chain = <Element>[pickedElement];
    for (final entry in rawChain) {
      if (!identical(entry, pickedElement)) {
        chain.add(entry);
      }
    }
    return chain;
  }

  _ResolvedSnapshot _resolvePreferredSnapshot(
      List<_LocatorSnapshot> snapshots) {
    _LocatorSnapshot? localProjectCandidate;
    _LocatorSnapshot? nonFlutterCandidate;
    _LocatorSnapshot? anyWithLocation;

    for (final snapshot in snapshots) {
      if (!snapshot.hasLocation) continue;

      anyWithLocation ??= snapshot;

      final normalizedFile = _normalizeLocationFile(snapshot.file!);

      if (localProjectCandidate == null &&
          !_isFlutterOrDartSdkLocation(normalizedFile) &&
          _isLikelyFirstParty(normalizedFile, snapshot.isLocalProject)) {
        localProjectCandidate = snapshot;
      }

      if (nonFlutterCandidate == null &&
          !_isFlutterOrDartSdkLocation(normalizedFile)) {
        nonFlutterCandidate = snapshot;
      }
    }

    if (localProjectCandidate != null) {
      return _ResolvedSnapshot(
        snapshot: localProjectCandidate,
        strategy: 'nearest first-party widget (non Flutter SDK)',
      );
    }

    if (nonFlutterCandidate != null) {
      return _ResolvedSnapshot(
        snapshot: nonFlutterCandidate,
        strategy: 'nearest non-Flutter widget',
      );
    }

    if (anyWithLocation != null) {
      return _ResolvedSnapshot(
        snapshot: anyWithLocation,
        strategy: 'fallback: nearest widget with creation location',
      );
    }

    return _ResolvedSnapshot(
      snapshot: snapshots.first,
      strategy: 'fallback: tapped widget has no creation location',
    );
  }

  _ResolvedSnapshot? _resolveParentSnapshot(
    List<_LocatorSnapshot> snapshots,
    _LocatorSnapshot resolvedSnapshot,
  ) {
    final resolvedIndex = snapshots.indexWhere(
      (item) => identical(item.element, resolvedSnapshot.element),
    );
    if (resolvedIndex < 0 || resolvedIndex >= snapshots.length - 1) {
      return null;
    }

    final ancestors = snapshots.sublist(resolvedIndex + 1);
    _LocatorSnapshot? localProjectCandidate;
    _LocatorSnapshot? nonFlutterCandidate;
    _LocatorSnapshot? anyWithLocation;

    for (final snapshot in ancestors) {
      if (!snapshot.hasLocation) continue;

      anyWithLocation ??= snapshot;
      final normalizedFile = _normalizeLocationFile(snapshot.file!);

      if (localProjectCandidate == null &&
          !_isFlutterOrDartSdkLocation(normalizedFile) &&
          _isLikelyFirstParty(normalizedFile, snapshot.isLocalProject)) {
        localProjectCandidate = snapshot;
      }

      if (nonFlutterCandidate == null &&
          !_isFlutterOrDartSdkLocation(normalizedFile)) {
        nonFlutterCandidate = snapshot;
      }
    }

    if (localProjectCandidate != null) {
      return _ResolvedSnapshot(
        snapshot: localProjectCandidate,
        strategy: 'parent first-party widget (non Flutter SDK)',
      );
    }

    if (nonFlutterCandidate != null) {
      return _ResolvedSnapshot(
        snapshot: nonFlutterCandidate,
        strategy: 'parent non-Flutter widget',
      );
    }

    if (anyWithLocation != null) {
      return _ResolvedSnapshot(
        snapshot: anyWithLocation,
        strategy: 'parent fallback: nearest ancestor with creation location',
      );
    }

    return null;
  }

  _LocatorSnapshot _buildSnapshot(Element element) {
    final node = element.toDiagnosticsNode();
    final jsonNode = node.toJsonMap(
      InspectorSerializationDelegate(
        service: WidgetInspectorService.instance,
        includeProperties: false,
        subtreeDepth: 1,
      ),
    );

    final creationLocationMap = _castCreationLocationMap(
      jsonNode['creationLocation'],
    );

    final rawCreationLocation = creationLocationMap == null
        ? null
        : const JsonEncoder.withIndent('  ').convert(creationLocationMap);

    return _LocatorSnapshot(
      element: element,
      widgetType: jsonNode['description']?.toString() ??
          '${element.widget.runtimeType}',
      file: creationLocationMap?['file']?.toString(),
      line: (creationLocationMap?['line'] as num?)?.toInt(),
      column: (creationLocationMap?['column'] as num?)?.toInt(),
      rawCreationLocation: rawCreationLocation,
      isLocalProject: debugIsLocalCreationLocation(element),
      globalRect: _computeGlobalRect(element),
    );
  }

  Map<String, dynamic>? _castCreationLocationMap(Object? source) {
    if (source is Map<String, dynamic>) {
      return source;
    }
    if (source is Map) {
      return source.cast<String, dynamic>();
    }
    return null;
  }

  Rect? _computeGlobalRect(Element element) {
    final renderObject = element.renderObject;
    if (renderObject == null || !renderObject.attached) {
      return null;
    }

    if (renderObject is RenderBox && renderObject.hasSize) {
      final topLeft = renderObject.localToGlobal(Offset.zero);
      if (_isFiniteOffset(topLeft)) {
        return topLeft & renderObject.size;
      }
    }

    try {
      final matrix = renderObject.getTransformTo(null);
      final rect = MatrixUtils.transformRect(matrix, renderObject.paintBounds);
      if (_isFiniteRect(rect)) {
        return rect;
      }
    } catch (_) {
      // ignored
    }

    return null;
  }

  bool _isFiniteOffset(Offset value) {
    return value.dx.isFinite && value.dy.isFinite;
  }

  bool _isFiniteRect(Rect value) {
    return value.left.isFinite &&
        value.top.isFinite &&
        value.right.isFinite &&
        value.bottom.isFinite;
  }

  bool _isLikelyFirstParty(String normalizedFile, bool isLocalProject) {
    if (_isFlutterOrDartSdkLocation(normalizedFile)) {
      return false;
    }

    if (_isPubCacheLocation(normalizedFile)) {
      return false;
    }

    if (normalizedFile.startsWith('package:')) {
      return isLocalProject;
    }

    if (normalizedFile.startsWith('/')) {
      return true;
    }

    return isLocalProject;
  }

  bool _isFlutterOrDartSdkLocation(String normalizedFile) {
    final lower = normalizedFile.toLowerCase();
    return lower.startsWith('dart:') ||
        lower.startsWith('package:flutter/') ||
        lower.contains('/packages/flutter/') ||
        lower.contains('/flutter/packages/flutter/');
  }

  bool _isPubCacheLocation(String normalizedFile) {
    final lower = normalizedFile.toLowerCase();
    return lower.contains('/.pub-cache/') || lower.contains('\\.pub-cache\\');
  }

  String _normalizeLocationFile(String file) {
    try {
      final uri = Uri.parse(file);
      if (uri.scheme == 'file') {
        return uri.toFilePath();
      }
    } catch (_) {
      // ignored
    }
    return file;
  }
}

class _LocatorSnapshot {
  const _LocatorSnapshot({
    required this.element,
    required this.widgetType,
    required this.file,
    required this.line,
    required this.column,
    required this.rawCreationLocation,
    required this.isLocalProject,
    required this.globalRect,
  });

  final Element element;
  final String widgetType;
  final String? file;
  final int? line;
  final int? column;
  final String? rawCreationLocation;
  final bool isLocalProject;
  final Rect? globalRect;

  bool get hasLocation =>
      (file != null && file!.isNotEmpty) && line != null && column != null;
}

class _ResolvedSnapshot {
  const _ResolvedSnapshot({
    required this.snapshot,
    required this.strategy,
  });

  final _LocatorSnapshot snapshot;
  final String strategy;
}
