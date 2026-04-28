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
  xb_scaffold: ^1.0.2
```

然后运行：

```bash
flutter pub get
```

## 在其他工程使用 CLI

如果你希望在业务工程里直接输入 `xb.page xb_test_generate_widget lib/src/`、`xb.parsemodel lib/model/user_model.dart`（而不是每次输入 `dart run xb_scaffold:xb ...`），推荐直接使用 `xb.setup` 一键安装命令工具。

### 1. 在业务工程添加依赖

在业务工程的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  xb_scaffold: ^1.0.2
```

然后执行：

```bash
flutter pub get
```

### 2. 执行 `xb.setup`（推荐）

`xb.setup` 用于一键初始化 CLI 短命令环境，适合首次接入时执行一次。

执行命令：

```bash
dart run xb_scaffold:xb xb.setup
```

该命令会自动执行以下操作：

1. 在当前项目根目录生成 `Makefile`
2. 自动执行 `make install-cli`
3. 处理 PATH：
   - macOS：向 `~/.zshrc` 追加 `export PATH="$HOME/.local/bin:$PATH"`（如不存在）
   - Windows：提示你手动把 `%USERPROFILE%\.local\bin` 加入环境变量
4. 自动执行 `xb.extension`（默认目录 `lib/`）
5. 自动执行 `xb.updateimg`（默认图片目录 `./assets/images`）

注意：`xb.setup` 无法直接刷新你“当前已打开”的终端会话。  
执行完成后，请在当前终端手动运行：

```bash
source ~/.zshrc
hash -r
```

### 3. 使用示例

```bash
# 打印模板到终端（方便复制）
xb.page xb_test_generate_widget

# 推荐：传「文件名 + 目录」直接生成两个文件
xb.page xb_test_generate_widget lib/src/
# => lib/src/xb_test_generate_widget.dart
# => lib/src/xb_test_generate_widget_vm.dart

# 也支持传完整文件路径（同样会额外生成 *_vm.dart）
xb.page xb_test_generate_widget lib/src/xb_test_generate_widget.dart

# 其他命令
xb.widget UserCard lib/widgets/user_card.dart

# 生成主题扩展目录和模板文件
xb.extension
xb.extension lib/public/

# 根据图片目录更新 app_theme_image.dart（默认 ./assets/images）
xb.updateimg
xb.updateimg ./assets/images

# 解析模型文件，生成 fromJson / toJson 代码片段（输出到终端）
xb.parsemodel lib/model/user_model.dart

# 根据 JSON 字符串生成模型代码（输出到终端或文件）
xb.newmodel add_device_video_manage_unnormal_model '{"deviceId":"1","deviceName":"A","accessStoreName":"S","code":"0","msg":"ok"}'
xb.newmodel add_device_video_manage_unnormal_model lib/model/
xb.newmodel add_device_video_manage_unnormal_model lib/model/ '{"deviceId":"1","deviceName":"A"}'
xb.newmodel add_device_video_manage_unnormal_model lib/model/add_device_video_manage_unnormal_model.dart '{"deviceId":"1"}'
```

`xb.page` 的生成规则：

- 第一个参数是文件名（推荐 snake_case）
- 自动将文件名转为类名（PascalCase），例如 `xb_test_generate_widget` -> `XbTestGenerateWidget`
- 生成页面文件和 VM 文件两个文件
- 两个文件顶部会互相 `import`

`xb.extension` 的生成规则：

- 不传路径时默认使用命令运行目录下的 `lib/`
- 输入目录路径（例如 `lib/public/`）
- 自动创建目录 `xb_scaffold_extension`
- 在该目录生成以下文件：
- `app_theme_color.dart`
- `app_theme_font_size.dart`
- `app_theme_font_weights.dart`
- `app_theme_image.dart`
- `app_theme_space.dart`

`xb.updateimg` 的更新规则：

- 自动查找 `app_theme_image.dart`（优先 `lib/public/xb_scaffold_extension/app_theme_image.dart`）
- 默认图片目录：`./assets/images`
- 支持自定义图片目录：`xb.updateimg <image_dir>`
- 递归扫描图片目录（忽略 `.DS_Store`）
- 对 `app_theme_image.dart` 增量追加：
- `String get xxx => imgPath('relative/path');`
- 若出现同名文件（仅扩展名不同），会自动加后缀区分：
- 例如 `ic_add_device_hint.png` / `ic_add_device_hint.svg`
- 会生成 `ic_add_device_hint_png` / `ic_add_device_hint_svg`

