# XB Scaffold Core: Bootstrap, MVVM, Navigation, Errors

## Bootstrap

```dart
void main() {
  initXBErrorHandler(reporter: (error, stack) async { /* send to Sentry etc. */ });
  runApp(const MyApp());
}
```

`initXBErrorHandler` parameters (all optional except none):

| Parameter | Type | Default | Purpose |
|---|---|---|---|
| `reporter` | `FutureOr<void> Function(Object, StackTrace?)` | null | crash reporting callback |
| `errorWidgetBuilder` | `Widget? Function(BuildContext, FlutterErrorDetails, String? routeName)` | null | custom build-error fallback UI |
| `dumpFlutterErrorToConsole` | bool | true | print framework errors to console |
| `enableErrorWidget` | bool | true | replace red error screen with `XBErrorView` |
| `enablePlatformDispatcherError` | bool | true | catch root-isolate uncaught errors |
| `enableIsolateError` | bool | false | listen to spawned isolate errors |
| `appRunner` | `FutureOr<void> Function()?` | null | run inside `runZonedGuarded` |

Idempotent — repeated calls are ignored. `errorWidgetBuilder` must never throw.

### XBScaffold

```dart
XBScaffold(
  required Widget child,
  required List<XBThemeConfig> themeConfigs,
  XBLoadingBuilder? loadingBuilder,   // Widget Function(BuildContext, String? msg)
  Color? toastBackgroundColor,
  int? maxPageLogLen,                 // page log ring buffer, default 30
)
```

Initializes theme map (one `XBTheme` per config index, scanned against `AssetManifest`), stores the loading builder and toast color globally. Non-first themes fall back to theme 0's `imgPrefix` for missing images.

### XBMaterialApp

Drop-in `MaterialApp` replacement that binds `xbNavigatorKey` and injects `xbRouteObserver` into `navigatorObservers` (required for `XBPageVM` show/hide callbacks). Supports the standard `MaterialApp` fields (home, routes, theme, locale, builder, ...).

If using `GetMaterialApp`/`CupertinoApp`/plain `MaterialApp` instead, pass `navigatorKey: xbNavigatorKey` yourself and add `xbRouteObserver` to observers.

## MVVM classes

### XBWidget<T extends XBVM> (base of everything)

Override:
- `T generateVM(BuildContext context)` — construct the VM (required).
- `Widget buildWidget(BuildContext context)` — the UI (required).
- `bool get wantKeepAlive` — keep state in lists (default false).

Instance members: `vmOf(context)` (no rebuild), `vmWatchOf(context)` (rebuilds), state-level `vm`, `vmWatch`, `reset()` (recreates VM and refreshes), `rebuildUI()`.

The widget wraps itself in `ChangeNotifierProvider<T>.value` + `Consumer<T>` and a `LayoutBuilder` that feeds `vm.widgetSize`.

### XBVM<T>

- Constructor: `MyVM({required super.context})`. `context` is stored for global access.
- `widget` — cast to the owning widget type `T`.
- `notify()` — call after mutating fields; ignored after dispose.
- `didCreated()` — VM created (init data here). `widgetDidBuilt()` — first frame built (post-frame). `didChangeDependencies()`, `didUpdateWidget(oldWidget)`, `dispose()` — always call `super`.
- `listen<E>(Function(E) onData)` — event bus subscription auto-cancelled on dispose.
- `setRepo(XBRepository?)` / `repo<R>()` — lifecycle-managed repository.
- `disposed` — check before async work completes.
- `widgetSize` / `widgetSizeDidChanged()` — react to layout size changes.

### XBPage<T extends XBPageVM> extends XBWidget<T>

Override `buildPage(context)` (body), `setTitle(context)` (AppBar title), optionally everything listed in the SKILL.md "Page configuration" section plus `drawer`, `endDrawer`, `leading`, `actions`, `buildTitle`, `buildLoading`, `buildAppBar`.

### XBPageVM<T> extends XBVM<T> with RouteAware

- Loading: `showLoading({String? msg})`, `hideLoading()`, `loadingMsg`. Requires the page's `needLoading => true`; `needInitLoading => true` shows loading from constructor.
- Navigation: `back<O>([O result])` → `xbNavigatorState.maybePop`.
- Route lifecycle (via `xbRouteObserver`): `didPush`/`didPop`/`didPushNext`/`didPopNext` call `isTop` flips and `willShow`/`willHide`/`willDispose` hooks.
- `addEnsureAfterPushAnimationTask(fn)` — run fn after push animation completes (or immediately if finished). `notifyNeedAfterPushAnimation(context) => true` on the page defers all `notify()` until the push animation ends.
- Drawers: `openDrawer/closeDrawer/openEndDrawer/closeEndDrawer` via `scaffoldKey`.
- Web: if `setTitle` is non-empty, sets `document.title` and restores on pop.

### XBVMLessWidget

Stateless variant: just override `buildWidget(BuildContext context)`. Used for stateless building blocks (`XBLoadingWidget`, etc.).

## Navigation

Global accessors (throw `StateError` with fix hints if not ready):
- `xbNavigatorState` — `push`, `maybePop`, `pop`.
- `xbNavigatorContext` — root navigator context for `showDialog`/`showModalBottomSheet`.
- `xbOverlayState` — for custom overlay entries.
- Null-safe variants: `xbNavigatorStateOrNull`, `xbNavigatorContextOrNull`, `xbOverlayStateOrNull`.
- `xbNavigatorKey` — the GlobalKey to bind manually when not using `XBMaterialApp`.
- `endEditing({BuildContext? context})` — dismiss keyboard.
- `xbRouteObserver` — `RouteObserver<ModalRoute<void>>` for external subscriptions.
- Push page transition logging is built in; inspect via `pageLogInfo()` / `showPageLog()`.

Push example:

```dart
xbNavigatorState.push(MaterialPageRoute(builder: (_) => const DetailPage()));
```

## Error handling

`XBErrorHandler.handle(error, stackTrace)` is invoked automatically from `FlutterError.onError`, `PlatformDispatcher.onError`, build-error fallback and (optionally) isolate listeners; it dedupes identical errors (hash list, cap 300) and forwards to `reporter`. `XBErrorView` is the default build-error widget showing error + stack.

## Page log

Every `XBPageVM` lifecycle transition is recorded (timestamped, UTC+8). Inspect with `pageLogInfo()` / `showPageLog()`; cap via `XBScaffold(maxPageLogLen:)`.
