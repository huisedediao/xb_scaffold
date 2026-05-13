import 'package:flutter/material.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_plugin.dart';
import '../../utils/xb_ume_time.dart';

class XBUmePerformancePlugin extends XBUmePlugin {
  @override
  String get id => 'performance';

  @override
  String get title => 'Performance';

  @override
  IconData get icon => Icons.speed;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _PerformancePanel(controller: controller);
  }
}

class _PerformancePanel extends StatelessWidget {
  const _PerformancePanel({required this.controller});

  final XBUmeController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.changeTick,
      builder: (context, _, __) {
        final frames = controller.frames.reversed.toList(growable: false);

        final avgTotal = _avg(frames.map((e) => e.totalMs));
        final avgBuild = _avg(frames.map((e) => e.buildMs));
        final avgRaster = _avg(frames.map((e) => e.rasterMs));
        final jankCount = frames.where((e) => e.isJank).length;
        final fps = avgTotal == 0 ? 0 : (1000 / avgTotal);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip('frames', '${frames.length}'),
                  _chip('avg fps', fps.toStringAsFixed(1)),
                  _chip('avg total', '${avgTotal.toStringAsFixed(2)} ms'),
                  _chip('avg build', '${avgBuild.toStringAsFixed(2)} ms'),
                  _chip('avg raster', '${avgRaster.toStringAsFixed(2)} ms'),
                  _chip('jank', '$jankCount'),
                  OutlinedButton(
                    onPressed: controller.clearFrames,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: frames.isEmpty
                  ? const Center(child: Text('No frame timings'))
                  : ListView.builder(
                      itemCount: frames.length,
                      itemBuilder: (context, index) {
                        final frame = frames[index];
                        return ListTile(
                          dense: true,
                          leading: SizedBox(
                            width: 84,
                            child: Text(
                              xbUmeFormatTime(frame.time),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                          title: Text(
                            'total ${frame.totalMs.toStringAsFixed(2)}ms '
                            '| build ${frame.buildMs.toStringAsFixed(2)}ms '
                            '| raster ${frame.rasterMs.toStringAsFixed(2)}ms',
                            style: TextStyle(
                              fontSize: 12,
                              color: frame.isJank
                                  ? Colors.red.shade700
                                  : Colors.black87,
                              fontWeight: frame.isJank
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            frame.isJank ? 'Jank frame' : 'Smooth frame',
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _chip(String key, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.04),
      ),
      child: Text(
        '$key: $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  double _avg(Iterable<double> values) {
    double sum = 0;
    int count = 0;
    for (final value in values) {
      sum += value;
      count += 1;
    }
    if (count == 0) return 0;
    return sum / count;
  }
}
