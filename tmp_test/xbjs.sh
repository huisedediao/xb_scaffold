#!/bin/zsh
# 用法: tmp_test/xbjs.sh <js文件>   在 Chrome 前台窗口当前标签页执行 JS（不抢焦点）
JSFILE="$1"
osascript <<EOF
set js to read POSIX file "$JSFILE" as «class utf8»
tell application "Google Chrome"
  set r to execute active tab of front window javascript js
end tell
return (r as string)
EOF
