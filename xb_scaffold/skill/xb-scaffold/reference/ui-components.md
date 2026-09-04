# XB Scaffold UI Components (styles + parameters)

Appearance conventions shared by most components: separator/line color `lineColor` (#E6E6E6) at `onePixel` width, default background `Colors.white`, accent `colors.primary`, horizontal gap `spaces.gapDef` (17.5) / `spaces.gapLess` (13.5).

## Toast

```dart
toast(String msg, {
  int duration = 3,               // seconds
  double bottom = 150,            // distance from screen bottom
  Color? backgroundColor,         // default: XBScaffold's toastBackgroundColor ?? Colors.black
  double radius = 8,              // corner radius of the bubble
  TextStyle? msgStyle,            // default white text
})
toastWidget(Widget widget, {int duration = 3, double bottom = 150}) // arbitrary content
```

Style: centered horizontally in an overlay, fade in/out, ignores pointers, only one visible at a time (a new toast hides the previous). No context needed.

## Dialogs

```dart
dialog({
  required String title,              // bold-ish (s18/medium), centered
  TextStyle? titleStyle,
  required String msg,                // grey #808080, s15
  TextStyle? msgStyle,
  required List<String> btnTitles,    // exactly 1 or 2 entries
  Color? btnHighLightColor,           // default colors.primary (last/only button)
  Color? btnDefaultColor,             // default black (first button of two)
  double? btnFontSize,                // default s16
  required ValueChanged<int> onSelected,
  double? maxWidth,                   // default side margin spaces.gapLarge
  int priority = 0,                   // XBDialogManager queue priority
})

dialogContent({                       // same shell, arbitrary body widget
  required String title, required Widget content,
  required List<String> btnTitles, required ValueChanged<int> onSelected,
  titleStyle, btnHighLightColor, btnDefaultColor, btnFontSize, maxWidth, priority,
})

dialogWidget(Widget widget, {int priority = 0})  // show ANY widget as a modal dialog
```

Style: white rounded card (radius 10), title on top, body below, 1px line, bottom button row (h=50) split by a 1px vertical line. Two-button layout: cancel-black left, highlight right. Pops automatically after selection. `priority` lets an urgent dialog jump the queue in `XBDialogManager`.

### XBDialogInput (input dialog)

```dart
dialogWidget(XBDialogInput(
  required String title,
  String? subTitle, TextStyle? subTitleStyle,
  String? placeholder, String? initValue,
  List<TextInputFormatter>? inputFormatters,   // e.g. XBDoubleTextInputFormatter()
  String? cancelTitle, String? confirmTitle,   // default 取消 / 确定
  XBValueGetter<bool, String>? onWillDone,     // return false to block confirm
  required ValueChanged<String> onDone,
  double? maxWidth, double? bottomMargin,      // bottom margin default 100
  String? notEmptyTip,                         // empty-input toast, default 请输入内容
  Widget? clearLeftWidget, Widget? clearRightWidget, Widget? unit, // unit suffix view
));
```

Style: white card radius 10, bordered input box (radius 6) with a grey clear (x) button, bottom cancel/confirm row h=50.

## ActionSheet (bottom sheet)

```dart
actionSheet({
  required List<String> titles,
  required ValueChanged<int> onSelected,
  int? selectedIndex,                  // highlighted with colors.primary
  Color? selectedColor,
  String? dismissTitle,                // optional separate cancel button
  Color? dismissTitleColor, double? dismissTitleFontSize, // default black / 14
  VoidCallback? onTapDismiss,
})
```

Style: white sheet, top corners radius 10, option cells h=50 centered text (14) with bottom hairlines, optional grey gap + cancel cell pinned at bottom (respects safe area).

```dart
actionSheetMulti({
  required List<String> titles,
  required ValueChanged<List<int>> onDone,   // sorted selected indexes
  List<int>? selectedIndexes, double topBarHeight = 50,
  VoidCallback? onCancel, Widget? cancelBtn, Widget? doneBtn, Widget? titleWidget,
  Widget? topBarSeparator, double topRadius = 10,
  ActionSheetMultiItemBuilder? itemBuilder,  // custom rows
  IndexedWidgetBuilder? separatorBuilder,
})
actionSheetMultiItem({required int itemCount, required ActionSheetMultiItemBuilder itemBuilder, ...}) // fully custom
actionSheetWidget({required Widget widget, bool isScrollControlled = false,
                   bool isDismissible = true, bool enableDrag = true}) // any bottom sheet
```

Multi default item: title left + radio icon right (checked = blue), h=50; top bar has 取消 / 确定 defaults; list caps at 70% screen height.

## Loading

```dart
// Page-scoped (XBPageVM):
@override bool needLoading(BuildContext context) => true;   // enables overlay
@override bool needInitLoading(BuildContext context) => true; // show on page open
vm.showLoading(msg: '加载中...'); vm.hideLoading();
@override Widget buildLoading(BuildContext context) => myWidget; // custom

// Global (queue-based overlay, works anywhere after bootstrap):
showLoadingGlobal({String? msg, Widget? widget, bool topLeftEnable = true,
                   bool topCenterEnable = false, bool topRightEnable = false,
                   bool contentEnable = false});
hideLoadingGlobal();
bool isShowGoabolLoading;
```

Default style (`XBLoadingWidget`): white rounded card (radius 8) with shadow, 60x60 rotating dotted spinner (black54), optional ellipsized grey message. Precedence: passed `widget` > global `loadingBuilder` > default. `XBLoadingMask(loading:, child:, text:, bgColor:)` overlays a spinner on any subtree; `XBLoading(text:)` respects the global builder.

Which parts of the screen stay touchable during page loading is controlled by `needResponseNavigationBarLeft/Center/RightWhileLoading` and `needResponseContentWhileLoading` (default: only nav-left responsive).

## Buttons

### XBButton — tap wrapper with effects and debounce

```dart
XBButton({
  required Widget child,
  VoidCallback? onTap,
  bool enable = true,
  Color? disableColor,          // overlay when disabled, default white38
  VoidCallback? onTapDisable,
  XBButtonTapEffect effect = XBButtonTapEffect.opacity,
  //   cover   = translucent black layer over child (radius via coverEffectRadius)
  //   opacity = child dims to opacityOnTap (default 0.5)
  //   none    = no effect
  double? opacityOnTap, Color? coverEffectColor /*default black alpha15*/, double? coverEffectRadius,
  bool needTapEffect = true,
  int preventMultiTapMilliseconds = 500,   // built-in debounce
  bool coverTransparentWhileOpacity = false, // keep a transparent hit-area layer
})
```

Always prefer `XBButton` over raw `GestureDetector` — you get the debounce and unified effects for free. Set `preventMultiTapMilliseconds: 0` when every tap must register.

### XBButtonText — small bordered text button

```dart
XBButtonText({
  required String text, TextStyle? style,
  Color? backgroundColor,       // default white
  Color? disableColor,
  double? borderRadius,         // default 5
  Color? borderColor,           // default grey.shade200, width onePixel
  EdgeInsetsGeometry? padding,  // default h: gapDef, v: 5
  VoidCallback? onTap, bool? enable, double? width,
})
```

Default text: fontSize 12, black alpha 150. With `width`, content centers.

### XBDisable

`XBDisable(child:, disable: true, onTapDisable:, disableOpacity: 1)` — wraps any subtree; when disabled taps hit `onTapDisable` and (optionally) dims the child.

## Cells (settings/list rows)

All cells extend `XBCell` (StatelessWidget) and share:

```dart
EdgeInsetsGeometry? margin, padding; VoidCallback? onTap; Color? backgroundColor;
Widget? backgroundWidget; double? contentHeight; BorderRadiusGeometry contentBorderRadius;
bool isShowArrow = false; Color? arrowColor; double? arrowLeftPadding /*5*/; double? arrowSize;
bool isNeedBtn = true;  // false removes the tap wrapper
```

Row layout: `leftWidget | content(+bottomContent) | rightWidget | arrow | bottomWidget`. Wrap in `XBCellGroup` for card + separators.

| Cell | Extra params | Look |
|---|---|---|
| `XBCellTitle` | `title`, `titleStyle`, `titleMaxLines`, `titleOverflow`, `titleRightPadding`, `maxTitleWidth` | left-aligned title, optional right chevron (`isShowArrow: true`) |
| `XBCellTitleSelect` | + `isSelected`, `selectedColor`, `unSelectedColor` | title + right check/radio icon tinted primary |
| `XBCellTitleSwitch` | + `isOn`, `activeColor` | title + right `CupertinoSwitch`; `isNeedBtn` defaults **false**; `onTap` fires on switch change |
| `XBCellTitleImage` | + `img`, `imgSize` (50x50), `imgRadius` | title + right thumbnail |
| `XBCellIconTitle` | + `icon` (path), `iconSize` (15x15), `iconRightPadding` | left icon + title |
| `XBCellIconTitleSelect` / `XBCellIconTitleSwitch` | icon + select/switch extras | combine both |
| `XBCellTitleSubtitle` | + `subtitle`, `subtitleStyle` (grey), `subtitleAlignment` (`XBCellAlignment.right` default / left), `maxSubtitleWidth`, `subtitleMaxLines` | title left, value right |
| `XBCellTitleSubtitlePoint` | + `pointSize` (6), `pointColor` (red), `pointLeftPadding` | subtitle cell with red badge dot on the right |
| `XBCellIconTitleSubtitlePoint` | icon + subtitle + point | all combined |
| `XBCellCenterTitle` | `title`, `titleStyle` | centered text row (used for dialog buttons) |
| `XBCellTopIconBottomTitle` | `icon`, `iconSize`, `title`, `gap` (5) | grid item: icon above centered title |
| `XBCellCustom` | `contentOverride`, `bottomContentOverride`, `leftWidgetOverride`, `rightWidgetOverride`, `arrowWidgetOverride`, `bottomWidgetOverride` | fully custom slots |
| `XBCellArrow` | `color`, `size` | chevron painter only |

### XBCellGroup (card container)

```dart
XBCellGroup({
  required List<Widget> children,
  ValueGetter<Widget>? headerBuilder, double? headerBottomPadding,
  ValueGetter<Widget>? footerBuilder, double? footerTopPadding,
  double? radius,                      // default 6
  double? paddingTop/Bottom/Left/Right, marginTop/Bottom/Left/Right,
  Color? backgroundColor,              // default white
  XBValueGetter<Widget, int>? separatorBuilder,  // default: xbLine()
})
```

Inserts a hairline between children automatically. Typical usage:

```dart
XBCellGroup(
  headerBuilder: () => const Text('账户'),
  children: [
    XBCellTitle(title: '修改密码', isShowArrow: true, onTap: () {}),
    XBCellTitleSubtitle(title: '版本', subtitle: '1.2.0'),
  ],
)
```

## Image

```dart
XBImage(dynamic img, {
  double? width, double? height, BoxFit? fit,
  Widget? placeholderWidget, Widget? errWidget,
  bool isInPackage = false,   // true: asset shipped inside a pub package
  Color? svgColor,            // tint for SVGs
})
```

Accepts: network URL (http…, cached), asset path, `File`, `Uint8List`, `ui.Image`, raw SVG string / data URI. `.svg` paths and bytes auto-render via flutter_svg. Empty/null shows `placeholderWidget` or nothing. Errors show `errWidget` or a grey error box. **Web: no File support.**

## TextField

```dart
XBTextField({
  String? placeholder, String? initValue,          // initValue read only at creation
  TextStyle? style, TextStyle? placeholderStyle,   // hint default #CCCCCC
  TextAlign textAlign = TextAlign.start,
  bool focused = false,                            // autofocus
  VoidCallback? onFocus, loseFocus,
  ValueChanged<String>? onChanged, onSubmitted,
  bool obscureText = false, TextInputType? keyboardType,
  Color? cursorColor,                              // default colors.primary
  int? maxLines, bool autoHeight = false,
  EdgeInsetsGeometry? contentPadding, bool needContentPadding = true,
  List<TextInputFormatter>? inputFormatters,
})
// clear via key: GlobalKey<XBTextFieldState> k; k.currentState?.clear();
```

Borderless (use `XBBG` or `XBBorder`-style containers around it). Formatters: `XBNumberTextInputFormatter` (integers), `XBDoubleTextInputFormatter` (decimals).

## Table

```dart
XBTable({
  required int titleCount,
  required int cellRowCount,
  required XBTableHeaderItemBuilder titleBuilder,  // (BuildContext, int column) -> Widget
  required XBTableCellBuilder cellBuilder,         // (XBTableIndex(row, column)) -> Widget
  List<int>? flexs,                // per-column flex, length must equal titleCount
  double? titleHeight,             // default 50
  bool isCanScroll = true,
})
```

Header is fixed; rows are a `ListView` of `Row`s split by flex.

## Pickers (Cupertino wheel)

```dart
XBTitlePicker({
  required List<String> titles,
  int initIndex = 0,
  ValueChanged<int>? onSelected,
  Widget? selectedBG,               // selection overlay; default: top+bottom hairlines
  TextStyle? norStyle, selectedStyle, // default fontSize 14
  AlignmentGeometry? alignment, EdgeInsetsGeometry? padding,
})   // itemExtent fixed 50

XBTitlePickerMulti({
  required List<List<String>> mulTitles,     // one wheel per column
  required List<int> selecteds,              // must match mulTitles.length
  ValueChanged<XBTitlePickerIndex>? onSelected,
  Widget? selectedBG, norStyle, selectedStyle,
  List<int> flexs = const [1,1,1],           // per-column width flex
  List<AlignmentGeometry>? alignments, List<EdgeInsetsGeometry>? paddings,
})
```

`XBTitlePickerIndex` carries each wheel's selected index. Embed inside your own bottom sheet (often with `actionSheetWidget`).

## Floating widgets

```dart
class MyFloat extends XBFloatWidget {
  @override
  Widget buildContent(Offset position, double contentLeft, bool isAbove, Function hide) {
    return myPanel; // hide() to dismiss
  }
}
XBFloatWidget(child: anchorWidget, type: 0 /*below*/ | 1 /*above*/, tapContentHide: false)
```

Tap the anchor to show an overlay panel (default content width 280) clamped to 5px screen margins; tapping outside dismisses; intercepts system back via `XBLegacyPopScope`. Ready-made contents: `XBFloatMenu`, `XBFloatMenuTitle`, `XBFloatMenuIconTitle`, `XBTip`.

## Lists

### XBHoveringHeaderList — pinned section headers

```dart
XBHoveringHeaderList({
  required List<int> itemCounts,                    // items per section
  required Widget Function(BuildContext, int section) sectionHeaderBuild,
  required double Function(int section) headerHeightForSection,
  required Widget Function(BuildContext, XBSectionIndexPath, double itemHeight) itemBuilder,
  required double Function(XBSectionIndexPath) itemHeightForIndexPath,
})
```

Fixed-height sections/items; the current section header floats above the list. `XBSectionIndexPath(section, item)` identifies a cell.

### XBAdaptiveListView — height-adaptive list

```dart
XBAdaptiveListView.builder / .separated({
  required double maxHeight, double? minHeight,
  required int itemCount, required IndexedWidgetBuilder itemBuilder,
  IndexedWidgetBuilder? separatorBuilder,
  Widget? header, footer,      // fixed above/below the scroll area
  Widget? emptyView,           // shown in the scroll area when itemCount == 0
  EdgeInsetsGeometry? padding, ScrollController? controller, ScrollPhysics? physics,
  bool reverse = false, Duration animationDuration = 200ms,
})
```

`AnimatedSize` shrinks/grows with content between min/max height; only the middle area scrolls.

### XBMaxHeightContainer

`XBMaxHeightContainer(maxHeight:, children:)` — constrained single-scroll column, cheap "list that scrolls only when too tall".

## Decor & misc

- `XBBG(child:, color: white, paddingH: 5, paddingV: 1, borderRadius / defAllRadius: 3, borderWidth:, borderColor:)` — quick bordered/filled container.
- `XBShadowContainer(child:, shadowColor: black12, shadowRadius: 5)` — box-shadow wrapper (child supplies its own background).
- `XBGradientWidget(begin:, end:, beginColor:, endColor:, child:)` — 2-stop `LinearGradient` background.
- `XBFadeWidget(child:, milliseconds: 200, initShow: false, fps: 30, autoShowAnimation: false)` — programmatic fade: `GlobalKey<XBFadeWidgetState>` then `state.show()` / `state.hide(done)`.
- `xbLine({width, color, direction: 0 /*h*/ | 1 /*v*/, startPadding, endPadding})` — hairline.
- `xbSpace(height:) / xbSpaceWidth(w) / xbSpaceHeight(h)` — SizedBox sugar.
- `XBBottomLine(child:, isShow: true, lineWidth:, lineColor:, padding:)` — row with bottom hairline.
- `XBEmptyAppBar()` — zero-size `PreferredSizeWidget` for `Scaffold.appBar`.
- `XBNavigatorBackBtn(onTap:, img:, imgSize:)` — default `Icons.arrow_back` black or themed image.
- `XBAnimationRotate(child:, repeat:, duration:)` — rotate animation wrapper (used by the loading spinner).
- `XBLegacyPopScope(child:, onWillPop: Future<bool> Function()?, canPopWhenOnWillPopIsNull: true)` — legacy `WillPopScope` semantics on modern `PopScope` (return false to block back).
- `XBIosEdgeBackGesture` — custom iOS-style edge swipe-back with indicator; callback type `XBIosEdgeBackCallback`.
- `XBRotatableFullscreen(childBuilder:, controller:, duration: 300ms, curve:, backgroundColor: black, turns: 0.25, onFullscreenChanged:)` — animate any child in/out of fullscreen via `controller.enter()/exit()/toggle()/isFullscreen`.
