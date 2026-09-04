# XB Scaffold Utilities and Pitfalls

## Logging

```dart
xbLog(obj); xbDebug(obj); xbInfo(obj); xbWarn(obj); xbError(obj); xbFatal(obj); xbUnDisappear(obj);
```

Timestamped, ANSI-colored, chunked at 800 chars to survive `debugPrint` truncation. `log/debug/info/warn/error` print only in debug mode; `fatal`/`unDisappear` always print.

Page lifecycle log ring buffer: `pageLogList`, `pageLogInfo()`, `showPageLog()` (see core.md).

## Event bus

```dart
class UserLoginEvent { final String username; UserLoginEvent(this.username); }

// In a VM (auto-cancelled on dispose):
@override
void didCreated() {
  super.didCreated();
  listen<UserLoginEvent>((event) => print(event.username));
}

// Anywhere else:
XBEventBus.fire(UserLoginEvent('john'));
final sub = XBEventBus.on<UserLoginEvent>().listen(...);  // manual cleanup needed
XBEventBus.removeListener(listenerObj);                    // required for non-VM listeners
```

Type-filtered broadcast stream. Prefer `vm.listen` so cancellation is automatic.

## Timers and tasks

```dart
final timer = XBTimer();                      // or XBTimer(listeningVM: vm) auto-cancel
timer.once(duration: Duration(seconds: 2), onTick: () {});
timer.repeat(duration: Duration(seconds: 1), onTick: () {});
timer.cancel();

XBPreventMultiTask(intervalMilliseconds: 1000).execute(() { submit(); },
    onError: () => toast('请勿重复点击'));      // debounce; executes only outside the window

final result = await XBWaitTask().execute<dynamic>(   // race task vs timeout
  task: () async => await loadAll(),
  param: null,
  milliseconds: 5000,
);
if (result == XBWaitTask.timeout) { /* timed out */ }  // XBWaitTask.paramErr = bad task signature

XBRefreshTasKUtil(duration: Duration(milliseconds: 300)).refresh(
  XBTask(params: query, execute: (p) => search(p)));   // trailing-edge delayed task (search box)
```

## JSON parsing (no codegen required)

```dart
class UserModel {
  String? name;
  int? age;
  List<Tag>? tags;

  UserModel.fromJson(Map<String, dynamic> json) {
    name  = xbParse<String>(json['name']);
    age   = xbParse<int>(json['age']);
    tags  = xbParseList<Tag>(json['tags'], factory: Tag.fromJson);
  }
}
```

- `xbParse<T>(dynamic)` handles `String`/`int`/`double`/`bool` coercion (bool: numeric `trueValue`, default 1) and `Map` + `factory` for objects; returns null on failure.
- `xbParseList<T>(dynamic, {trueValue, factory})` maps a JSON array, dropping null-parses.
- Use the `xb.parsemodel` / `xb.newmodel` CLI to generate these bodies.

## Date and time

```dart
XBDateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
XBDateFormat('yyyy-MM-dd').parse('2026-09-04');   // throws FormatException on mismatch
XBTimeUtil.nowMillis;                             // epoch ms
XBTimeUtil.nowTimeStr(format: 'yyyy-MM-dd');      // default 'yyyy-MM-dd HH:mm:ss'
XBTimeUtil.isToday(dt);
XBTimeUtil.formatSecondsToHMS(seconds);           // "MM:SS" ("HH:MM:SS" when hours > 0)
XBTimeUtil.second2HMS(second: s, hUnit: ':', mUnit: ':', sUnit: '', fillZero: true, omitZero: false);
XBTimeUtil.secondMSListLessOneHour(second);       // [minutes, seconds], less than one hour
```

## Collections and models

- `XBSelectModel<T>({isSelected = false, required T model})` — pairing for multi-select lists (use with `actionSheetMulti` or checkboxes).
- `XBUniqueList` extension on `List<T>`: `replaceOrAdd(obj:, equal:)`, `replaceOrAddAll(...)`, `forEachCanBreak(cb)`, `firstWhereOrNull`, `lastWhereOrNull`, `firstOrNull`, `lastOrNull`, `get(index)` (null-safe), `mutableCopy()`.
- `XBStackList` extension: `push(v)`, `pop`, `top`.

## Measure utilities

- `XBTextSizeUtil.textSize(text:, textStyle:, maxWidth:, maxLines:)` / `spanSize(textSpan:, ...)` — measure text before layout.
- `XBImgSizeUtil.getImageSizeFromUrl/Asset/File/Memory(...)` — cached intrinsic image sizes; returns `Size.zero` on failure.

## Screen metrics (global getters)

From `xb_sys_space.dart` — usable anywhere after bootstrap:

`screenW`, `screenH`, `screenSize`, `dpr`, `stateBarH` (sticky max), `naviBarH` (kToolbarHeight), `tabbarH`, `topBarH` (status+nav), `screenHWithoutTopBarH`, `safeAreaBottom` (sticky max — stays valid while the keyboard collapses), `onePixel`.

Global style constants: `lineColor` #E6E6E6, `viewBG` #F1EBEB (page background default), `naviBarBG` white, `naviBarTitle` black.

## Common pitfalls

1. **"XBScaffold ... is not ready" `StateError`** — global APIs used before `XBScaffold` mounts, or navigator key not bound. Fix: use `XBMaterialApp` + `XBScaffold`, or pass `navigatorKey: xbNavigatorKey` (and add `xbRouteObserver` to `navigatorObservers` for page lifecycle).
2. **Page loading never shows** — forgot `@override bool needLoading(BuildContext context) => true;` on the `XBPage`. `showLoading`/`hideLoading` are silently ignored otherwise.
3. **`dialog` with 3+ buttons** — unsupported; use `actionSheet` or `dialogWidget` with custom content.
4. **Stale VM references** — don't store a VM in a field; grab `context.vmOf<T>()` at use time (VMs are recreated by `reset()` and on widget rebuild paths).
5. **`notify()` after dispose is a no-op** but your async callback may still crash on other members — guard with `if (vm.disposed) return;`.
6. **`XBImage` on web** — `File`/`XBFileImage` inputs are unsupported; use URLs, assets or bytes.
7. **Don't listen to global streams in `testWidgets`** — fake-async tests can hang on live streams; wrap in `await tester.runAsync(() async { ... })` and prefer page-state assertions (`find.text`, `canPop`).
8. **`XBCellTitleSwitch` tap handling** — it sets `isNeedBtn: false` by default; the `CupertinoSwitch` receives taps and forwards them to `onTap`. Provide `onTap` to persist the new state; the visual state is controlled by `isOn` (redraw on rebuild).
9. **`XBButton` debounce** — default 500 ms swallows rapid taps; pass `preventMultiTapMilliseconds: 0` for rapid-fire use cases (checkbox-like cells already do this).
10. **Don't import `src/`** — anything not exported by `package:xb_scaffold/xb_scaffold.dart` is private API and may change.
11. **`XBHoveringHeaderList` requires fixed heights** — you must supply `itemHeightForIndexPath` and `headerHeightForSection`; for variable-height content use plain `ListView`.
12. **Theme image fallback only scans declared assets** — new images require `flutter pub get`/rebuild so `AssetManifest` includes them.
