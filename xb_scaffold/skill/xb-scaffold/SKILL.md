---
name: xb-scaffold
description: Complete usage guide for the xb_scaffold Flutter framework (MVVM with XBPage/XBWidget/XBVM, theme system, dialogs, toast, loading, actionSheet, XBCell list cells, XBButton, XBImage, XBTable, pickers, floating tips, event bus, CLI tools). Use when the project depends on package:xb_scaffold, when writing or reviewing Flutter code that imports xb_scaffold, or when the user mentions XBPage, XBPageVM, XBVM, XBCell, XBButton, XBImage, XBScaffold, XBMaterialApp, xb toast/dialog/loading/actionSheet, or the xb.* CLI commands.
---

# XB Scaffold

`xb_scaffold` is a Provider-based Flutter scaffold providing an MVVM architecture, theming, routing helpers, dialogs, toast, loading, action sheets, a rich cell/button/table/picker component library, utilities, and a code-generation CLI. All public APIs are exported from `package:xb_scaffold/xb_scaffold.dart`.

## Golden rules

1. **MVVM first**: every page/component that owns state extends `XBPage`/`XBWidget` with a paired VM class. Never call `setState` for VM state; mutate VM fields then call `vm.notify()`.
2. **Global UI APIs** (`toast`, `dialog`, `actionSheet`, `showLoadingGlobal`, route push/pop via `xbNavigatorState`) work only after `XBScaffold`/`XBMaterialApp` is mounted. If you must use `MaterialApp`/`GetMaterialApp` instead of `XBMaterialApp`, pass `navigatorKey: xbNavigatorKey`.
3. **Theme access is global**: use the top-level getters `colors`, `fontSizes`, `fontWeights`, `spaces`, `images`, `app` (from `xb_theme_mixin.dart`) anywhere — e.g. `color: colors.primary`.
4. **Never import from `package:xb_scaffold/src/...`**; import `package:xb_scaffold/xb_scaffold.dart` only.

## App bootstrap (required)

```dart
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  initXBErrorHandler(
    reporter: (error, stack) {},       // forward to your crash reporter
    // errorWidgetBuilder, dumpFlutterErrorToConsole, enableErrorWidget,
    // enablePlatformDispatcherError, enableIsolateError are optional
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return XBMaterialApp(              // auto-injects xbRouteObserver + navigator key
      title: 'Demo',
      theme: ThemeData(useMaterial3: true),
      home: XBScaffold(                // initializes theme configs + global builders
        themeConfigs: [
          XBThemeConfig(primaryColor: Colors.blue, imgPrefix: "assets/images/theme1/"),
          XBThemeConfig(primaryColor: Colors.red,  imgPrefix: "assets/images/theme2/"),
        ],
        loadingBuilder: (context, msg) => const Center(child: CircularProgressIndicator()), // optional
        toastBackgroundColor: Colors.black87,   // optional
        child: const HomePage(),
      ),
    );
  }
}
```

- `initXBErrorHandler` is idempotent; call once before `runApp`. `appRunner:` may wrap `runApp` inside a guarded zone instead.
- Non-default themes fall back to theme 0's image prefix when an asset is missing there.
- `XBRootWidget(child: ..., onLoaded: ..., willExitTip: "再按一次退出应用", onAppPaused: ..., onAppResumed: ...)` wraps a home page to get "press-again-to-exit" and app lifecycle callbacks.

## Pages and widgets (MVVM core)

| Need | Base class | Override | VM base |
|---|---|---|---|
| Full-screen page with AppBar | `XBPage<VM>` | `generateVM`, `setTitle`, `buildPage` | `XBPageVM<Page>` |
| Reusable stateful component | `XBWidget<VM>` | `generateVM`, `buildWidget` | `XBVM<Widget>` |
| Stateless component | `XBVMLessWidget` | `buildWidget` | none |

```dart
class HomePage extends XBPage<HomePageVM> {
  const HomePage({super.key});
  @override
  HomePageVM generateVM(BuildContext context) => HomePageVM(context: context);
  @override
  String setTitle(BuildContext context) => "首页";
  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return Text('${vm.counter}');
  }
  @override
  List<Widget>? actions(BuildContext context) => []; // AppBar right side
}

class HomePageVM extends XBPageVM<HomePage> {
  HomePageVM({required super.context});
  int _counter = 0;
  int get counter => _counter;
  void increment() { _counter++; notify(); }
}
```

