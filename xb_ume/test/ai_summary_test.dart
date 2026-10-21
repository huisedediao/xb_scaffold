import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

void main() {
  group('buildAiSummaryHtml', () {
    test('基础报告（未生成、无错误）不输出区块', () {
      expect(gui.buildAiSummaryHtml(null), '');
    });

    test('生成中显示进度提示', () {
      final html = gui.buildAiSummaryHtml(null, summarizing: true);
      expect(html, contains('AI 总结'));
      expect(html, contains('正在生成 AI 总结'));
    });

    test('生成失败显示原因并转义 HTML', () {
      final html = gui.buildAiSummaryHtml(null, error: '未配置 <key>');
      expect(html, contains('未生成 AI 总结'));
      expect(html, contains('未配置 &lt;key&gt;'));
      expect(html, isNot(contains('<key>')));
    });

    test('完整总结渲染指标/覆盖/正文/问题/生成信息', () {
      final html = gui.buildAiSummaryHtml(
        <String, Object?>{
          'verdict': '20 次中成功 17 次，成功率 85%',
          'metrics': [
            {'name': '总次数', 'value': '20', 'basis': '轮 1-20'},
            {'name': '成功率', 'value': '85%', 'basis': '成功 17 / 总 20'},
          ],
          'requirements': [
            {'requirement': '连续测 20 次', 'status': 'met', 'evidence': '轮 1-20'},
            {
              'requirement': '计算成功率',
              'status': 'unmet',
              'evidence': '记录无成功判定',
            },
          ],
          'summary': '执行了 20 次播放。',
          'issues': ['第 3 次播放失败'],
          'confidence': 'high',
          'coverageWarning': '覆盖可能不全：指令要求 20 未在总结中出现',
        },
        ms: 2500,
        model: 'mock-model',
      );
      expect(html, contains('成功率 85%'));
      expect(html, contains('总次数'));
      expect(html, contains('成功 17 / 总 20'));
      expect(html, contains('连续测 20 次'));
      expect(html, contains('✅ 满足'));
      expect(html, contains('❌ 未满足'));
      expect(html, contains('执行了 20 次播放'));
      expect(html, contains('第 3 次播放失败'));
      expect(html, contains('覆盖可能不全'));
      expect(html, contains('模型 mock-model'));
      expect(html, contains('耗时 2.5s'));
      expect(html, contains('把握度 高'));
    });

    test('字段类型异常时不抛异常', () {
      final html = gui.buildAiSummaryHtml(<String, Object?>{
        'verdict': 42,
        'metrics': 'bad',
        'requirements': [1, null],
        'summary': null,
        'issues': 'bad',
      });
      expect(html, contains('AI 总结'));
      expect(html, contains('42'));
    });
  });

  group('aiSummaryMissingRequirements', () {
    test('数量要求已覆盖（requirements 或 metrics）', () {
      final s = <String, dynamic>{
        'requirements': [
          {'requirement': '连续测 20 次', 'status': 'met', 'evidence': '轮 1-20'},
        ],
        'metrics': [
          {'name': '成功率', 'value': '85%', 'basis': '成功 17 / 总 20'},
        ],
      };
      expect(
        gui.aiSummaryMissingRequirements(s, '连续测 20 次，计算成功率'),
        isEmpty,
      );
    });

    test('数量要求缺失返回缺失项', () {
      final s = <String, dynamic>{
        'requirements': [
          {'requirement': '进入播放页', 'status': 'met', 'evidence': '路由 /play'},
        ],
        'metrics': <Object?>[],
      };
      expect(
        gui.aiSummaryMissingRequirements(s, '播放成功或失败算一次，连续测 20 次'),
        ['20'],
      );
    });

    test('指令无数字时不检查', () {
      expect(
        gui.aiSummaryMissingRequirements(<String, dynamic>{}, '打开设置页'),
        isEmpty,
      );
    });
  });
}
