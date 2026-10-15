import re
src = open('bin/ide_gui.dart', encoding='utf-8').read()
m = re.search(r"String guiHtml", src)
start = src.index("'''", m.end()) + 3
end = src.index("''';", start)
html = src[start:end]
sm = re.search(r"<script>([\s\S]*?)</script>", html)
js = sm.group(1) if sm else ''
open('/tmp/gui_check.js', 'w', encoding='utf-8').write(js)
print('script chars:', len(js))