`xb.parsemodel` 的规则：

- 用法：`xb.parsemodel <dart_model_file_path>`
- 读取指定 Dart 模型文件，按类定义解析字段
- 在终端输出每个类对应的 `fromJson` / `toJson` 代码片段
- 非空字段会自动追加默认值：
- `String -> ""`
- `int -> 0`
- `double -> 0.0`
- `bool -> false`
- `List -> []`
- `List<基础类型>` 生成 `xbParseList<T>(...)`
- `List<对象类型>` 生成 `xbParseList(..., factory: Type.fromJson)`
- 对象类型字段生成 `xbParse(..., factory: Type.fromJson)`

`xb.parsemodel` 示例：

输入文件（`lib/model/user_model.dart`）：

```dart
class UserModel {
  String name;
  int age;
  List<Tag>? tags;
}

class Tag {
  String? id;
}
```

`xb.newmodel` 的规则：

- 用法：`xb.newmodel <file_name> [out_path] <json_string>`
- `file_name` 用于生成类名（自动转换为首字母大写驼峰）
- `json_string` 必须是 JSON 对象（顶层必须是 `{}`）
- 不传 `out_path` 时，模型代码输出到终端
- 传 `out_path` 时：
- 若是目录路径：输出到 `<out_path>/<file_name>.dart`
- 若是文件路径：直接输出到该文件（自动补 `.dart`）
- 生成内容包括：
- `import 'package:xb_scaffold/xb_scaffold.dart';`
- 可空字段声明
- 构造函数
- `fromJson`（使用 `xbParse` / `xbParseList`）
- `toJson`

`xb.newmodel` 示例：

执行命令：

```bash
xb.newmodel add_device_video_manage_unnormal_model '{"deviceId":"1","deviceName":"A","accessStoreName":"S","code":"0","msg":"ok"}'
```

输出示例（节选）：

```dart
import 'package:xb_scaffold/xb_scaffold.dart';

class AddDeviceVideoManageUnnormalModel {
  String? deviceId;
  String? deviceName;
  String? accessStoreName;
  String? code;
  String? msg;

  AddDeviceVideoManageUnnormalModel({
    this.deviceId,
    this.deviceName,
    this.accessStoreName,
    this.code,
    this.msg,
  });

  AddDeviceVideoManageUnnormalModel.fromJson(Map<String, dynamic> json) {
    deviceId = xbParse<String>(json['deviceId']);
    deviceName = xbParse<String>(json['deviceName']);
    accessStoreName = xbParse<String>(json['accessStoreName']);
    code = xbParse<String>(json['code']);
    msg = xbParse<String>(json['msg']);
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> retMap = {};
    retMap['deviceId'] = deviceId;
    retMap['deviceName'] = deviceName;
    retMap['accessStoreName'] = accessStoreName;
    retMap['code'] = code;
    retMap['msg'] = msg;
    return retMap;
  }
}
```

执行命令：

```bash
xb.parsemodel lib/model/user_model.dart
```

输出示例（节选）：

```dart
----------------------------UserModel----------------------------

UserModel.fromJson(Map<String, dynamic> json) {
    name = xbParse<String>(json['name']) ?? "";
    age = xbParse<int>(json['age']) ?? 0;
    tags = xbParseList(json['tags'], factory: Tag.fromJson);
}

Map<String, dynamic> toJson() {
    final Map<String, dynamic> retMap = {};
    retMap['name'] = name;
    retMap['age'] = age;
    if (tags != null) {
        retMap['tags'] = tags!.map((v) => v.toJson()).toList();
    }
    return retMap;
}
```

### 4. 不安装也能用（备用方式）

如果你不想安装本地命令，仍可直接执行：

