import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class XBErrorView extends StatelessWidget {
  final Object? error;
  final StackTrace? stackTrace;
  final String message;
  final VoidCallback? onRetry;
  final String retryText;
  final VoidCallback? onBack;
  final String backText;
  final bool showCopyButton;
  final String copyButtonText;
  final String copiedHintText;

  const XBErrorView({
    super.key,
    this.error,
    this.stackTrace,
    this.message = '页面发生异常，请稍后重试',
    this.onRetry,
    this.retryText = 'retry',
    this.onBack,
    this.backText = 'back',
    this.showCopyButton = true,
    this.copyButtonText = '复制异常',
    this.copiedHintText = '已复制异常信息',
  });

  String _buildCopyText() {
    final buffer = StringBuffer();
    if (message.isNotEmpty) {
      buffer.writeln('message: $message');
    }
    if (error != null) {
      buffer.writeln('error: $error');
    }
    if (stackTrace != null) {
      buffer.writeln('stackTrace:\n$stackTrace');
    }
    return buffer.toString().trim();
  }

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
                      if (showCopyButton)
                        TextButton(
                          onPressed: () async {
                            final text = _buildCopyText();
                            if (text.isEmpty) return;
                            final messenger =
                                ScaffoldMessenger.maybeOf(context);
                            await Clipboard.setData(ClipboardData(text: text));
                            messenger?.hideCurrentSnackBar();
                            messenger?.showSnackBar(
                              SnackBar(content: Text(copiedHintText)),
                            );
                          },
                          child: Text(copyButtonText),
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
