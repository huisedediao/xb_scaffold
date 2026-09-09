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
- 🛠️ **工具集合**：事件总线、定时器等实用工具

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

### 5. 生成 AI 自装指南（可选，推荐）

xb_scaffold 并非主流框架，AI 编程工具默认不了解它的 API。包内内置了一份全英文的 AI Skill（`skill/xb-scaffold/`，含 SKILL.md 和详细到组件参数/样式的 reference 文档）。

由于各家 AI IDE（Qoder、Claude Code、Cursor 等）的 skill/规则目录与格式互不兼容，`xb.skill` 不直接安装到任何特定工具，而是在项目根生成一份**厂商中立的自装指南**：

```bash
dart run xb_scaffold:xb xb.skill
# 已安装 xb 短命令的项目：
xb.skill
```

| 参数 | 说明 |
|---|---|
| （默认） | 在当前目录生成 `xb-scaffold-ai-guide.md` |
| `--out <path>` | 自定义生成位置（如 `docs/xb-scaffold.md`） |
| `--force` | 覆盖已存在的文件，不再询问 |

指南文档包含两部分：

1. **给 AI 的指令**：如何把下方的知识库转换成它当前工具的原生 skill/规则（含常见工具映射表：`.qoder/skills/`、`.claude/skills/`、`.cursor/rules/` 等）；
2. **完整知识库**：用 `<!-- section: ... -->` 标记切分的 SKILL.md 与 4 份 reference 文档全文。

之后告诉你的 AI 一句话即可：

> 读取并执行项目根目录下 `xb-scaffold-ai-guide.md` 中的安装指令。

无论你（或团队成员）使用哪种 AI IDE，它都会自己把知识装成自己认识的样子。

注意：`xb.setup` 会在末尾自动生成该指南，接入即生成，一般无需单独执行。

## 使用 xb.build 打包（新手教程）

> xb.build 是 XB Scaffold 自带的打包命令。照着本文一步步做，不需要理解原理也能把项目打包成安装包。本文假设你已经会用 Flutter 写代码，只是还没打过包。

### 1. 准备工作（每台电脑只需做一次）

**① 检查环境**
- 打 iOS 包：必须用 **Mac**，并装好 Xcode（App Store 搜 "Xcode" 安装）
- 打 Android / 鸿蒙包：Mac 或 Windows 都可以
- Flutter 已安装：打开终端输入 `flutter --version`，能显示版本号即可
- 项目依赖了 XB Scaffold：打开项目 `pubspec.yaml`，`dependencies` 里有 `xb_scaffold: ^版本号`（版本太老会没有 xb.build，见第 5 节排错）

**② 打开终端，进入项目目录**
- Mac 打开终端：按 `⌘ + 空格`，输入"终端"回车
- 进入项目：输入 `cd `（cd 后有一个空格），**把项目文件夹拖进终端窗口**，回车。例如显示成：
  ```bash
  cd /Users/你的用户名/你的项目
  ```

**③ 下载项目依赖**
```bash
flutter pub get
```
看到 `Got dependencies!` 即成功。

**④ 配置 iOS 签名（只打 Android / 鸿蒙的人跳过这步）**

苹果要求每个 App 都必须有"签名"，签名绑定一个 **团队编号（Team ID）**。xb.build 需要你把编号填进配置文件，只需做一次。

找到你的团队编号，三选一：
- **方式 A（最省事）**：直接问负责打包/上架的同事要。公司项目一般只有一个固定编号，例如 `273JDFD2Q8`
- **方式 B（从证书看）**：打开 Mac 的"钥匙串访问"应用 → 搜索 `Apple Development` 或 `iPhone Distribution` → 双击证书 → **名称中括号里的字母数字**（例如 `(273JDFD2Q8)`）就是 Team ID
- **方式 C（从老工程抄）**：找一个"能在 Xcode 里正常打包"的 iOS 工程，用文本编辑器打开 `ios/Runner.xcodeproj/project.pbxproj`，搜索 `DEVELOPMENT_TEAM`，等号后的内容就是