**VM access** (from any `BuildContext`):
- `context.vmOf<T>()` — no rebuild; use in callbacks.
- `context.vmWatch<T>()` — rebuilds on `notify()`; use in build methods.
- `context.vmOfOrNull<T>()` / `context.vmWatchOrNull<T>()` — null-safe variants.
- Inside `XBWidget`/`XBPage` subclasses: `vmOf(context)`, `vm`, `vmWatch` getters, `reset()` (new VM), `rebuildUI()`.

**XBVM essentials**: `notify()` refreshes UI; `listen<E>(cb)` subscribes to `XBEventBus` (auto-removed on dispose); `repo<R>()` / `setRepo(...)` attach an `XBRepository`; `widget` casts back to the owner widget; `didCreated()` / `widgetDidBuilt()` / `didChangeDependencies()` / `didUpdateWidget()` / `dispose()` are lifecycle hooks (call `super`).

**XBPageVM extras**: `showLoading({msg})` / `hideLoading()`; `back([result])`; `isTop`; route lifecycle `willShow`/`willHide`/`willDispose`/`didPush`/`didPop`/`didPushNext`/`didPopNext`; `addEnsureAfterPushAnimationTask(fn)`; drawer helpers.

## Page configuration (XBPage overrides)

- Visibility/layout: `needSafeArea` (default false), `needHideAppbar`, `needImmersiveAppbar`, `needRemovePadding` (default true), `needAdaptKeyboard`, `needPageContentAdaptTabbar`, `needRebuildWhileOrientationChanged`, `needRebuildWhileAppThemeChanged` (default true), `backgroundWidget`, `backgroundColor` (default `viewBG`).
- Loading: `needLoading` (default false) enables page-level loading overlay; `needInitLoading` shows it immediately; `buildLoading` customizes; `needResponse*WhileLoading` controls which regions stay interactive.
- AppBar: `navigationBarBGColor` / `navigationBarTitleColor` / `navigationBarTitleSize` / `navigationBarTitleFontWeight`, `leading`, `actions`, `buildTitle`, `leadingWidth`, `statusBarStyle` (`XBStatusBarStyle.light/dark`), `pushAnimationMilliseconds`.
- Back behavior: `canPop` (block back button + gestures), `handlePopSuccess` / `handlePopFailure`.

## Global UI one-liners

```dart
toast('Saved', duration: 3, bottom: 150, backgroundColor: Colors.black87, radius: 8, msgStyle: ...);
toastWidget(anyWidget, duration: 3);           // custom content, same overlay mechanics

dialog(                                        // iOS-style alert: white rounded card, bottom buttons
  title: '提示', msg: '确定删除吗？',
  btnTitles: ['取消', '确定'],                  // 1 or 2 buttons only
  onSelected: (i) { if (i == 1) delete(); },
);

dialogContent(title: 'x', content: myWidget, btnTitles: ['OK'], onSelected: (_) {}); // custom body
dialogWidget(XBDialogInput(title: '输入', placeholder: '...', onDone: (text) {}));   // input dialog
dialogWidget(anyWidget, priority: 1);          // any custom dialog (priority queue)

actionSheet(                                   // bottom sheet, white cells h=50, top radius 10
  titles: ['拍照', '相册'], onSelected: (i) {}, dismissTitle: '取消',
  selectedIndex: 1,                            // highlight current choice
);
actionSheetMulti(titles: [...], onDone: (selectedIndexes) {}, selectedIndexes: [0]); // multi-select
actionSheetWidget(widget: myPanel);            // custom bottom sheet

showLoadingGlobal(msg: '加载中');               // app-wide loading overlay (queue-based)
hideLoadingGlobal();
```

## Component quick map

Details, parameter tables and appearance notes: [reference/ui-components.md](reference/ui-components.md)

- **Cells** (`lib/src/common/xb_cell/`): `XBCellGroup` (rounded white card w/ separators), `XBCellTitle`, `XBCellTitleSelect`, `XBCellTitleSwitch`, `XBCellTitleImage`, `XBCellIconTitle`, `XBCellIconTitleSelect`, `XBCellIconTitleSwitch`, `XBCellTitleSubtitle`, `XBCellTitleSubtitlePoint`, `XBCellIconTitleSubtitlePoint`, `XBCellCenterTitle`, `XBCellTopIconBottomTitle`, `XBCellCustom`, `XBCellArrow`.
- **Buttons**: `XBButton` (tap wrapper w/ effects + debounce), `XBButtonText` (padded text button), `XBDisable`.
- **Images/text**: `XBImage` (url/asset/File/bytes/SVG auto-detect), `XBTextField` (+ `XBNumberTextInputFormatter`, `XBDoubleTextInputFormatter`).
- **Lists**: `XBHoveringHeaderList` (pinned section headers), `XBAdaptiveListView` (height-adaptive list), `XBMaxHeightContainer`.
- **Table/pickers**: `XBTable`, `XBTitlePicker` (Cupertino wheel), `XBTitlePickerMulti`.
- **Float/overlay**: `XBFloatWidget` (+ `XBFloatMenu`, `XBTip`), `XBRotatableFullscreen`.
- **Decor/misc**: `XBBG`, `XBShadowContainer`, `XBGradientWidget`, `XBFadeWidget`, `xbLine()`, `xbSpace()`, `XBEmptyAppBar`, `XBNavigatorBackBtn`, `XBLoadingWidget`, `XBLoadingMask`, `XBAnimationRotate`, `XBIosEdgeBackGesture`, `XBLegacyPopScope`.