```bash
dart run xb_scaffold:xb xb.setup
dart run xb_scaffold:xb xb.page xb_test_generate_widget
dart run xb_scaffold:xb xb.page xb_test_generate_widget lib/src/
dart run xb_scaffold:xb xb.extension
dart run xb_scaffold:xb xb.extension lib/public/
dart run xb_scaffold:xb xb.updateimg
dart run xb_scaffold:xb xb.updateimg ./assets/images
dart run xb_scaffold:xb xb.parsemodel lib/model/user_model.dart
dart run xb_scaffold:xb xb.newmodel add_device_video_manage_unnormal_model '{"deviceId":"1"}'
dart run xb_scaffold:xb xb.newmodel add_device_video_manage_unnormal_model lib/model/ '{"deviceId":"1"}'
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
    return XBMaterialApp(
      title: 'XB Scaffold Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
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

如果你使用的是 `GetMaterialApp` 或 `CupertinoApp`，请显式绑定：

```dart
navigatorKey: xbNavigatorKey
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
  String setTitle(BuildContext context) => "首页";

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
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
  List<Widget>? actions(BuildContext context) {
    final vm = vmOf(context);
    return [
      IconButton(
        icon: Icon(Icons.settings),
        onPressed: vm.openSettings,
      ),
    ];
  }

  // 页面配置（可选）
  @override
  bool needSafeArea(BuildContext context) => true;

  @override
  bool needAdaptKeyboard(BuildContext context) => true;
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
    toast(message);
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
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
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
  Widget buildWidget(BuildContext context) {
    return Container(
      child: Text('简单组件'),
    );
  }
}
```

## 核心功能

### VM 访问方式

XB Scaffold 提供了多种访问 VM 的方式：

#### 1. 在 build 中直接拿 VM

```dart
@override
Widget buildPage(BuildContext context) {
  final vm = vmOf(context);
  return Text('计数: ${vm.counter}');
}
```

#### 2. 使用 XBWidget 的方法

```dart
Widget _buildCounter(BuildContext context) {
  final vm = context.vmOf<HomePageVM>(); // 不监听变化
  final vmWatch = context.vmWatch<HomePageVM>(); // 监听变化
  return ElevatedButton(
    onPressed: vm.increment,
    child: Text('计数: ${vmWatch.counter}'),
  );
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

架构边界（重要）：
- 本框架路由能力仅适用于单 `Navigator` 场景
- 如果项目存在多 `Navigator`，或者使用三方路由（例如 `go_router`），请不要使用框架内路由能力
- 在上述场景中，`xb_route.dart` 中的所有方法都不适用

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
popUntilType(HomePage);

// 检查顶部页面类型
if (topIsType(HomePage)) {
  // 当前顶部是 HomePage
}
```

### 主题管理

```dart
// 切换主题（索引对应初始化时的 themeConfigs）
XBThemeVM().changeTheme(1);

// 获取当前主题
final theme = XBThemeVM().theme;

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
dialog(
  title: '提示',
  msg: '确定要删除吗？',
  btnTitles: ['取消', '确定'],
  onSelected: (index) {
    if (index == 1) {
      // 确认操作
    }
  },
);

// 显示输入对话框
dialogWidget(
  XBDialogInput(
    title: '输入',
    placeholder: '请输入内容',
    onDone: (text) {
      print('输入的内容: $text');
    },
  ),
);

// 显示 ActionSheet
actionSheet(
  titles: ['拍照', '从相册选择'],
  onSelected: (index) {
    if (index == 0) {
      // 拍照操作
    } else {
      // 选择照片操作
    }
  },
  dismissTitle: '取消',
);

// 显示 Toast
toast('操作成功');
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
bool needLoading(BuildContext context) => true;

@override
bool needInitLoading(BuildContext context) => true; // 页面初始化时显示 Loading
```

### 网络请求

```dart
// 配置网络请求
XBDioConfig.init(
  baseUrl: 'https://api.example.com',
  connectTimeout: 5, // 秒
  receiveTimeout: 3, // 秒
);

// GET 请求
final users = await XBHttp.get<List<dynamic>>('/users');

// POST 请求
final createResp = await XBHttp.post<Map<String, dynamic>>(
  '/users',
  bodyParams: {'name': 'John', 'age': 30},
);

// 在 VM 中使用
class UserListVM extends XBPageVM<UserListPage> {
  List<User> users = [];

  Future<void> loadUsers() async {
    showLoading();
    try {
      final response = await XBHttp.get<List<dynamic>>('/users');
      users = response.map((json) => User.fromJson(json)).toList();
      notify();
    } catch (e) {
      toast('加载失败: $e');
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
final preventMultiTask = XBPreventMultiTask(intervalMilliseconds: 1000);

preventMultiTask.execute(
  () {
    submitData();
  },
  onError: () {
    toast('请勿重复点击');
  },
);
```

#### 等待任务

```dart
final waitTask = XBWaitTask();

final result = await waitTask.execute<dynamic>(
  task: () async {
    await Future.wait([
      loadUserData(),
      loadConfigData(),
      loadNotifications(),
    ]);
    return true;
  },
  param: null,
  milliseconds: 5000,
);

if (result == XBWaitTask.timeout) {
  print('任务超时');
} else {
  print('所有任务完成');
}
```

## 高级功能

### 悬浮头部列表

```dart
XBHoveringHeaderList(
  itemCounts: sections.map((e) => e.items.length).toList(),
  sectionHeaderBuild: (context, section) {
    return Container(
      height: 40,
      color: Colors.grey[200],
      child: Text('分组 $section'),
    );
  },
  headerHeightForSection: (section) => 40,
  itemBuilder: (context, indexPath, itemHeight) {
    return ListTile(
      title: Text('项目 ${indexPath.item}'),
    );
  },
  itemHeightForIndexPath: (indexPath) => 56,
)
```

### 自定义组件

#### 按钮组件

```dart
XBButtonText(
  text: '点击按钮',
  onTap: () {
    print('按钮被点击');
  },
  backgroundColor: Colors.blue,
  style: TextStyle(color: Colors.white),
  borderRadius: 8,
  enable: true, // 是否可点击
)
```

#### 图片组件

```dart
XBImage(
  'https://example.com/image.jpg',
  width: 100,
  height: 100,
  placeholderWidget: CircularProgressIndicator(),
  errWidget: Icon(Icons.error),
  fit: BoxFit.cover,
)
```

### 页面配置选项

```dart
class MyPage extends XBPage<MyPageVM> {
  // 是否需要安全区域
  @override
  bool needSafeArea(BuildContext context) => true;

  // 是否需要适配键盘
  @override
  bool needAdaptKeyboard(BuildContext context) => true;

  // 是否启用 Android 物理返回键
  @override
  bool onAndroidPhysicalBack(BuildContext context) => true;

  // 是否启用 iOS 侧滑返回
  @override
  bool needIosGestureBack(BuildContext context) => true;

  // 屏幕方向改变时是否重新构建
  @override
  bool needRebuildWhileOrientationChanged(BuildContext context) => false;

  // 主题改变时是否重新构建
  @override
  bool needRebuildWhileAppThemeChanged(BuildContext context) => true;

  // 页面背景色
  @override
  Color? backgroundColor(BuildContext context) => Colors.white;

  // 导航栏背景色
  @override
  Color? navigationBarBGColor(BuildContext context) => Colors.blue;

  // 导航栏标题颜色
  @override
  Color? navigationBarTitleColor(BuildContext context) => Colors.white;
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
      toast('网络请求失败: $e');
      rethrow;
    }
  }
}

// 使用
await ApiService.safeRequest(() => XBHttp.get('/api/data'));
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

### Q: 为什么在 `testWidgets` 里使用 `xbRouteStackStream.listen` 会卡住？

A: 在 Flutter 的 `testWidgets`（fake async）环境中，直接监听全局路由流可能导致测试进程不退出。  
建议把监听/取消放到 `tester.runAsync` 中执行：

```dart
testWidgets('route stream test', (tester) async {
  await tester.pumpWidget(const MyApp());

  await tester.runAsync(() async {
    final sub = xbRouteStackStream.listen((event) {
      // assert / collect event
    });
    await sub.cancel();
  });
});
```

如果只是做路由 API 覆盖测试，优先通过页面状态断言（如 `find.text`、`canPop`）验证，避免不必要的全局流监听。

## 更新日志

查看 [CHANGELOG.md](CHANGELOG.md) 了解详细的版本更新信息。

## 许可证

本项目基于 MIT 许可证开源。查看 [LICENSE](LICENSE) 文件了解更多信息。

## 贡献

欢迎提交 Issue 和 Pull Request 来帮助改进这个项目。

## 支持

如果这个项目对您有帮助，请给它一个 ⭐️！