拿到编号后，在终端执行下面命令（**把 `XXXXXXXXXX` 换成你的编号**，整体复制执行即可，没有报错就是成功）：

```bash
cat > ~/.xb_build_config.json << 'EOF'
{
  "ios": {
    "signing": {
      "style": "automatic",
      "team": "XXXXXXXXXX"
    }
  }
}
EOF
```

说明：`style: automatic` 表示让 Xcode 自动管理证书和描述文件，绝大多数人用它就够了，不需要手动碰证书。

**⑤ 确认 Xcode 已登录 Apple 账号（打 iOS 需要）**

打开 Xcode → 菜单 Settings…（旧版叫 Preferences…）→ `Accounts`，能看到 Apple ID 即可。公司电脑一般已配好，不确定就打开看一眼。

### 2. 开始打包

**① 先提交代码（⚠️ 很重要，否则会打旧包）**

xb.build 是在代码仓库"最近一次提交"的基础上打包的（保证打出来的包和代码一致）。**如果你刚改了代码但还没 `git commit`，打出来的包不含你的新改动**。两种选择：

- **正式打包**：先提交，再打包
  ```bash
  git add .
  git commit -m "准备打包"
  ```
- **快速自测**：不想提交，就想用当前代码打一个试试 → 在打包命令末尾加 `--no-worktree`（见下）

**② 执行打包**

打 iPhone 包：

```bash
dart run xb_scaffold:xb xb.build --platform ios --build-name 1.0.0 --build-number 1
```

只有两个参数需要理解：
- `--build-name 1.0.0`：**版本号**，给用户看的，通常 `数字.数字.数字`，按你们团队的版本计划填
- `--build-number 1`：**打包序号**，每次打包都要比上一次大（苹果硬性要求），不知道当前是多少就先填 `1`，之后每次 +1

打安卓包（`--build-name` / `--build-number` 与 iOS 通用，可带可不带；不传则用工程配置的版本）：

```bash
dart run xb_scaffold:xb xb.build --platform android
```

打鸿蒙包（同样支持版本参数；默认生成 `.hap`，想要 `.app` 加 `--ohos app`）：

```bash
dart run xb_scaffold:xb xb.build --platform ohos
```

**懒人选项**：什么都不带，自动检测项目能打哪些平台，全部打一遍：

```bash
dart run xb_scaffold:xb xb.build
```

（如果装过 xb.setup 短命令，把上面的 `dart run xb_scaffold:xb xb.build` 换成 `xb.build` 即可）

**③ 等待完成**

- 首次打包比较慢（iOS 可能 20~40 分钟：要下载依赖 + 全量编译），之后会快很多
- 中途不要关终端
- 看到这行字就是成功：
  ```
  全部平台构建完成，产物目录: /Users/你的用户名/Desktop/xb_build
  ```

### 3. 打包完成，去哪里拿安装包？

所有产物都在 **桌面上的 `xb_build` 文件夹**（即 `~/Desktop/xb_build`）：

| 平台 | 产物文件 | 说明 |
| --- | --- | --- |
| iOS | `项目名.xcarchive` | Xcode 归档包。装真机 / TestFlight / 上架还需用 Xcode 再导出一次（可让负责上架的同事操作） |
| Android | `项目名.apk` | 可直接发给别人安装，或上传各应用市场 |
| 鸿蒙 | `项目名.hap` / `项目名.app` | 安装到鸿蒙设备，或上传华为应用市场 |

### 4. 打包前建议先试跑（可选但推荐）

第一次打包前，先做一次"只检查不动手"：

```bash
dart run xb_scaffold:xb xb.build --dry-run
```

它会检查电脑环境、git 状态、签名配置是否齐全并打印出来，有问题可以提前发现，不用等 40 分钟。

