#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成专利 06 的附图（黑白线条风格，宋体）。输出到 figures_06/ 目录。"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "figures_06")
os.makedirs(OUT, exist_ok=True)

SONG = "/System/Library/Fonts/Supplemental/Songti.ttc"
F_TITLE = ImageFont.truetype(SONG, 34, index=1)   # 标题 粗
F_HEAD = ImageFont.truetype(SONG, 26, index=1)    # 组头/强调 粗
F_BODY = ImageFont.truetype(SONG, 24, index=6)    # 正文
F_SMALL = ImageFont.truetype(SONG, 20, index=6)   # 小字
F_MARK = ImageFont.truetype(SONG, 20, index=1)    # 标记 粗

BLACK = (0, 0, 0)
DGRAY = (60, 60, 60)
MGRAY = (120, 120, 120)
LGRAY = (225, 225, 225)
WHITE = (255, 255, 255)


def arrow(d, p1, p2, color=BLACK, width=3, head=16):
    x1, y1 = p1
    x2, y2 = p2
    d.line([p1, p2], fill=color, width=width)
    ang = math.atan2(y2 - y1, x2 - x1)
    a1 = ang + math.radians(150)
    a2 = ang - math.radians(150)
    tri = [(x2, y2),
           (x2 + head * math.cos(a1), y2 + head * math.sin(a1)),
           (x2 + head * math.cos(a2), y2 + head * math.sin(a2))]
    d.polygon(tri, fill=color)


def dashed(d, points, color=BLACK, width=2, dash=10, gap=7):
    """折线虚线。"""
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        dist = math.hypot(x2 - x1, y2 - y1)
        if dist == 0:
            continue
        n = int(dist // (dash + gap)) + 1
        for i in range(n):
            t0 = min(i * (dash + gap) / dist, 1.0)
            t1 = min((i * (dash + gap) + dash) / dist, 1.0)
            d.line([(x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0),
                    (x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1)],
                   fill=color, width=width)


def rbox(d, box, r=14, fill=WHITE, outline=BLACK, width=2):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def diamond(d, cx, cy, hw, hh, fill=WHITE, outline=BLACK, width=3):
    d.polygon([(cx - hw, cy), (cx, cy - hh), (cx + hw, cy), (cx, cy + hh)],
              fill=fill, outline=outline, width=width)


def center(d, text, cx, cy, font, fill=BLACK):
    d.text((cx, cy), text, font=font, fill=fill, anchor="mm")


def text_left(d, text, x, cy, font, fill=BLACK):
    d.text((x, cy), text, font=font, fill=fill, anchor="lm")


def caption(d, W, text):
    center(d, text, W / 2, 40, F_TITLE)


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path)
    print("saved", path, img.size)


# ---------------------------------------------------------------- 图1 方法流程图
def fig1():
    W, H = 900, 1160
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    caption(d, W, "图1  界面源码跨进程定位方法流程图")

    steps = [
        ("步骤 S1 · 101", "应用端响应拾取指令，提取源码位置"),
        ("步骤 S2 · 102", "写入剪贴板兜底，经扩展事件流发布定位请求"),
        ("步骤 S3 · 103", "守护进程扫描端口、特征探测、指纹去重"),
        ("步骤 S4 · 104", "订阅扩展事件流并解析定位请求"),
        ("步骤 S5 · 105", "按 IDE 适配策略唤起 IDE 定位，失败降级重试"),
    ]
    bx1, bx2 = 110, 790
    bh = 130
    gap = 70
    y = 100
    centers = []
    for i, (tag, desc) in enumerate(steps):
        top = y + i * (bh + gap)
        rbox(d, [bx1, top, bx2, top + bh], r=16, fill=WHITE, outline=BLACK, width=3)
        center(d, tag, W / 2, top + 42, F_HEAD)
        center(d, desc, W / 2, top + 90, F_BODY)
        centers.append((W / 2, top, top + bh))
    for i in range(len(steps) - 1):
        _, _, bot = centers[i]
        _, ntop, _ = centers[i + 1]
        arrow(d, (W / 2, bot + 4), (W / 2, ntop - 6), width=3)
    save(img, "fig1.png")


