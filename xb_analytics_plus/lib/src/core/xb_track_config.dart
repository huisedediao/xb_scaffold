import 'xb_track_sink.dart';
import 'xb_track_store.dart';
import 'xb_track_types.dart';

class XBTrackConfig {
  final bool enabled;
  final int flushBatchSize;
  final Duration flushInterval;
  final int maxPendingQueueSize;
  final int maxEventBytes;
  final double sampleRate;
  final int memoryMaxEvents;
  final int ioMaxBytes;
  final int webMaxBytes;
  final String schemaVersion;
  final String? appVersion;
  final String? platform;
  final bool enableConsoleSink;
  final bool enableMemorySink;
  final bool enableLocalStoreSink;
  final XBTrackCommonParamsProvider? commonParamsProvider;
  final XBTrackSanitizer? sanitizer;
  final XBTrackShareRequested? onShareRequested;
  final List<XBTrackSink> sinks;
  final XBTrackStore? store;
  final Set<String> sensitiveKeys;
  final String sensitiveValueMask;
  final bool dropEventsWhenQueueFull;
  final bool debugPrintDropReason;
  final String storeNamespace;

  const XBTrackConfig({
    this.enabled = true,
    this.flushBatchSize = 20,
    this.flushInterval = const Duration(seconds: 1),
    this.maxPendingQueueSize = 5000,
    this.maxEventBytes = 8 * 1024,
    this.sampleRate = 1.0,
    this.memoryMaxEvents = 1000,
    this.ioMaxBytes = 20 * 1024 * 1024,
    this.webMaxBytes = 3 * 1024 * 1024,
    this.schemaVersion = '1.0.0',
    this.appVersion,
    this.platform,
    this.enableConsoleSink = false,
    this.enableMemorySink = true,
    this.enableLocalStoreSink = true,
    this.commonParamsProvider,
    this.sanitizer,
    this.onShareRequested,
    this.sinks = const <XBTrackSink>[],
    this.store,
    this.sensitiveKeys = const <String>{
      'password',
      'passwd',
      'token',
      'access_token',
      'refresh_token',
      'idcard',
      'id_card',
      'phone',
      'mobile',
    },
    this.sensitiveValueMask = '***',
    this.dropEventsWhenQueueFull = true,
    this.debugPrintDropReason = false,
    this.storeNamespace = 'xb_track',
  })  : assert(flushBatchSize > 0),
        assert(maxPendingQueueSize > 0),
        assert(maxEventBytes > 256),
        assert(sampleRate > 0 && sampleRate <= 1.0),
        assert(memoryMaxEvents > 0),
        assert(ioMaxBytes > 0),
        assert(webMaxBytes > 0),
        assert(storeNamespace != '');
}
