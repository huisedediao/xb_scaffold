import 'package:flutter/material.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

class XBAnalyticsLocatorTestPage extends StatefulWidget {
  const XBAnalyticsLocatorTestPage({super.key});

  @override
  State<XBAnalyticsLocatorTestPage> createState() =>
      _XBAnalyticsLocatorTestPageState();
}

class _XBAnalyticsLocatorTestPageState
    extends State<XBAnalyticsLocatorTestPage> {
  bool _showTrackDebugPage = false;

  Future<void> _showThirdPartyContent() async {
    xbTrack(
      'show_embedded_xb_track_debug_page',
      pageName: 'xb_analytics_locator_test',
      params: const <String, dynamic>{
        'source': 'ume_locator_test',
      },
    );
    await xbFlushTrack();
    if (!mounted) return;
    setState(() {
      _showTrackDebugPage = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('XB Analytics Locator Test')),
      body: Column(
        children: [
          Material(
            key: const ValueKey<String>('local-project-control-area'),
            color: const Color(0xFFE8F1FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Local project UI',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'This blue area is built in xb_ume/example. The '
                          'third-party debug page is embedded below it.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed:
                        _showTrackDebugPage ? null : _showThirdPartyContent,
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Show third-party UI'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _showTrackDebugPage
                ? const _LocalProjectTrackDebugWrapper()
                : const Center(
                    child: Text('Third-party UI has not been shown yet.'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A widget owned by the example project that deliberately wraps third-party
/// UI. Tapping descendants of [XBTrackDebugPage] should still resolve to the
/// configured `xb_analytics_plus` package instead of this local ancestor.
class _LocalProjectTrackDebugWrapper extends StatelessWidget {
  const _LocalProjectTrackDebugWrapper();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      key: ValueKey<String>('local-project-track-debug-wrapper'),
      color: Colors.white,
      child: XBTrackDebugPage(),
    );
  }
}