# ---------------------------------------------------------------- 图2 系统架构图
def fig2():
    W, H = 1500, 1060
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    caption(d, W, "图2  界面源码跨进程定位系统架构图")

    # ---- 左侧：设备端 ----
    dx1, dy1, dx2, dy2 = 70, 120, 460, 880
    rbox(d, [dx1, dy1, dx2, dy2], r=24, fill=WHITE, outline=BLACK, width=3)
    center(d, "移动设备 / 桌面端", (dx1 + dx2) / 2, dy1 + 36, F_HEAD)

    # 应用 201
    rbox(d, [110, 200, 420, 320], r=12, fill=WHITE, outline=BLACK, width=4)
    center(d, "运行中应用 201", 265, 244, F_HEAD)
    center(d, "（含应用内调试工具）", 265, 284, F_SMALL)

    # VM Service 202
    rbox(d, [110, 420, 420, 600], r=12, fill=WHITE, outline=BLACK, width=3)
    center(d, "调试虚拟机服务 202", 265, 466, F_HEAD)
    center(d, "扩展事件流", 265, 522, F_BODY)
    center(d, "事件缓冲区", 265, 562, F_BODY)
    arrow(d, (265, 324), (265, 416), width=3)

    # ---- 中间：端口入口 203 ----
    rbox(d, [560, 420, 840, 600], r=12, fill=WHITE, outline=BLACK, width=3)
    center(d, "调试服务端口入口 203", 700, 466, F_MARK)
    text_left(d, "· 调试工具链代理端口", 592, 514, F_SMALL)
    text_left(d, "· 设备端口转发端口", 592, 546, F_SMALL)
    text_left(d, "· 桌面直连端口", 592, 578, F_SMALL)
    arrow(d, (424, 505), (556, 505), width=3)
    center(d, "既有调试链路", 492, 478, F_SMALL)
    
    # ---- 右侧：开发机端 ----
    hx1, hy1, hx2, hy2 = 950, 120, 1460, 880
    rbox(d, [hx1, hy1, hx2, hy2], r=24, fill=WHITE, outline=BLACK, width=3)
    center(d, "开发机端", (hx1 + hx2) / 2, hy1 + 36, F_HEAD)
    
    # 守护进程 204
    rbox(d, [980, 200, 1430, 490], r=12, fill=WHITE, outline=BLACK, width=4)
    center(d, "独立守护进程 204", 1205, 244, F_HEAD)
    subs = [
        (286, "会话发现模块（扫描·探测·指纹去重）"),
        (352, "事件订阅解析模块"),
        (418, "IDE 适配唤起模块"),
    ]
    for sy, stext in subs:
        rbox(d, [1000, sy, 1410, sy + 50], r=8, fill=WHITE, outline=DGRAY, width=2)
        center(d, stext, 1205, sy + 25, F_SMALL)
    arrow(d, (844, 505), (976, 452), width=3)
    center(d, "轮询扫描", 895, 560, F_SMALL)
    center(d, "特征探测", 895, 592, F_SMALL)
    
    # IDE 集合 205
    rbox(d, [980, 580, 1430, 780], r=12, fill=WHITE, outline=BLACK, width=3)
    center(d, "本机 IDE 集合 205", 1205, 626, F_HEAD)
    text_left(d, "命令行协议系（VS Code 系编辑器）", 1015, 680, F_BODY)
    text_left(d, "深链协议系（JetBrains 系 IDE）", 1015, 726, F_BODY)
    arrow(d, (1205, 494), (1205, 576), width=3)
    center(d, "命令行 / 深链唤起", 1340, 536, F_SMALL)
    
    # ---- 剪贴板兜底 206（虚线） ----
    dashed(d, [(265, 884), (265, 966), (1205, 966), (1205, 788)], width=2)
    arrow(d, (1205, 966), (1205, 788), width=2, head=14)
    center(d, "剪贴板兜底通道 206", 735, 940, F_MARK)

    save(img, "fig2.png")


# ---------------------------------------------------------------- 图3 会话自动发现流程
def fig3():
    W, H = 900, 1260
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    caption(d, W, "图3  调试会话自动发现流程示意图")

    bx1, bx2 = 150, 750

    def step_box(top, bh, tag, desc, note=None):
        rbox(d, [bx1, top, bx2, top + bh], r=14, fill=WHITE, outline=BLACK, width=3)
        center(d, tag, W / 2, top + 36, F_HEAD)
        center(d, desc, W / 2, top + 78, F_BODY)
        if note:
            center(d, note, W / 2, top + 112, F_SMALL)
        return top + bh

    # 301
    bot = step_box(110, 110, "301", "扫描本机回环 TCP 监听端口")
    arrow(d, (450, bot + 4), (450, 266), width=3)
    # 302
    bot = step_box(270, 110, "302", "对候选端口发起虚拟机元信息特征探测")
    arrow(d, (450, bot + 4), (450, 386), width=3)

    # 303 判定（菱形）
    diamond(d, 450, 490, 280, 100, width=3)
    center(d, "303", 450, 452, F_HEAD)
    center(d, "响应为调试虚拟机服务？", 450, 500, F_BODY)
    # 否：右侧回到 301
    arrow(d, (734, 490), (830, 490), width=3)
    dashed(d, [(830, 490), (830, 165)], width=2)
    arrow(d, (830, 165), (754, 165), width=3)
    center(d, "否：下一候选端口", 790, 610, F_SMALL)

    # 是 ↓
    arrow(d, (450, 594), (450, 646), width=3)
    center(d, "是", 470, 620, F_SMALL)

    # 304
    bot = step_box(650, 130, "304", "以隔离组标识组合计算实例指纹并去重",
                   note="（指纹已存在：跳过接入）")
    arrow(d, (450, bot + 4), (450, 826), width=3)

    # 305
    bot = step_box(830, 110, "305", "建立长连接并订阅扩展事件流")
    arrow(d, (450, bot + 4), (450, 986), width=3)

    # 306
    bot = step_box(990, 130, "306", "会话断开清理、实例重启后重接入",
                   note="（周期性轮询执行）")

    # 循环：306 → 左侧 → 301
    dashed(d, [(450, bot + 4), (450, 1150), (80, 1150), (80, 165)], width=2)
    arrow(d, (80, 165), (146, 165), width=3)
    center(d, "周期轮询", 80, 700, F_MARK)

    save(img, "fig3.png")