### 5. 常见问题

| 现象 | 原因 | 解决办法 |
| --- | --- | --- |
| 提示 `xb.build` 不是有效命令 | 当前依赖的 xb_scaffold 版本还没有 xb.build | 升级 pubspec 里的 xb_scaffold 到含 xb.build 的版本，重新 `flutter pub get` |
| 签名时报 `No profiles ... were found` / 找不到 team | Team ID 填错，或这台 Mac 的 Xcode 没登录对应 Apple 账号 | 重新核对第 1 步 ④ 的编号；确认 Xcode 已登录（第 1 步 ⑤） |
| 签名时报 `An App ID with identifier 'com.xxx' is not available` | bundle id（`com.xxx.xxx`）被别人注册过了 | 用 Xcode 打开 iOS 工程 → Signing & Capabilities → 把 Bundle Identifier 改成没被占用的（如 `com.你的公司.你的项目`），提交后重新打包 |
| 打出来的包没有我最新改的代码 | 未提交的改动不会进包 | 先 `git commit` 再打包，或加 `--no-worktree` 快速自测 |
| 下载依赖时网络报错 | 网络波动 | 直接重跑打包命令（有缓存，重试通常能过） |
| 看到看不懂的报错 | — | 把终端完整输出复制给同事 / 在 XB Scaffold 仓库提 issue |

### 6. 进阶命令速查

| 命令 | 作用 |
| --- | --- |
| `... xb.build --dry-run` | 只检查环境与配置，不打包 |
| `... xb.build --no-worktree` | 不用 git 已提交代码，直接用当前代码打包（快速自测） |
| `... xb.build --open` | 打包完成后自动打开产物文件夹 |
| `... xb.build --project-dir /别的/项目路径` | 在任意目录给其他项目打包 |
| `... xb.build --platform ios android` | 同时打多个平台 |


## 快速开始

### 1. 初始化应用

```dart
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  initXBErrorHandler(
    // 可选：上报到你的监控系统
    reporter: (error, stack) {
      debugPrint('Captured error: $error');
    },
  );
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

`initXBErrorHandler` 建议在 `runApp` 前调用一次，用于统一接管异常捕获和上报。

参数说明（与源码一致）：

- `reporter`：自定义异常上报回调，签名是 `FutureOr<void> Function(Object error, StackTrace? stackTrace)`
- `errorWidgetBuilder`：自定义页面构建异常时的兜底 Widget
- `dumpFlutterErrorToConsole`：是否打印 Flutter 框架异常到控制台，默认 `true`
- `enableErrorWidget`：是否启用页面构建异常兜底 UI，默认 `true`
- `enablePlatformDispatcherError`：是否启用 root isolate 未捕获异常兜底，默认 `true`
- `enableIsolateError`：是否监听 isolate 异常，默认 `false`

更完整的初始化示例：

```dart
void main() {
  initXBErrorHandler(
    reporter: (error, stack) async {
      // 例如：上报到 Sentry / Firebase Crashlytics / 自建日志平台
      debugPrint('report error => $error');
      if (stack != null) {
        debugPrint('stack => $stack');
      }
    },
    errorWidgetBuilder: (context, details, routeName) {
      return Material(
        child: Center(
          child: Text('页面异常：${routeName ?? 'unknown'}'),
        ),
      );
    },
    dumpFlutterErrorToConsole: true,
    enableErrorWidget: true,
    enablePlatformDispatcherError: true,
    enableIsolateError: false,
  );

  runApp(const MyApp());
}
```

注意：

- `initXBErrorHandler` 内部有防重复初始化，重复调用只有第一次生效
- 如果你要自定义异常页面，确保 `errorWidgetBuilder` 返回的 Widget 不再抛异常
- 生产环境建议保留 `reporter` 并接入你的监控平台

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
    // todo
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

### 2. 状态管理

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
