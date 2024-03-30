<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/guides/libraries/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-library-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/developing-packages).
-->

基于provider封装的脚手架，集成路由、主题、dialog、toast、actionSheet等常用控件，集成分组头部悬浮的ListView

## 引入
```
flutter pub add xb_scaffold
```

## 初始化
```
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      navigatorObservers: [xbRouteObserver],
      home: const XBScaffold(
          imgPrefixs: ["assets/images/default/", "assets/images/custom/"],
          child: MyHomePage(title: 'Flutter Demo Home Page')),
    );
  }
}
```

## 使用

### 主题切换
```
/// 这里的序号，对应initXBScaffold传入的图片路径的序号
XBThemeVM().changeTheme(1);
```

### XBVM
```
继承自ChangeNotifier

用于页面状态的管理

构造时需传入其管理的页面的context，用于在vm中处理业务
```

### XBWidget
```
基于provider和XBVM封装的widget，简化provider的使用

抽象类，重写buildWidget进行UI的编写


示例：

class XBWidgetTest extends XBWidget<XBWidgetTestVM> {
  const XBWidgetTest({super.key});

  @override
  XBWidgetTestVM generateVM(BuildContext context) {
    return XBWidgetTestVM(context: context);
  }

  @override
  Widget buildWidget(XBWidgetTestVM vm, BuildContext context) {
    return Container();
  }
}

class XBWidgetTestVM extends XBVM<XBWidgetTest> {
  XBWidgetTestVM({required super.context});
}
```

### XBVMLessWidget
```
继承自XBWidget，使用XBVM作为默认vm

不需要自己写vm，适合不需要处理业务逻辑只需要UI的情况
```

### XBPage
```
抽象类，继承自XBWidget

封装了navigationBar（可隐藏）的页面，可定制标题、返回按钮、右上角按钮、
背景颜色、navigationBar背景颜色等等

提供是否屏幕方向改变后重新build、是否启动安卓物理返回、是否需要输入框跟随键盘移动、是否启动iOS侧滑返回等功能选择


示例：

class XBPageTest extends XBPage<XBPageTestVM> {
  const XBPageTest({super.key});

  @override
  XBPageTestVM generateVM(BuildContext context) {
    return XBPageTestVM(context: context);
  }

  @override
  Widget buildPage(XBPageTestVM vm, BuildContext context) {
    return Container();
  }
}

class XBPageTestVM extends XBVM<XBPageTest> {
  XBPageTestVM({required super.context});
}
```

### 路由
```
/// push到新页面
push

/// 用新页面替换当前页
replace

/// 回到上一页
pop

/// 回到根页面
popToRoot

/// 回到第一个指定类型的页面
popUtilType

/// 回到指定页面
popUtilWidget

```

### ListView分组头部悬浮

```
XBHoveringHeaderList

实现ListView分组头部悬浮，支持混搭多种header、item、separator，支持indexPath跳转

使用参考demo
```

### 拓展主题中没有的内容

```
使用extension向对应的类中添加即可。


例如，要添加颜色：

extension AppThemeColor on XBThemeColor {
  Color get orange => Colors.orange;
}
```

