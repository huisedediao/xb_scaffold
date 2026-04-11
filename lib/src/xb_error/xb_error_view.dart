import 'package:flutter/material.dart';

class XBErrorView extends StatelessWidget {
  final Object? error;
  final StackTrace? stackTrace;
  final String message;
  final VoidCallback? onRetry;
  final String retryText;
  final VoidCallback? onBack;
  final String backText;

  const XBErrorView({
    super.key,
    this.error,
    this.stackTrace,
    this.message = '页面发生异常，请稍后重试',
    this.onRetry,
    this.retryText = 'retry',
    this.onBack,
    this.backText = 'back',
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.black87,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (onRetry != null || onBack != null) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    children: [
                      if (onRetry != null)
                        ElevatedButton(
                          onPressed: onRetry,
                          child: Text(retryText),
                        ),
                      if (onBack != null)
                        OutlinedButton(
                          onPressed: onBack,
                          child: Text(backText),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
