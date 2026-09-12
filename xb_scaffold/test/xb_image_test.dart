import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('XBImage 类型分发：空值/bytes/svg/url/asset 全分支', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    // XBImage.build 仅做类型分发，不依赖真实 context；
    // 直接调用 build 以隔离 asset/网络加载副作用（挂载真实
    // Image.asset/CachedNetworkImage 会触发测试环境不允许的资源加载）
    final ctx = tester.element(find.byType(SizedBox));

    // 空值/空字符串 → 占位 widget
    expect(const XBImage(null).build(ctx), isA<Container>());
    expect(const XBImage('').build(ctx), isA<Container>());

    // 自定义占位 widget 被保留
    const placeholder = SizedBox(key: Key('ph'));
    final phWidget =
        const XBImage(null, placeholderWidget: placeholder).build(ctx);
    expect(phWidget, isA<SizedBox>());
    expect((phWidget as SizedBox).key, const Key('ph'));

    // Uint8List → Image.memory
    final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
    final memWidget = XBImage(bytes).build(ctx);
    expect(memWidget, isA<Image>());
    expect((memWidget as Image).image, isA<MemoryImage>());

    // SVG 字符串 / data URI / 网络 svg → SvgPicture
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>';
    expect(const XBImage(svg).build(ctx), isA<SvgPicture>());
    const uri =
        'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=';
    expect(const XBImage(uri).build(ctx), isA<SvgPicture>());
    expect(const XBImage('https://a.com/icon.svg').build(ctx), isA<SvgPicture>());

    // http 普通 url → CachedNetworkImage
    expect(const XBImage('https://a.com/photo.png').build(ctx),
        isA<CachedNetworkImage>());

    // 本地 asset：png → Image.asset，svg → SvgPicture.asset
    final assetWidget = const XBImage('assets/images/icon.png').build(ctx);
    expect(assetWidget, isA<Image>());
    expect((assetWidget as Image).image, isA<AssetImage>());
    expect(const XBImage('assets/images/icon.svg').build(ctx), isA<SvgPicture>());
  });

  group('XBImgSizeUtil', () {
    /// 运行时生成指定宽高的真实 PNG，避免硬编码字节
    Future<Uint8List> genPng(int width, int height) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()..color = const Color(0xFFFF0000));
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    testWidgets('空输入返回 Size.zero', (tester) async {
      expect(await XBImgSizeUtil.getImageSizeFromUrl(''), Size.zero);
      expect(
          await XBImgSizeUtil.getImageSizeFromMemory(Uint8List(0)), Size.zero);
    });

    testWidgets('内存 PNG 解码出正确宽高', (tester) async {
      // 图片编解码是真实 dart:ui 异步，fake-async 环境需 runAsync 驱动
      final pngBytes = (await tester.runAsync(() => genPng(2, 3)))!;
      final size = await tester
          .runAsync(() => XBImgSizeUtil.getImageSizeFromMemory(pngBytes));
      expect(size, const Size(2, 3), reason: '2x3 图片应解码出 Size(2, 3)');
    });

    testWidgets('相同 bytes 命中缓存', (tester) async {
      final pngBytes = (await tester.runAsync(() => genPng(4, 5)))!;
      final first = await tester
          .runAsync(() => XBImgSizeUtil.getImageSizeFromMemory(pngBytes));
      final second = await tester
          .runAsync(() => XBImgSizeUtil.getImageSizeFromMemory(pngBytes));
      expect(first, const Size(4, 5));
      expect(second, first);
    });
  });
}
