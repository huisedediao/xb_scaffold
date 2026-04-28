import 'package:flutter/material.dart';

/// Backward-compatible pop handling on top of PopScope.
/// It preserves the behavior of legacy onWillPop callbacks.
class XBLegacyPopScope extends StatefulWidget {
  final Future<bool> Function()? onWillPop;
  final Widget child;
  final bool canPopWhenOnWillPopIsNull;

  const XBLegacyPopScope({
    super.key,
    required this.child,
    this.onWillPop,
    this.canPopWhenOnWillPopIsNull = true,
  });

  @override
  State<XBLegacyPopScope> createState() => _XBLegacyPopScopeState();
}

class _XBLegacyPopScopeState extends State<XBLegacyPopScope> {
  bool _allowOnePop = false;
  bool _handlingWillPop = false;
  bool _programmaticPopInFlight = false;

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (didPop) {
      if (_allowOnePop && mounted) {
        setState(() {
          _allowOnePop = false;
        });
      }
      _programmaticPopInFlight = false;
      return;
    }

    if (_programmaticPopInFlight) {
      _programmaticPopInFlight = false;
      if (_allowOnePop && mounted) {
        setState(() {
          _allowOnePop = false;
        });
      }
      return;
    }

    final onWillPop = widget.onWillPop;
    if (onWillPop == null || _handlingWillPop) {
      return;
    }

    _handlingWillPop = true;
    try {
      final allowPop = await onWillPop();
      if (!mounted || !allowPop) {
        return;
      }

      setState(() {
        _allowOnePop = true;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _programmaticPopInFlight = true;
        await Navigator.maybePop(context);
        if (!mounted) return;
        _programmaticPopInFlight = false;
        if (_allowOnePop) {
          setState(() {
            _allowOnePop = false;
          });
        }
      });
    } finally {
      _handlingWillPop = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasWillPop = widget.onWillPop != null;
    return PopScope(
      canPop: hasWillPop ? _allowOnePop : widget.canPopWhenOnWillPopIsNull,
      onPopInvokedWithResult: _onPopInvoked,
      child: widget.child,
    );
  }
}
