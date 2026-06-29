import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class _DialogEntry {
  final Widget widget;
  final int priority;
  final int id;
  static int _nextId = 0;

  _DialogEntry({required this.widget, required this.priority})
      : id = _nextId++;
}

class XBDialogManager {
  static final XBDialogManager _instance = XBDialogManager._();
  factory XBDialogManager() => _instance;
  XBDialogManager._();

  final List<_DialogEntry> _queue = [];
  bool _isShowing = false;
  _DialogEntry? _currentEntry;
  int _showId = 0;

  void show({required Widget widget, int priority = 0}) {
    final entry = _DialogEntry(widget: widget, priority: priority);
    _insertIntoQueue(entry);

    if (!_isShowing) {
      _showNext();
      return;
    }

    if (_currentEntry != null && _shouldReplace(entry, _currentEntry!)) {
      _dismissCurrent();
    }
  }

  void _insertIntoQueue(_DialogEntry entry) {
    int i = 0;
    while (i < _queue.length) {
      final item = _queue[i];
      if (entry.priority > item.priority ||
          (entry.priority == item.priority && entry.id > item.id)) {
        break;
      }
      i++;
    }
    _queue.insert(i, entry);
  }

  bool _shouldReplace(_DialogEntry newEntry, _DialogEntry current) {
    if (newEntry.priority > current.priority) return true;
    if (newEntry.priority == current.priority && newEntry.id > current.id) {
      return true;
    }
    return false;
  }

  void _showNext() {
    if (_queue.isEmpty) {
      _isShowing = false;
      _currentEntry = null;
      return;
    }

    _isShowing = true;
    _currentEntry = _queue.removeAt(0);
    _showId++;
    final expectedShowId = _showId;

    try {
      _showDialogWidget(_currentEntry!.widget).then((_) {
        if (_showId == expectedShowId) {
          _onDialogClosed();
        }
      });
    } catch (e) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_showId == expectedShowId) {
          _showDialogWidget(_currentEntry!.widget).then((_) {
            if (_showId == expectedShowId) {
              _onDialogClosed();
            }
          });
        }
      });
    }
  }

  void _dismissCurrent() {
    if (_currentEntry != null) {
      _insertIntoQueue(_currentEntry!);
    }
    try {
      xbNavigatorState.pop();
    } catch (_) {}
    _showNext();
  }

  void _onDialogClosed() {
    _showNext();
  }

  Future<T?> _showDialogWidget<T>(Widget widget) {
    return showDialog<T>(
      barrierDismissible: false,
      context: xbNavigatorContext,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 50),
            child: Material(
                type: MaterialType.transparency,
                child: Container(alignment: Alignment.center, child: widget)),
          ),
        );
      },
    );
  }
}
