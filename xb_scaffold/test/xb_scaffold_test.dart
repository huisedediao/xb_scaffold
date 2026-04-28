import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

const _testSvg = '''
<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg">
  <rect width="16" height="16" fill="#1677ff"/>
</svg>
''';

void main() {
  testWidgets('XBImage renders svg string bytes and files',
      (WidgetTester tester) async {
    late List<Widget> built;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            built = [
              const XBImage(_testSvg, width: 16, height: 16).build(context),
              XBImage(
                Uint8List.fromList(utf8.encode(_testSvg)),
                width: 16,
                height: 16,
              ).build(context),
              XBImage(File('icon.svg'), width: 16, height: 16).build(context),
            ];
            return const SizedBox();
          },
        ),
      ),
    );

    expect(built, everyElement(isA<SvgPicture>()));
  });

  testWidgets('XBImage keeps non-svg string paths as Image',
      (WidgetTester tester) async {
    late Widget built;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            built = const XBImage('assets/images/icon.png').build(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(built, isA<Image>());
  });

  testWidgets('XBImage detects svg urls with query parameters',
      (WidgetTester tester) async {
    late Widget built;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            built = const XBImage(
              'https://example.com/icon.svg?v=1',
              width: 16,
              height: 16,
            ).build(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(built, isA<SvgPicture>());
  });

  testWidgets('XBImage passes svgColor to SvgPicture',
      (WidgetTester tester) async {
    late SvgPicture built;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            built = const XBImage(
              _testSvg,
              svgColor: Colors.red,
            ).build(context) as SvgPicture;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(
      built.colorFilter,
      const ColorFilter.mode(Colors.red, BlendMode.srcIn),
    );
  });
}
