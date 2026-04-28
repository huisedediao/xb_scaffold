#!/usr/bin/env bash

python3 <<'PY'
from pathlib import Path
import re

ROOT = Path.cwd()

METHODS = [
    "buildPage", "buildWidget",
    "needPageContentAdaptTabbar",
    "needSafeArea",
    "onAndroidPhysicalBack",
    "needRebuildWhileOrientationChanged",
    "needRebuildWhileAppThemeChanged",
    "needAdaptKeyboard",
    "needHideAppbar",
    "needImmersiveAppbar",
    "needRemovePadding",
    "needIosGestureBack",
    "needResponseNavigationBarLeftWhileLoading",
    "needResponseNavigationBarCenterWhileLoading",
    "needResponseNavigationBarRightWhileLoading",
    "needResponseContentWhileLoading",
    "needInitLoading",
    "needLoading",
    "needEndEditingWhileTouch",
    "notifyNeedAfterPushAnimation",
    "statusBarStyle",
    "backgroundWidget",
    "backgroundColor",
    "tabbarHeight",
    "navigationBarBGColor",
    "navigationBarTitleColor",
    "navigationBarTitleSize",
    "navigationBarTitleFontWeight",
    "setTitle",
    "pushAnimationMilliseconds",
    "longPressThresholdMilliseconds",
    "leadingWidth",
    "buildTitle",
    "leading",
    "drawer",
    "endDrawer",
    "buildLoading",
    "buildAppBar",
    "actions"
]

method_group = "|".join(METHODS)

# 方法定义匹配：保留返回值类型
define_pattern = re.compile(
    rf'((?:\b\w+\s+)?)({method_group})\s*\(([^)]*)\)\s*\{{',
    re.DOTALL
)

# super 调用
super_call_pattern = re.compile(
    rf'super\.({method_group})\s*\(\s*[^,\n()]+?\s*,\s*context\s*\)'
)

changed_files = []

for file in ROOT.rglob("*.dart"):
    if any(part in {
        ".dart_tool",
        "build",
        ".git",
        ".idea",
        ".vscode",
        "ios/Pods",
    } for part in file.parts):
        continue

    text = file.read_text(encoding="utf-8")
    original = text

    def replace_define(match):
        return_type = match.group(1)
        method_name = match.group(2)

        # 避免重复插入
        after = text[match.end():match.end() + 200]
        if "final vm = vmOf(context);" in after:
            return f"{return_type}{method_name}(BuildContext context) {{"

        return (
            f"{return_type}{method_name}(BuildContext context) {{\n"
            f"    final vm = vmOf(context);"
        )

    def replace_super_call(match):
        method_name = match.group(1)
        return f"super.{method_name}(context)"

    text = define_pattern.sub(replace_define, text)
    text = super_call_pattern.sub(replace_super_call, text)

    if text != original:
        file.write_text(text, encoding="utf-8")
        changed_files.append(str(file.relative_to(ROOT)))

print("处理完成。")

if changed_files:
    print("已修改文件：")
    for f in changed_files:
        print(" -", f)
else:
    print("没有发现需要修改的文件。")
PY