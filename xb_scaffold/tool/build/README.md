# xb.build — 通用 Flutter 多平台打包工具

基于 git worktree 隔离构建的通用 Flutter 打包工具，随 `xb_scaffold` 包分发。
适用任何依赖 `xb_scaffold` 的 Flutter 项目（Android / iOS / 鸿蒙）。

## 核心特性

- **worktree 隔离构建**：在临时 git worktree（HEAD 快照）中执行 `flutter build`，
  打包代码与 git HEAD 严格一致，不受工作区未提交改动影响；结束自动清理。
  项目不是 git 仓库或已是 worktree 时自动降级为直接构建。
- **iOS Pods 复用**：隔离 worktree 中自动复用项目已安装的 `ios/Pods`（rsync 复制），
  pod install 从"全量网络下载 10+ 分钟"降到"秒级校验"，失败自动回退全量安装。
- **iOS 签名注入，零工程文件修改**：签名信息不写进 `project.pbxproj`，
  而是在 `xcodebuild archive` 命令行注入（优先级最高），见下方签名说明。
- **三层配置**：内置默认值 < 项目级 `.xb_build_config.json` <
  用户级 `~/.xb_build_config.json`；签名证书等个人配置放用户级文件，不进 git。
- **path 依赖自动软链**：识别 pubspec 中 `../xxx` 类型的 path 依赖，
  在隔离环境中自动创建指向真实源码的软链接。
- **monorepo 子项目支持**：项目根是 git 仓库内子目录时也能正确隔离构建。

## 调用方式

任意依赖 xb_scaffold 的项目根目录中：

```bash
# 直接走 dart 入口（最常用）
dart run xb_scaffold:xb xb.build --platform ios --build-number 100 --build-name 1.2.0

# 执行过 xb.setup 后，可省略前缀（等价全局命令）
xb.build --platform android

# 手动执行 Python 入口（不经过 xb_scaffold 依赖，方便调试）
python3 <xb_scaffold包>/tool/build/xb_build.py --project-dir . --dry-run
```

参数一览：

| 参数 | 说明 |
|---|---|
| `--project-dir <路径>` | 目标 Flutter 项目根（默认当前目录） |
| `--platform android\|ios\|ohos\|auto` | 要构建的平台，默认 `auto`（按目录检测） |
| `--build-number <num>` | 三端通用构建序号：iOS 注入 FLUTTER_BUILD_NUMBER，Android/Ohos 透传 flutter --build-number |
| `--build-name <x.y.z>` | 三端通用版本号：iOS 注入 FLUTTER_BUILD_NAME，Android/Ohos 透传 flutter --build-name |
| `--ohos hap\|app` | 鸿蒙包类型（默认 hap） |
| `--no-worktree` | 关闭隔离，直接构建当前目录 |
| `--no-reuse-pods` | 不复用已有 ios/Pods |
| `--dry-run` | 只打印配置预览与环境检测，不执行构建 |
| `--config <路径>` | 追加一份配置文件 |

## iOS 签名配置（重点）

**背景**：证书/描述文件属于"人 + 机器"属性，不属于项目；若把它们写进工程
文件或项目配置，每个开发者 clone 后都要改工程、且极易误提交。

**做法**：`xcodebuild` 命令行 build setting 优先级高于 `project.pbxproj`，
因此签名完全由配置文件驱动，工程文件零修改、零备份还原。

在用户级配置 `~/.xb_build_config.json` 写入（**不要提交到 git**）：

```json
{
  "ios": {
    "signing": {
      "style": "automatic",
      "team": "YOUR_TEAM_ID",
      "identity": "Apple Distribution",
      "profile": "App Store Profile Name"
    }
  }
}
```

| style | 注入内容 | 适用 |
|---|---|---|
| `automatic` | `CODE_SIGN_STYLE=Automatic` + `DEVELOPMENT_TEAM`（自动创建/更新描述文件，配合 `-allowProvisioningUpdates`） | 团队自动签名，最省事 |
| `manual` | `CODE_SIGN_STYLE=Manual` + `CODE_SIGN_IDENTITY` + `PROVISIONING_PROFILE_SPECIFIER` | 指定证书 + 描述文件的商店包 |
| `none` | 不注入任何签名参数 | 使用工程自带签名配置 |

未填写 `team`/`profile` 时对应参数自动省略。

### 补丁兜底（可选，默认关闭）

极少数情况需要在工程文件中做 build setting 表达不了的调整时，可在项目级
配置声明"本地补丁文件 -> 工程文件"映射，构建前备份覆盖、构建后自动还原：

```json
{
  "ios": {
    "patch_files": {
      "ios/Runner.xcodeproj/project.pbxproj": "scripts/local_ios_patches/project.pbxproj"
    }
  }
}
```

注意：补丁文件是某版本工程文件的快照，工程结构变化后需同步更新；能用签名
注入解决的问题请优先使用注入。

## 完整配置项

参见随包 `build_config.example.json`（含每项注释）。

| 键 | 默认 | 说明 |
|---|---|---|
| `project_name` | pubspec name | 产物命名（apk/归档名） |
| `output_dir` | `~/Desktop/xb_build` | 产物输出目录 |
| `platforms` | `["auto"]` | 平台列表或 auto 检测 |
| `git_worktree` | `true` | 是否使用 worktree 隔离 |
| `ios.scheme` | `Runner` | xcodebuild scheme |
| `ios.workspace` | `ios/Runner.xcworkspace` | workspace 相对路径 |
| `ios.signing.*` | style=none | 见上节 |
| `ios.allow_provisioning_updates` | `true` | 自动签名时是否允许更新描述文件 |
| `ios.reuse_pods` | `true` | 复用已有 ios/Pods |
| `ios.extra_settings` | `[]` | 追加自定义 xcodebuild 设置（如 `ENABLE_BITCODE=NO`） |
| `android.target_platforms` | `null` | 如 `["android-arm64"]`；null=flutter 默认 |
| `android.apk_name` | `<project>.apk` | 产物文件名 |
| `ohos.package_type` | `hap` | `hap` 或 `app` |
| `ohos.flavor` | `""` | 透传 `--flavor`（空则不传） |

## 原理与边界

- 隔离构建要求项目在 git 仓库中；构建前 `git worktree add --detach`，
  构建后 `git worktree remove --force` 并删除临时目录。
- iOS 构建链：`flutter pub get` → `pod install` →（可选补丁）→ `xcodebuild archive`，
  产出 `<project>.xcarchive`；不再需要 `flutter build ios` 预编译。
- 鸿蒙打包要求使用支持 ohos 的 Flutter 定制版工具链；签名在鸿蒙工程内配置。
- iOS 自动签名需要本机钥匙串已装有对应证书，且 xcodebuild 有权访问
  （首次可能弹窗授权）。