# ---------------------------------------------------------------- 图4 触发与反馈界面
def fig4():
    W, H = 1000, 1120
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    caption(d, W, "图4  定位请求触发与反馈界面示意图")

    # 手机外框 401
    px1, py1, px2, py2 = 70, 100, 610, 1060
    rbox(d, [px1, py1, px2, py2], r=40, fill=WHITE, outline=BLACK, width=4)
    center(d, "应用运行界面 401", (px1 + px2) / 2, py1 + 32, F_SMALL)
    d.line([(px1 + 24, py1 + 58), (px2 - 24, py1 + 58)], fill=MGRAY, width=2)

    # 调试信息面板
    panel = [px1 + 30, py1 + 90, px2 - 30, py1 + 700]
    rbox(d, panel, r=12, fill=WHITE, outline=DGRAY, width=2)
    text_left(d, "调试信息面板", panel[0] + 20, panel[1] + 30, F_SMALL, DGRAY)
    d.line([(panel[0] + 16, panel[1] + 56), (panel[2] - 16, panel[1] + 56)],
           fill=MGRAY, width=1)

    # 文件组头 + 源码位置条目 402
    fy = panel[1] + 80
    text_left(d, "lib/pages/home/item_card.dart", panel[0] + 24, fy, F_SMALL, MGRAY)
    rows = [
        ("line 40", "Row(children: [...])", False),
        ("line 42", "ItemCard(item: entity)", False),
        ("line 55", "XBScaffold(page: this)", True),   # 含触发控件
    ]
    ry = fy + 34
    trig = None
    for rtag, rtext, has_btn in rows:
        rbox(d, [panel[0] + 20, ry, panel[2] - 20, ry + 52], r=8,
             fill=WHITE, outline=MGRAY, width=2)
        text_left(d, rtag, panel[0] + 40, ry + 26, F_SMALL)
        text_left(d, rtext, panel[0] + 140, ry + 26, F_SMALL)
        if has_btn:
            bx, by, br = panel[2] - 52, ry + 26, 16
            d.ellipse([bx - br, by - br, bx + br, by + br],
                      fill=WHITE, outline=BLACK, width=4)
            center(d, "→", bx, by, F_MARK)
            trig = (bx, by, br, ry)
        ry += 66

    # 浮动反馈提示 404（锚定触发控件下方）
    tx1, ty1, tx2, ty2 = px1 + 120, trig[3] + 66, px2 - 60, trig[3] + 196
    rbox(d, [tx1, ty1, tx2, ty2], r=10, fill=WHITE, outline=BLACK, width=3)
    center(d, "已发出定位请求", (tx1 + tx2) / 2, ty1 + 40, F_BODY)
    center(d, "兜底：位置文本已入剪贴板", (tx1 + tx2) / 2, ty1 + 86, F_SMALL)
    # 锚定连线：触发控件 → 提示框
    arrow(d, (trig[0], trig[1] + trig[2] + 4), (trig[0], ty1 - 4), width=2, head=12)

    # ---- 右侧引线标注 ----
    turn_x = 662
    txt_x = 672

    def leader(edge_x, ey, label):
        d.line([(edge_x, ey), (turn_x, ey)], fill=DGRAY, width=2)
        d.ellipse([edge_x - 4, ey - 4, edge_x + 4, ey + 4], fill=DGRAY)
        d.text((txt_x, ey), label, font=F_MARK, fill=BLACK, anchor="lm")

    leader(panel[2] - 20, fy, "源码位置条目 402")
    leader(trig[0] + trig[2], trig[1], "行尾定位触发控件 403")
    leader(tx2, (ty1 + ty2) / 2, "浮动反馈提示 404")

    save(img, "fig4.png")


if __name__ == "__main__":
    fig1()
    fig2()
    fig3()
    fig4()
    print("ALL DONE")
