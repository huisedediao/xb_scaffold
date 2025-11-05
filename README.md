# XB Scaffold

基于 Provider 封装的 Flutter 脚手架，集成路由、主题、dialog、toast、actionSheet 等常用控件，提供完整的 MVVM 架构解决方案。

[![pub package](https://img.shields.io/pub/v/xb_scaffold.svg)](https://pub.dev/packages/xb_scaffold)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 特性

- 🏗️ **完整的 MVVM 架构**：基于 Provider 的状态管理
- 🎨 **主题系统**：支持多主题切换和自定义主题
- 🧭 **路由管理**：简化的路由操作和生命周期管理
- 📱 **丰富的 UI 组件**：内置常用组件和工具类
- 🔄 **生命周期管理**：完整的页面和组件生命周期
- 🌐 **跨平台支持**：支持 iOS、Android、Web、Desktop
- 📋 **悬浮列表**：支持分组头部悬浮的 ListView
- 🛠️ **工具集合**：网络请求、事件总线、定时器等实用工具

## 安装

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  xb_scaffold: ^0.1.42
```

然后运行：

```bash
flutter pub get
```

## 快速开始

### 1. 初始化应用

```dart
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XB Scaffold Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // 添加路由观察者
      navigatorObservers: [xbNavigatorObserver, xbRrouteObserver],
      home: XBScaffold(
        // 配置主题
        themeConfigs: [
          XBThemeConfig(
            primaryColor: Colors.blue,
            imgPrefix: "assets/images/theme1/",
          ),
          XBThemeConfig(
            primaryColor: Colors.red,
            imgPrefix: "assets/images/theme2/",
          ),
        ],
        // 自定义 Loading 样式（可选）
        loadingBuilder: (context, msg) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                if (msg != null) ...[
                  SizedBox(height: 16),
                  Text(msg),
                ],
              ],
            ),
          );
        },
        // Toast 背景颜色（可选）
        toastBackgroundColor: Colors.black87,
        child: const HomePage(),
      ),
    );
  }
}
```

### 2. 创建页面

#### 使用 XBPage（推荐用于页面）

```dart
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class HomePage extends XBPage<HomePageVM> {
  const HomePage({super.key});

  @override
  HomePageVM generateVM(BuildContext context) {
    return HomePageVM(context: context);
  }

  @override
  String setTitle(HomePageVM vm) => "首页";

  @override
  Widget buildPage(HomePageVM vm, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Text('计数器: ${vm.counter}'),
          SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: vm.increment,
                child: Text('增加'),
              ),
              ElevatedButton(
                onPressed: vm.decrement,
                child: Text('减少'),
              ),
            ],
          ),
          SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => vm.showToast('Hello XB Scaffold!'),
            child: Text('显示 Toast'),
          ),
        ],
      ),
    );
  }

  // 自定义 AppBar（可选）
  @override
  List<Widget>? actions(HomePageVM vm) {
    return [
      IconButton(
        icon: Icon(Icons.settings),
        onPressed: vm.openSettings,
      ),
    ];
  }

  // 页面配置（可选）
  @override
  bool needSafeArea(HomePageVM vm) => true;

  @override
  bool needAdaptKeyboard(HomePageVM vm) => true;
}

class HomePageVM extends XBPageVM<HomePage> {
  HomePageVM({required super.context});

  int _counter = 0;
  int get counter => _counter;

  void increment() {
    _counter++;
    notify(); // 通知 UI 更新
  }

  void decrement() {
    _counter--;
    notify();
  }

  void showToast(String message) {
    xbToast(message);
  }

  void openSettings() {
    push(const SettingsPage());
  }
}
```

#### 使用 XBWidget（用于组件）

```dart
class CounterWidget extends XBWidget<CounterWidgetVM> {
  const CounterWidget({super.key});

  @override
  CounterWidgetVM generateVM(BuildContext context) {
    return CounterWidgetVM(context: context);
  }

  @override
  Widget buildWidget(CounterWidgetVM vm, BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          Text('计数: ${vm.count}'),
          ElevatedButton(
            onPressed: vm.increment,
            child: Text('点击'),
          ),
        ],
      ),
    );
  }
}

class CounterWidgetVM extends XBVM<CounterWidget> {
  CounterWidgetVM({required super.context});

  int _count = 0;
  int get count => _count;

  void increment() {
    _count++;
    notify();
  }
}
```

#### 使用 XBVMLessWidget（无需自定义 VM）

```dart
class SimpleWidget extends XBVMLessWidget {
  const SimpleWidget({super.key});

  @override
  Widget buildWidget(XBVM vm, BuildContext context) {
    return Container(
      child: Text('简单组件'),
    );
  }
}
```

## 核心功能

### VM 访问方式

XB Scaffold 提供了多种访问 VM 的方式：

#### 1. 传统方式（通过参数）

```dart
@override
Widget buildPage(HomePageVM vm, BuildContext context) {
  return Text('计数: ${vm.counter}');
}
```

#### 2. 使用 XBWidget 的方法

```dart
Widget _buildCounter(BuildContext context) {
  final vm = vmOf(context); // 不监听变化
  final vmWatch = vmWatchOf(context); // 监听变化
  return Text('计数: ${vm.counter}');
}
```

#### 3. 使用 BuildContext 扩展（推荐）

```dart
class CounterDisplay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // 监听变化，会触发 rebuild
    final vm = context.vmWatch<HomePageVM>();
    return Text('计数: ${vm.counter}');
  }
}

class CounterButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // 不监听变化，不会触发 rebuild
    final vm = context.vmOf<HomePageVM>();
    return ElevatedButton(
      onPressed: vm.increment,
      child: Text('增加'),
    );
  }
}
```

#### 4. 安全访问

```dart
Widget build(BuildContext context) {
  final vm = context.vmOfOrNull<HomePageVM>();
  if (vm == null) {
    return Text('VM 不存在');
  }
  return Text('计数: ${vm.counter}');
}
```

### 路由管理

```dart
// 跳转到新页面
push(const DetailPage());

// 带参数跳转
push(DetailPage(id: 123));

// 替换当前页面
replace(const NewPage());

// 返回上一页
pop();

// 返回并传递结果
pop('result');

// 返回到根页面
popToRoot();

// 返回到指定类型的页面
popUtilType<HomePage>();

// 返回到指定页面实例
popUtilWidget(homePage);

// 检查顶部页面类型
if (topIsType<HomePage>()) {
  // 当前顶部是 HomePage
}
```

### 主题管理

```dart
// 切换主题（索引对应初始化时的 themeConfigs）
XBThemeVM().changeTheme(1);

// 获取当前主题
final theme = XBThemeVM().currentTheme;

// 在组件中使用主题颜色
Container(
  color: colors.primary, // 使用主题色
  child: Text('主题文本'),
)

// 扩展主题颜色
extension CustomColors on XBThemeColor {
  Color get customBlue => Color(0xFF2196F3);
  Color get customGreen => Color(0xFF4CAF50);
}
```

### Dialog 和弹窗

```dart
// 显示确认对话框
xbDialog(
  title: '提示',
  msg: '确定要删除吗？',
  onConfirm: () {
    // 确认操作
  },
);

// 显示输入对话框
xbDialogInput(
  title: '输入',
  hint: '请输入内容',
  onConfirm: (text) {
    print('输入的内容: $text');
  },
);

// 显示 ActionSheet
xbActionSheet(
  actions: [
    XBActionSheetAction(
      title: '拍照',
      onTap: () {
        // 拍照操作
      },
    ),
    XBActionSheetAction(
      title: '从相册选择',
      onTap: () {
        // 选择照片操作
      },
    ),
  ],
);

// 显示 Toast
xbToast('操作成功');
```

### Loading 管理

```dart
class MyPageVM extends XBPageVM<MyPage> {
  // 显示 Loading
  void loadData() async {
    showLoading(msg: '加载中...');
    try {
      // 执行异步操作
      await Future.delayed(Duration(seconds: 2));
    } finally {
      hideLoading();
    }
  }
}

// 页面级 Loading 配置
@override
bool needLoading(MyPageVM vm) => true;

@override
bool needInitLoading(MyPageVM vm) => true; // 页面初始化时显示 Loading
```

### 网络请求

```dart
// 配置网络请求
XBHttp.instance.init(
  baseUrl: 'https://api.example.com',
  connectTimeout: 5000,
  receiveTimeout: 3000,
);

// GET 请求
final response = await XBHttp.instance.get('/users');

// POST 请求
final response = await XBHttp.instance.post(
  '/users',
  data: {'name': 'John', 'age': 30},
);

// 在 VM 中使用
class UserListVM extends XBPageVM<UserListPage> {
  List<User> users = [];

  Future<void> loadUsers() async {
    showLoading();
    try {
      final response = await XBHttp.instance.get('/users');
      users = (response.data as List)
          .map((json) => User.fromJson(json))
          .toList();
      notify();
    } catch (e) {
      xbToast('加载失败: $e');
    } finally {
      hideLoading();
    }
  }
}
```

### 事件总线

```dart
// 定义事件
class UserLoginEvent {
  final String username;
  UserLoginEvent(this.username);
}

// 在 VM 中监听事件
class HomePageVM extends XBPageVM<HomePage> {
  @override
  void didCreated() {
    super.didCreated();
    // 监听用户登录事件
    listen<UserLoginEvent>((event) {
      print('用户 ${event.username} 已登录');
      // 处理登录后的逻辑
    });
  }
}

// 发送事件
XBEventBus.fire(UserLoginEvent('john_doe'));
```

### 工具类

#### 定时器

```dart
final timer = XBTimer();

// 延时执行
timer.once(
  duration: Duration(seconds: 2),
  onTick: () {
    print('2秒后执行');
  },
);

// 重复执行
timer.repeat(
  duration: Duration(seconds: 1),
  onTick: () {
    print('每秒执行一次');
  },
);

// 取消定时器
timer.cancel();
```

#### 防重复点击

```dart
XBPreventMultiTask.run(
  key: 'submit_button',
  task: () async {
    // 提交操作
    await submitData();
  },
  onError: () {
    xbToast('请勿重复点击');
  },
);
```

#### 等待任务

```dart
final waitTask = XBWaitTask();

