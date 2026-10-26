// mobile-mcp 适配器单测：用本地假 MCP HTTP 服务锁定协议行为，不依赖 npx / 外网。
//
// 覆盖：
//   - 端口已有适配器时直接复用（不拉起进程）；
//   - 纯 JSON 与 SSE 两种响应体都能解析；
//   - mcp-session-id 在后续请求里回传；
//   - 能力矩阵按 tools/list 推导；
//   - 工具名模糊匹配与参数映射（button / packageName / bundleId / 坐标）；
//   - 适配器未暴露的能力抛 DeviceUnsupported，而不是假装成功。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/bridge.dart';
import '../bin/src/device/mobile_mcp.dart';

/// 模拟 mobile-mcp 实际暴露的工具名。
const List<Map<String, Object?>> _realisticTools = <Map<String, Object?>>[
  {'name': 'mobile_list_available_devices'},
  {'name': 'mobile_install_app'},
  {'name': 'mobile_uninstall_app'},
  {'name': 'mobile_launch_app'},
  {'name': 'mobile_terminate_app'},
  {'name': 'mobile_press_button'},
  {'name': 'mobile_click_on_screen_at_coordinates'},
  {'name': 'mobile_list_crashes'},
];

void main() {
  late HttpServer server;
  late List<Map<String, Object?>> tools;
  late String devicePayload;
  final calls = <Map<String, Object?>>[];
  final sessionHeaders = <String?>[];

  /// 每个测试独立起一个假适配器（随机端口），bridge 走「复用已有端点」分支。
  Future<MobileMcpBridge> newBridge() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final msg = body.trim().isEmpty
          ? <String, Object?>{}
          : (jsonDecode(body) as Map).cast<String, Object?>();
      final method = '${msg['method']}';
      final params =
          (msg['params'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
      // 通知（无 id）按 MCP 约定回 202 且不带响应体。
      if (msg['id'] == null) {
        req.response.statusCode = HttpStatus.accepted;
        await req.response.close();
        return;
      }
      sessionHeaders.add(req.headers.value('mcp-session-id'));

      var sse = false;
      Map<String, Object?> result;
      switch (method) {
        case 'initialize':
          req.response.headers.set('mcp-session-id', 'sid-test');
          result = <String, Object?>{
            'protocolVersion': '2025-06-18',
            'capabilities': <String, Object?>{},
            'serverInfo': <String, Object?>{'name': 'fake-mobile-mcp', 'version': '0'},
          };
        case 'tools/list':
          result = <String, Object?>{'tools': tools};
          sse = true;
        case 'tools/call':
          calls.add(<String, Object?>{
            'name': params['name'],
            'arguments': params['arguments'],
          });
          result = <String, Object?>{
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': _toolText('${params['name']}', devicePayload),
              },
            ],
          };
          sse = true;
        default:
          result = <String, Object?>{};
      }
      final response = <String, Object?>{'jsonrpc': '2.0', 'id': msg['id'], 'result': result};
      if (sse) {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write('event: message\ndata: ${jsonEncode(response)}\n\n');
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(response));
      }
      await req.response.close();
    });
    return MobileMcpBridge(port: server.port, npx: 'npx');
  }

  setUp(() {
    calls.clear();
    sessionHeaders.clear();
    tools = List<Map<String, Object?>>.of(_realisticTools);
    devicePayload = jsonEncode(<Object?>[
      <String, Object?>{
        'id': 'emulator-5554',
        'name': 'Pixel 8',
        'platform': 'android',
        'state': 'device',
      },
    ]);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('复用已有端点并解析 SSE 下的设备列表', () async {
    final bridge = await newBridge();
    final devices = await bridge.listDevices();

    expect(devices, hasLength(1));
    expect(devices.single.id, 'emulator-5554');
    expect(devices.single.name, 'Pixel 8');
    expect(devices.single.platform, 'android');
    expect(devices.single.backend, 'mobile-mcp');
    expect(devices.single.usable, isTrue);

    // initialize 不带会话头；后续请求必须回传 mcp-session-id。
    expect(sessionHeaders.first, isNull);
    expect(sessionHeaders.where((h) => h == 'sid-test'), isNotEmpty);

    await bridge.dispose();
  });

  test('能力矩阵按 tools/list 推导', () async {
    final bridge = await newBridge();
    await bridge.warmup();
    expect(
      bridge.capabilities,
      containsAll(<DeviceCapability>[
        DeviceCapability.install,
        DeviceCapability.uninstall,
        DeviceCapability.launch,
        DeviceCapability.terminate,
        DeviceCapability.pressKey,
        DeviceCapability.tapNative,
        DeviceCapability.crashList,
      ]),
    );
    // 未暴露的工具不声明能力。
    expect(bridge.capabilities, isNot(contains(DeviceCapability.crashGet)));
    await bridge.dispose();
  });

  test('按键 / 点击 / 启动的参数映射', () async {
    final bridge = await newBridge();
    await bridge.pressKey('emulator-5554', DeviceKey.back);
    var args = (calls.last['arguments'] as Map).cast<String, Object?>();
    expect(calls.last['name'], 'mobile_press_button');
    expect(args['button'], 'BACK');
    expect(args['key'], 'back');
    expect(args['deviceId'], 'emulator-5554');

    await bridge.tapNative('emulator-5554', 120, 340);
    args = (calls.last['arguments'] as Map).cast<String, Object?>();
    expect(calls.last['name'], 'mobile_click_on_screen_at_coordinates');
    expect(args['x'], 120);
    expect(args['y'], 340);

    final note = await bridge.launch('emulator-5554', 'com.example.demo');
    args = (calls.last['arguments'] as Map).cast<String, Object?>();
    expect(calls.last['name'], 'mobile_launch_app');
    expect(args['packageName'], 'com.example.demo');
    expect(args['bundleId'], 'com.example.demo');
    expect(note, 'launched com.example.demo');

    await bridge.dispose();
  });

  test('空设备列表带 hint 时不伪造设备', () async {
    // 真实适配器在没有模拟器时会返回这个形状。
    devicePayload = jsonEncode(<String, Object?>{
      'devices': <Object?>[],
      'hint': 'No local device, simulator or emulator is available.',
    });
    final bridge = await newBridge();
    expect(await bridge.listDevices(), isEmpty);
    await bridge.dispose();
  });

  test('适配器未暴露的能力抛 DeviceUnsupported', () async {
    tools = <Map<String, Object?>>[
      {'name': 'mobile_list_available_devices'},
    ];
    final bridge = await newBridge();
    expect(
      () => bridge.tapNative('emulator-5554', 1, 1),
      throwsA(isA<DeviceUnsupported>()
          .having((e) => e.capability, 'capability', DeviceCapability.tapNative)),
    );
    expect(
      () => bridge.crashGet('emulator-5554', 'x'),
      throwsA(isA<DeviceUnsupported>()),
    );
    await bridge.dispose();
  });
}

/// 假适配器返回的文本：设备列表给 JSON，其余给一行可读文案。
String _toolText(String tool, String devicesJson) {
  if (tool == 'mobile_list_available_devices') return devicesJson;
  if (tool == 'mobile_launch_app') return 'launched com.example.demo';
  return 'ok';
}
