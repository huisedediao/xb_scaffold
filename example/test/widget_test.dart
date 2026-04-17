import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  testWidgets('xb_route API coverage test', (WidgetTester tester) async {
    Future<void> waitRouteTransition() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
    }

    await tester.pumpWidget(const _RouteTestApp());
    await waitRouteTransition();

    final pageA = const _RoutePageA();
    push(pageA, 1);
    await waitRouteTransition();
    expect(topIsType(_RoutePageA), isTrue); // topIsType
    expect(stackContainType(_RoutePageA), isTrue); // stackContainType

    final mappedRoute = MaterialPageRoute<void>(
      settings: RouteSettings(
        name: '${pageA.runtimeType}',
        arguments: {
          xbCategoryNameKey: xbCategoryName,
          xbHashCodeKey: pageA.hashCode,
        },
      ),
      builder: (context) => pageA,
    );

    expect(isXBRoute(mappedRoute), isTrue); // isXBRoute
    expect(
      routeIsMapWidget(route: mappedRoute, widget: pageA), // routeIsMapWidget
      isTrue,
    );

    replace(const _RoutePageB(), 1); // replace
    await waitRouteTransition();
    expect(find.text('route-B'), findsOneWidget);

    push(const _RoutePageC(), 1); // push
    await waitRouteTransition();
    expect(topIsType(_RoutePageC), isTrue);

    pop(); // pop
    await waitRouteTransition();
    expect(find.text('route-B'), findsOneWidget);

    push(const _RoutePagePopUntilA(), 1);
    await waitRouteTransition();
    push(const _RoutePagePopUntilB(), 1);
    await waitRouteTransition();
    push(const _RoutePagePopUntilC(), 1);
    await waitRouteTransition();
    expect(topIsType(_RoutePagePopUntilC), isTrue);

    popUntilType(_RoutePagePopUntilA); // popUntilType
    await waitRouteTransition();
    expect(topIsType(_RoutePagePopUntilA), isTrue);

    pushAndClearStack(const _RoutePageClearStack(), 1); // pushAndClearStack
    await waitRouteTransition();
    expect(find.text('route-CLEAR'), findsOneWidget);

    push(const _RoutePageAfterClear(), 1);
    await waitRouteTransition();
    expect(xbNavigatorState.canPop(), isTrue);

    popToRoot(); // popToRoot
    await waitRouteTransition();
    expect(xbNavigatorState.canPop(), isFalse);
    expect(find.text('route-home'), findsOneWidget);
  });
}

class _RouteTestApp extends StatelessWidget {
  const _RouteTestApp();

  @override
  Widget build(BuildContext context) {
    return XBMaterialApp(
      home: XBScaffold(
        themeConfigs: [XBThemeConfig(primaryColor: Colors.blue, imgPrefix: '')],
        child: const _RouteHomePage(),
      ),
    );
  }
}

class _RouteHomePage extends StatelessWidget {
  const _RouteHomePage();

  @override
  Widget build(BuildContext context) {
    return const Material(
      child: SizedBox.expand(
        child: Center(
          child: Text('route-home'),
        ),
      ),
    );
  }
}

class _RoutePageA extends StatelessWidget {
  const _RoutePageA();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('A');
}

class _RoutePageB extends StatelessWidget {
  const _RoutePageB();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('B');
}

class _RoutePageC extends StatelessWidget {
  const _RoutePageC();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('C');
}

class _RoutePagePopUntilA extends StatelessWidget {
  const _RoutePagePopUntilA();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('PU-A');
}

class _RoutePagePopUntilB extends StatelessWidget {
  const _RoutePagePopUntilB();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('PU-B');
}

class _RoutePagePopUntilC extends StatelessWidget {
  const _RoutePagePopUntilC();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('PU-C');
}

class _RoutePageClearStack extends StatelessWidget {
  const _RoutePageClearStack();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('CLEAR');
}

class _RoutePageAfterClear extends StatelessWidget {
  const _RoutePageAfterClear();

  @override
  Widget build(BuildContext context) => const _RoutePageBody('AFTER-CLEAR');
}

class _RoutePageBody extends StatelessWidget {
  final String tag;
  const _RoutePageBody(this.tag);

  @override
  Widget build(BuildContext context) {
    return Material(
      child: SizedBox.expand(
        child: Center(child: Text('route-$tag')),
      ),
    );
  }
}