// 等待多个异步任务完成
waitTask.wait([
  loadUserData(),
  loadConfigData(),
  loadNotifications(),
]).then((_) {
  print('所有任务完成');
});
```

## 高级功能

### 悬浮头部列表

```dart
XBHoveringHeaderList(
  itemCount: items.length,
  headerBuilder: (context, section) {
    return Container(
      height: 40,
      color: Colors.grey[200],
      child: Text('分组 $section'),
    );
  },
  itemBuilder: (context, indexPath) {
    return ListTile(
      title: Text('项目 ${indexPath.item}'),
    );
  },
  sectionCount: sections.length,
  itemCountInSection: (section) => sections[section].items.length,
)
```

### 自定义组件

#### 按钮组件

```dart
XBButton(
  text: '点击按钮',
  onTap: () {
    print('按钮被点击');
  },
  backgroundColor: Colors.blue,
  textColor: Colors.white,
  borderRadius: 8,
  disable: false, // 是否禁用
)
```

#### 图片组件

```dart
XBImage(
  imageUrl: 'https://example.com/image.jpg',
  width: 100,
  height: 100,
  placeholder: CircularProgressIndicator(),
  errorWidget: Icon(Icons.error),
)
```

### 页面配置选项

```dart
class MyPage extends XBPage<MyPageVM> {
  // 是否需要安全区域
  @override
  bool needSafeArea(MyPageVM vm) => true;

  // 是否需要适配键盘
  @override
  bool needAdaptKeyboard(MyPageVM vm) => true;

  // 是否启用 Android 物理返回键
  @override
  bool onAndroidPhysicalBack(MyPageVM vm) => true;

  // 是否启用 iOS 侧滑返回
  @override
  bool needIosGestureBack(MyPageVM vm) => true;

  // 屏幕方向改变时是否重新构建
  @override
  bool needRebuildWhileOrientationChanged(MyPageVM vm) => false;

  // 主题改变时是否重新构建
  @override
  bool needRebuildWhileAppThemeChanged(MyPageVM vm) => true;

  // 页面背景色
  @override
  Color? backgroundColor(MyPageVM vm) => Colors.white;

  // 导航栏背景色
  @override
  Color? navigationBarBGColor(MyPageVM vm) => Colors.blue;

  // 导航栏标题颜色
  @override
  Color? navigationBarTitleColor(MyPageVM vm) => Colors.white;
}
```

## 最佳实践

### 1. VM 生命周期管理

```dart
class MyPageVM extends XBPageVM<MyPage> {
  StreamSubscription? _subscription;

  @override
  void didCreated() {
    super.didCreated();
    // 页面创建时的初始化操作
    _initData();
  }

  @override
  void widgetDidBuilt() {
    super.widgetDidBuilt();
    // 页面构建完成后的操作
    _startListening();
  }

  void _startListening() {
    _subscription = someStream.listen((data) {
      // 处理数据
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
```

### 2. 错误处理

```dart
class ApiService {
  static Future<T> safeRequest<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (e) {
      xbToast('网络请求失败: $e');
      rethrow;
    }
  }
}

// 使用
await ApiService.safeRequest(() => XBHttp.instance.get('/api/data'));
```

### 3. 状态管理

```dart
class UserVM extends XBVM<UserWidget> {
  UserState _state = UserState.loading;
  UserState get state => _state;

  User? _user;
  User? get user => _user;

  void loadUser() async {
    _state = UserState.loading;
    notify();

    try {
      _user = await userRepository.getUser();
      _state = UserState.success;
    } catch (e) {
      _state = UserState.error;
    }
    notify();
  }
}

enum UserState { loading, success, error }
```

## 常见问题

### Q: 如何在子组件中访问父页面的 VM？

A: 使用 BuildContext 扩展：

```dart
class ChildWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final parentVM = context.vmOf<ParentPageVM>();
    return Text(parentVM.someData);
  }
}
```

### Q: 如何处理页面间的数据传递？

A: 可以通过构造函数、路由参数或事件总线：

```dart
// 方式1: 构造函数
push(DetailPage(userId: 123));

// 方式2: 事件总线
XBEventBus.fire(DataUpdateEvent(data));

// 方式3: 返回结果
final result = await push(SelectPage());
```

### Q: 如何自定义主题？

A: 使用扩展：

```dart
extension MyThemeColors on XBThemeColor {
  Color get customPrimary => Color(0xFF1976D2);
  Color get customAccent => Color(0xFFFF4081);
}

// 使用
Container(color: colors.customPrimary)
```

## 更新日志

查看 [CHANGELOG.md](CHANGELOG.md) 了解详细的版本更新信息。

## 许可证

本项目基于 MIT 许可证开源。查看 [LICENSE](LICENSE) 文件了解更多信息。

## 贡献

欢迎提交 Issue 和 Pull Request 来帮助改进这个项目。

## 支持

如果这个项目对您有帮助，请给它一个 ⭐️！

