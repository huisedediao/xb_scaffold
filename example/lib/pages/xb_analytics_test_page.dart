import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

class XBAnalyticsTestPage extends StatefulWidget {
  const XBAnalyticsTestPage({super.key});

  @override
  State<XBAnalyticsTestPage> createState() => _XBAnalyticsTestPageState();
}

class _XBAnalyticsTestPageState extends State<XBAnalyticsTestPage>
    with WidgetsBindingObserver {
  final List<String> _logs = <String>[];
  final _TestSpySink _spySink = _TestSpySink();

  bool _loading = false;
  bool _inited = false;
  bool _commonProviderEnabled = true;
  String _sharePreview = '';

  DateTime? _pageEnterAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageEnterAt = DateTime.now();
    _initTrack();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final enter = _pageEnterAt;
    if (enter != null) {
      final duration = DateTime.now().difference(enter).inMilliseconds;
      xbTrackPageLeave('XBAnalyticsTestPage', durationMs: duration);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_inited) return;
    if (state == AppLifecycleState.resumed) {
      xbTrackAppForeground(params: {'source': 'lifecycle'});
      _addLog('自动记录 app_foreground');
    } else if (state == AppLifecycleState.paused) {
      xbTrackAppBackground(params: {'source': 'lifecycle'});
      _addLog('自动记录 app_background');
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[${DateTime.now().toIso8601String()}] $message');
      if (_logs.length > 120) {
        _logs.removeLast();
      }
    });
  }

  Future<void> _run(String title, Future<void> Function() task) async {
    if (_loading) return;
    setState(() {
      _loading = true;
    });
    _addLog('开始: $title');
    try {
      await task();
      _addLog('完成: $title');
    } catch (e, s) {
      _addLog('失败: $title, err=$e');
      _addLog('$s');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _initTrack() async {
    await _run('initXBTrack', () async {
      await initXBTrack(
        XBTrackConfig(
          appVersion: 'example_1.0.0+1',
          enableConsoleSink: true,
          enableMemorySink: true,
          enableLocalStoreSink: true,
          flushBatchSize: 5,
          flushInterval: const Duration(milliseconds: 800),
          memoryMaxEvents: 1000,
          ioMaxBytes: 20 * 1024 * 1024,
          webMaxBytes: 3 * 1024 * 1024,
          maxPendingQueueSize: 5000,
          onShareRequested: (content) async {
            final maxLen = min(220, content.length);
            _sharePreview = content.substring(0, maxLen);
            _addLog('onShareRequested 回调触发，payload长度=${content.length}');
          },
          commonParamsProvider: _commonProviderEnabled
              ? () => <String, dynamic>{
                    'tenantId': 'demo_tenant_001',
                    'storeId': 'sz_nanshan_01',
                    'abGroup': 'A',
                  }
              : null,
          sinks: <XBTrackSink>[_spySink],
          debugPrintDropReason: true,
        ),
      );

      xbSetTrackPage('XBAnalyticsTestPage');
      xbTrackPageView(
        'XBAnalyticsTestPage',
        params: {'entry': 'choose_page_menu'},
      );
      _inited = true;
    });
  }

  Future<void> _trackManualEvent() async {
    xbTrack(
      'manual_business_event',
      params: <String, dynamic>{
        'action': 'submit',
        'scene': 'analytics_test',
        'clickAt': DateTime.now().toIso8601String(),
      },
      commonParams: <String, dynamic>{
        'common_override': 'from_manual_call',
      },
    );
    _addLog('已调用 xbTrack(manual_business_event)');
  }

  Future<void> _trackSensitiveData() async {
    xbTrack(
      'sensitive_mask_test',
      params: <String, dynamic>{
        'phone': '13800138000',
        'password': '123456',
        'token': 'abcdef-token',
        'normalField': 'visible',
      },
    );
    _addLog('已发送敏感字段测试事件（phone/password/token）');
  }

  Future<void> _trackErrorEvent() async {
    try {
      throw StateError('analytics test throw');
    } catch (e, s) {
      await xbTrackError(
        e,
        s,
        extra: <String, dynamic>{'scene': 'manual_test'},
      );
    }
    _addLog('已调用 xbTrackError');
  }

  Future<void> _testUserContext() async {
    xbSetTrackUser('user_demo_1001');
    xbTrack('user_set_event', params: {'state': 'set'});
    xbClearTrackUser();
    xbTrack('user_clear_event', params: {'state': 'clear'});
    _addLog('已覆盖 xbSetTrackUser / xbClearTrackUser');
  }

  Future<void> _testCommonProvider() async {
    _commonProviderEnabled = !_commonProviderEnabled;
    xbSetTrackCommonParamsProvider(
      _commonProviderEnabled
          ? () => <String, dynamic>{
                'tenantId': 'dynamic_tenant_002',
                'storeId': 'cd_hightech_01',
                'abGroup': 'B',
              }
          : null,
    );
    xbTrack(
      'common_provider_toggle',
      params: {'enabled': _commonProviderEnabled},
    );
    _addLog('已切换 xbSetTrackCommonParamsProvider: $_commonProviderEnabled');
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _testPageHelpers() async {
    xbTrackPageView('ManualPage', params: {'manual': true});
    xbTrackPageHide('ManualPage', params: {'manual': true});
    xbTrackPageLeave(
      'ManualPage',
      durationMs: 1234,
      params: {'manual': true},
    );
    _addLog('已覆盖 xbTrackPageView / xbTrackPageHide / xbTrackPageLeave');
  }

  Future<void> _testAppHelpers() async {
    xbTrackAppForeground(params: {'source': 'manual'});
    xbTrackAppBackground(params: {'source': 'manual'});
    _addLog('已覆盖 xbTrackAppForeground / xbTrackAppBackground');
  }

  Future<void> _testTapHelper() async {
    xbTrackTap('analytics_test_tap_btn', params: {'from': 'test_page'});
    _addLog('已覆盖 xbTrackTap');
  }

  Future<void> _testFlushAndReadLatest() async {
    await xbFlushTrack();
    final events = await xbReadTrackLocalLatest(limit: 10, offset: 0);
    _addLog('xbFlushTrack 完成, xbReadTrackLocalLatest 拿到 ${events.length} 条');
    if (events.isNotEmpty) {
      _addLog('latest event: ${events.first.event}');
    }
  }

  Future<void> _testExportJson() async {
    final jsonText = await xbExportTrackAsJson(limit: 20);
    final len = jsonText.length;
    _addLog('xbExportTrackAsJson(limit:20) 长度=$len');

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is List && decoded.isNotEmpty) {
        final last = decoded.last;
        _addLog('JSON导出最后一条 event=${last['event']}');
      }
    } catch (e) {
      _addLog('JSON解析失败: $e');
    }
  }

  Future<void> _testExportText() async {
    final text = await xbExportTrackAsText(limit: 20);
    final lines =
        text.split('\n').where((element) => element.trim().isNotEmpty).toList();
    _addLog('xbExportTrackAsText(limit:20) 行数=${lines.length}');
  }

  Future<void> _testShareCallback() async {
    await xbShareTrackExport(limit: 10);
    _addLog('xbShareTrackExport 已调用, preview长度=${_sharePreview.length}');
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openDebugPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const XBTrackDebugPage(),
      ),
    );
    _addLog('已打开并返回 XBTrackDebugPage');
  }

  Future<void> _clearLocal() async {
    await xbClearTrackLocal();
    _addLog('已调用 xbClearTrackLocal');
  }

  Future<void> _closeTrack() async {
    await closeXBTrack(flushBeforeClose: true);
    _inited = false;
    _addLog('已调用 closeXBTrack(flushBeforeClose: true)');
    if (mounted) {
      setState(() {});
    }
  }

  Widget _btn(String title, Future<void> Function() onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ElevatedButton(
        onPressed: _loading ? null : () => _run(title, onTap),
        child: Text(title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('xb_analytics_plus 测试页')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '状态: inited=$_inited, commonProvider=$_commonProviderEnabled, '
            'spySinkTotal=${_spySink.totalEvents}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '目标：覆盖 init/track/error/user/common/export/share/read/clear/close/debug/helper。',
          ),
          const SizedBox(height: 12),
          _btn('1. initXBTrack（重新初始化）', _initTrack),
          _btn('2. xbTrack 手动业务事件', _trackManualEvent),
          _btn('3. 敏感字段脱敏测试', _trackSensitiveData),
          _btn('4. xbTrackError', _trackErrorEvent),
          _btn('5. 用户上下文 set/clear', _testUserContext),
          _btn('6. 切换公共参数 provider', _testCommonProvider),
          _btn('7. 页面事件 helper', _testPageHelpers),
          _btn('8. 前后台 helper', _testAppHelpers),
          _btn('9. 点击 helper', _testTapHelper),
          _btn('10. flush + readLatest', _testFlushAndReadLatest),
          _btn('11. 导出 JSON', _testExportJson),
          _btn('12. 导出 Text', _testExportText),
          _btn('13. share 回调测试', _testShareCallback),
          _btn('14. 打开 XBTrackDebugPage', _openDebugPage),
          _btn('15. 清空本地埋点', _clearLocal),
          _btn('16. closeXBTrack', _closeTrack),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton(
              onPressed: () {
                setState(_logs.clear);
              },
              child: const Text('17. 清空页面日志'),
            ),
          ),
          if (_loading) ...[
            const SizedBox(height: 6),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          Text(
            'share preview: ${_sharePreview.isEmpty ? '-' : _sharePreview}',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          const Text(
            '执行日志（最新在上）',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (_logs.isEmpty)
            const Text('暂无日志，点击上方按钮开始测试。')
          else
            ..._logs.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(e),
              ),
            ),
        ],
      ),
    );
  }
}

class _TestSpySink extends XBTrackSink {
  int totalEvents = 0;

  @override
  Future<void> onEvents(List<XBTrackEvent> events) async {
    totalEvents += events.length;
  }
}