## Screen metrics and style constants (global getters)

`screenW`, `screenH`, `screenSize`, `stateBarH`, `naviBarH`, `tabbarH`, `topBarH`, `screenHWithoutTopBarH`, `safeAreaBottom`, `onePixel`, `dpr`; colors `lineColor` (#E6E6E6), `viewBG`, `naviBarBG`, `naviBarTitle`; theme `colors.primary` (default #007AFF), `fontSizes.s8..s40` (`def`=16), `fontWeights.bold/semiBold/medium/normal/thin`, `spaces.gapDef`(17.5)/`gapLess`(13.5)/`gapLarge`(35), `images.imgPath(name)`; helpers `endEditing()`, `xbNavigatorState`, `xbNavigatorContext`, `isHarmony`, page log `recordPageLog`/`showPageLog`.

## Utilities

Details: [reference/utils-pitfalls.md](reference/utils-pitfalls.md)

- `XBEventBus.fire(event)` / `vm.listen<T>(cb)` / `XBEventBus.on<T>()`.
- `XBTimer` (once/repeat/cancel, optional `listeningVM` auto-cancel), `XBWaitTask` (timeout race), `XBPreventMultiTask` (debounce), `XBRefreshTasKUtil` (delayed refresh), `XBTask`.
- JSON parsing: `xbParse<T>(json['k'])`, `xbParseList<T>(json['k'], factory: Model.fromJson)`.
- `XBDateFormat('yyyy-MM-dd HH:mm:ss').format(dt)/parse(s)`, `XBTimeUtil` (nowMillis, nowTimeStr, isToday, formatSecondsToHMS).
- `XBSelectModel<T>` (isSelected + model), `XBUniqueList`, `XBStackList`, text/image size utils.

## Theme, repository layer, CLI

Details: [reference/theme-cli-repository.md](reference/theme-cli-repository.md)

- Multi-theme: `XBThemeVM().changeTheme(i)`; extend via Dart `extension` on `XBThemeColor`/`XBThemeFontSize`/etc.; `xb.extension` CLI generates starter files.
- Data layer: `XBRepository` → `XBService` → `XBDataSource` chain with paired init/dispose; attach via `vm.setRepo(...)`.
- CLI (`xb.setup`, `xb.page`, `xb.widget`, `xb.extension`, `xb.updateimg`, `xb.parsemodel`, `xb.newmodel`, `xb.skill`) — one-time setup: `dart run xb_scaffold:xb xb.setup`.

## Common pitfalls

- Calling `toast`/`dialog`/push before the navigator exists throws `StateError` ("XBScaffold ... is not ready") — ensure `XBScaffold` is mounted or bind `navigatorKey: xbNavigatorKey`.
- `XBPageVM.showLoading` is page-scoped and requires `needLoading(context) => true` on the page; use `showLoadingGlobal`/`hideLoadingGlobal` for anywhere-else loading.
- `dialog` supports only 1–2 buttons; more choices → `actionSheet`.
- Don't cache a VM obtained from a widget; fetch via `context.vmOf` each time to avoid stale disposal.
- `XBImage` on web does not support `File` inputs.
- In `testWidgets`, live global streams can hang the test — wrap listeners in `tester.runAsync`.
- `XBCellTitleSwitch` passes `isNeedBtn: false` by default (the switch itself handles taps); set `onTap` to receive change events.

## Deeper references

- App bootstrap, MVVM lifecycle, navigation, error handling: [reference/core.md](reference/core.md)
- Full component library (styles + parameters): [reference/ui-components.md](reference/ui-components.md)
- Theming, data layer, CLI commands: [reference/theme-cli-repository.md](reference/theme-cli-repository.md)
- Utilities and gotchas: [reference/utils-pitfalls.md](reference/utils-pitfalls.md)
