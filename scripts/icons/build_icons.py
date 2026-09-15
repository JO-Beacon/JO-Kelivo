#!/usr/bin/env python3
"""JO-AIClient 图标派生工具

把 assets/icon_sources/ 下的母版，派生成各平台需要的 PNG，调用
flutter_launcher_icons 产出五个平台的启动器图标与启动画面，最后再打包两处
多尺寸 ICO。ICO 放在最后是因为那个生成器只会写出单一尺寸，必须由本脚本覆盖。

「同一份素材在不同场合怎么用」由本脚本负责：不同产物可以从不同母版取源，
某个用途需要额外处理（例如桌面图标要带底色）也在这里完成 ——
应用图标素材只有浅色、深色两份透明 SVG，其余尺寸与变体都由本脚本派生；
另有一套迷你图形（简化图形），供托盘、网页标签与过小的尺寸档位使用 —— 它
目前是主图形的占位副本，等真正的简化图形到位后替换母版即可，本脚本不用改。

母版不需要事先裁成正方形或手工居中：脚本会量出内容实际范围（含 SVG 向外溢出的
光晕），自动套方形画布、居中并留出余量。同一组母版共用一套变换，保证同组图形
大小与位置完全一致 —— 否则光晕强弱不同会导致量出的范围不同，两版就会差几个百分点。

用法：
    python scripts/icons/build_icons.py             # 派生 + 生成全平台图标与启动画面
    python scripts/icons/build_icons.py --stage raw # 只派生 PNG 与 ICO
    python scripts/icons/build_icons.py --check     # 只体检并报告，不写任何文件

依赖：
    Python 3 与 Pillow；Node 与 @resvg/resvg-js（见同目录 package.json，
    在 scripts/icons 下执行 npm install 即可）；最后一步需要 Flutter SDK。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# ── 可调参数 ────────────────────────────────────────────────────────────────

CANVAS = 1024         # 归一化后的方形画布边长
ALPHA_FLOOR = 8       # 低于此透明度视为不可见（避免把极淡的溢出算进范围）
PROBE_PAD = 320       # 探测光晕范围时向四周临时外扩的像素

# 图形（含向外溢出的光晕）在画布里占的边长比例，其余留白。
#
# 比例归「用途」，不归母版：同一份母版可以按不同比例派生出多份成品，各平台
# 要多大互不牵连，改一个不会带着其他平台一起变。以前比例是挂在母版组上的，
# 于是「让某个平台大一点」只能全局改或硬凑，那是职责挂错了层。
#
# 1.0 是上限：再大就要裁掉光晕，而光晕哪怕接近全透明也必须完整保留。
#
# Android 硬约束（官方文档）：自适应图标与 Android 12+ 启动画面同一规范，
# 原文「与自适应图标一样，前景的三分之一被遮盖」——内容必须装进直径 2/3 的
# 圆，圆外完全不可见（带底 240dp 中 160dp，不带底 288dp 中 192dp，都是 2/3）。
# 故这两处最多 0.667，这里取 0.60 给不同厂商的遮罩形状留余量。
#
# 各平台数值的取法：**桌面图标一律取 0.95**，让图形占底板的比例在各平台一致。
# Windows / iOS / macOS 三者的底板都铺满画布、母版同一份，所以同一个数字在
# 三处得到同样的观感 —— 不需要为平台各算一个系数。
#
# Android 是唯一要单独算的：它的底板被系统裁到画布的 2/3（72dp 视口），
# 而且启动器读配置里的 inset 又把前景往里缩一截。设成 0.899 之后，
# 前景的实际高度 = 108 × 0.899 × (1 - 2×16%) = 66dp，正好用满官方安全区
# （图形不得超过画布中心 66dp 的圆）；落到 72dp 视口上即 91.7%（含辉光），
# 实心线条约 86% —— 这已是它能到的上限，与 Windows 的 87% 只差一个百分点。
RATIO = {
    'win':     0.95,   # Windows 桌面、任务栏、开始菜单、窗口标题栏
    'android': 0.60,   # Android 12+ 启动画面（2/3 是硬顶；桌面图标见下一行）
    'android_icon': 0.899,  # Android 桌面图标（用满 66dp 安全区，见上）
    'ios':     0.95,   # iOS 主屏幕
    'macos':   0.95,   # macOS Dock / Finder（底板另收 PLATE_SHRINK_MACOS）
    'web':     0.95,   # 网页标签，只有 16 像素，要顶满
    'mini':    0.95,   # 迷你图形：托盘、菜单栏、小尺寸档位
    'splash':  0.95,   # 启动画面（iOS 与 Android 11 及以下，系统不裁）
    'about':   0.95,   # 应用内展示（关于页）
}

# 迷你图形用在哪：边长小于等于这个值的档位改用简化图形（tray 母版）。
# 那种尺寸下完整图形的细节挤成一团，而迷你版更顶满、更好认。
# 分界线做成常量——等真正的简化图形到位后，看实际效果再调。
MINI_MAX_SIZE = 16

# ── 底板 ────────────────────────────────────────────────────────────────────
# 资源管理器、开始菜单、快捷方式、主屏幕只读构建期写死的那张图，而壁纸的明暗不
# 受我们控制。透明图形放到反色的桌面上会直接退化成看不见（实测浅色版置于深色
# 桌面，达到可辨对比度的像素占比为 0），所以带底成品必须自带一块不透明的底。
#
# 底板与图形是一对，必须反色：母版 app-icon-light.svg 是深色描边，只能垫浅底；
# app-icon-dark.svg 是浅色描边，只能垫深底。这里按母版的明暗登记两种底色，
# 具体用哪一种是 SOURCE_POLARITY 决定的，不给人自由搭配的机会 ——
# 「黑底 + 深色图形」这类画出来看不见的组合，在结构上就写不出来。
PLATE_COLOR = {
    'dark':  '#000000',   # 深底，配浅色描边的母版
    'light': '#FFFFFF',   # 浅底，配深色描边的母版
}
PLATE_RADIUS_RATIO = 0.225   # 圆角半径占边长的比例
PLATE_SHRINK_MACOS = 0.80    # macOS 图标四周另需留白，内容只占画布八成

# ── 母版登记 ────────────────────────────────────────────────────────────────
# 角色 -> 文件。产物表按优先级回退（靠前的先用）。
# light / dark 是应用图标母版（完整造型，给尺寸充裕的场合：桌面大图、主屏、
# 启动画面等）。tray_light / tray_dark 是迷你母版，为托盘、菜单栏、网页标签
# 这类只有十几到二十几像素的场合**单独绘制**：线条更粗、去掉光晕与细碎图元、
# 简化为可辨认的大块面。两套造型长得不一样是刻意的 —— 完整造型缩到那个尺寸
# 会糊成一团，迷你造型存在的理由就是那时还认得出。
SOURCES = {
    'light': 'assets/icon_sources/app-icon-light.svg',
    'dark': 'assets/icon_sources/app-icon-dark.svg',
    'tray_light': 'assets/icon_sources/app-icon-tray-light.svg',
    'tray_dark': 'assets/icon_sources/app-icon-tray-dark.svg',
}

# 同组母版共用一套归一化变换（深浅两版必须严格对齐）
SOURCE_GROUP = {
    'light': 'app',
    'dark': 'app',
    'tray_light': 'tray',
    'tray_dark': 'tray',
}

# 每份母版是为哪种底色而作的 —— 同时也是这套成品用在浅色还是深色界面。
# 垫底时按它取 PLATE_COLOR 里对应的颜色，所以底板与图形永远反色、配不错。
SOURCE_POLARITY = {
    'light': 'light',
    'dark': 'dark',
    'tray_light': 'light',
    'tray_dark': 'dark',
}

# ── 产物登记 ────────────────────────────────────────────────────────────────

# 托盘 PNG 的边长。面板实际只画十几到二十几像素，128 足以覆盖高分屏。
TRAY_PNG_SIZE = 128

# 每个产物自己声明「用哪份母版、缩多大、带什么底」。字段：
#   roles  源角色优先级（靠前的先用；写 tray_* 即取迷你图形）
#   out    输出路径
#   size   边长
#   ratio  缩放比例，取 RATIO 的键
#   plate  底板形态：none 不带底 / square 直角满幅 / rounded 圆角满幅
#          / macos 圆角且整体收小（macOS 规范要求四周留白）
#   note   体检时打印的说明
#
# 以前一张成品图供好几个平台共用，于是各平台只能将就同一个大小。现在按平台
# 拆开：iOS、网页标签、Android 各拿各的，互不牵连。
PNG_OUTPUTS = [
    # 带底的成品：资源管理器、开始菜单、主屏幕只读构建期写死的这一张，不会
    # 跟随系统明暗切换。透明图形放到反色的桌面上会直接退化成看不见。
    dict(roles=('dark',), out='assets/app_icon.png', size=CANVAS,
         ratio='ios', plate='square', note='iOS 主屏幕'),
    dict(roles=('tray_dark', 'dark'), out='assets/app_icon_web.png', size=CANVAS,
         ratio='web', plate='square', note='网页标签（迷你图形）'),
    dict(roles=('dark',), out='assets/app_icon_macos.png', size=CANVAS,
         ratio='macos', plate='macos', note='macOS Dock / Finder'),
    # Android 自适应图标的前景：系统拿它和纯黑底合成再加遮罩，所以不带底，
    # 且必须收进 2/3 的安全圆（见 RATIO 的注释）。
    dict(roles=('dark',), out='assets/app_icon_android.png', size=CANVAS,
         ratio='android_icon', plate='none', note='Android 自适应前景'),
    # 应用内展示：透明底，随界面明暗各取一份
    dict(roles=('dark',), out='assets/app_icon_dark.png', size=CANVAS,
         ratio='about', plate='none', note='关于页（深色）'),
    dict(roles=('light',), out='assets/app_icon_light.png', size=CANVAS,
         ratio='about', plate='none', note='关于页（浅色）'),
    # 启动画面属于程序内部 → 用透明版；底色已按深浅分两套，图形各配一版。
    # iOS 与 Android 11 及以下原样居中、不裁切；Android 12+ 要收进 2/3。
    dict(roles=('light',), out='assets/start.png', size=256,
         ratio='splash', plate='none', note='启动画面浅（iOS 与 Android 11-）'),
    dict(roles=('dark',), out='assets/start_dark.png', size=256,
         ratio='splash', plate='none', note='启动画面深（iOS 与 Android 11-）'),
    dict(roles=('light',), out='assets/start_android12.png', size=256,
         ratio='android', plate='none', note='启动画面浅（Android 12+）'),
    dict(roles=('dark',), out='assets/start_android12_dark.png', size=256,
         ratio='android', plate='none', note='启动画面深（Android 12+）'),
    # 托盘图形（Windows / Linux）：面板与任务栏的底色可深可浅，一份图形不可能
    # 两头都看得见，所以深浅各出一份，由程序按当前应用主题切换
    # （见 desktop_tray_controller.dart）。
    #
    # 这两份**自带底**，是实测决定的：托盘只显示 16 像素，而一块底色把线条颜色
    # 锁死成「只配一种底」。应用主题与任务栏底色错配时（应用浅色 + 深色任务栏），
    # 无底线条的可辨比例实测 0%（对比度 1.46，等于看不见）。自带底之后两种底色
    # 下都可辨（实测 76%）。代价是图标变成实心方块、与系统其它细线条托盘图标
    # 风格不同 —— 这是有意的取舍。
    #
    # 底板颜色由母版决定（见 SOURCE_POLARITY），浅色母版配白底、深色母版配黑底，
    # 配不错。
    dict(roles=('tray_light', 'light'), out='assets/icon_tray_light.png',
         size=TRAY_PNG_SIZE, ratio='mini', plate='rounded',
         note='Linux 及其他平台托盘（浅色，迷你图形，自带白底）'),
    dict(roles=('tray_dark', 'dark'), out='assets/icon_tray_dark.png',
         size=TRAY_PNG_SIZE, ratio='mini', plate='rounded',
         note='Linux 及其他平台托盘（深色，迷你图形，自带黑底）'),
    # macOS 菜单栏以「模板图」方式加载：系统只取轮廓当遮罩、再按菜单栏颜色填充，
    # 所以**必须不带底** —— 一旦垫了不透明的底，系统会把整块底填成实心方块。
    # 因此只有一份，不参与深浅切换，也不跟应用主题。
    dict(roles=('tray_light', 'light'), out='assets/icon_mac.png', size=180,
         ratio='mini', plate='none', note='macOS 菜单栏（迷你图形，无底模板图）'),
]

# 多尺寸 ICO。字段同上，另加：
#   sizes  内含的尺寸档位
#   mini   可选：小于等于 MINI_MAX_SIZE 的档位改用这一套
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
ICO_OUTPUTS = [
    # 这两份只被 Windows 托盘加载（插件按 LR_LOADFROMFILE 读 .ico），实际只显示
    # 16 像素 → 整体走迷你图形，并自带底（原因见上面 PNG 那一段）。
    dict(roles=('tray_light', 'light'), out='assets/icon_tray_light.ico',
         sizes=ICO_SIZES, ratio='mini', plate='rounded',
         note='Windows 托盘（浅色，迷你图形，自带白底）'),
    dict(roles=('tray_dark', 'dark'), out='assets/icon_tray_dark.ico',
         sizes=ICO_SIZES, ratio='mini', plate='rounded',
         note='Windows 托盘（深色，迷你图形，自带黑底）'),
    # 这一份编进 exe，任务栏、开始菜单、快捷方式都用它 → 带底圆角。
    # 最小的几档换迷你造型：完整造型缩到 16 像素会糊成一团，迷你造型还认得出。
    # 代价是同一个文件里混了两套造型，资源管理器切换视图大小时图形会变 ——
    # 这是有意为之（小尺寸换更清楚的那套），不是缺陷，故不做尺寸间的一致性要求。
    dict(roles=('dark',), out='windows/runner/resources/app_icon.ico',
         sizes=ICO_SIZES, ratio='win', plate='rounded',
         mini=dict(roles=('tray_dark', 'dark'), ratio='mini', plate='rounded'),
         note='Windows 桌面 / 任务栏 / 开始菜单'),
]

WORKSPACE = REPO / 'build' / 'icon_build'

# 启动画面生成器会把这几个文件按它自己的格式整体重写（缩进、空行、行尾），
# 内容往往并无变化。生成后逐份比对：去掉全部空白字符后与仓库版本一致，
# 说明只是格式抖动，就还原成仓库版本，免得这些无信息量的改动混进记录。
SPLASH_FORMAT_NOISE = (
    'ios/Runner/Info.plist',
    'android/app/src/main/res/values/styles.xml',
    'web/index.html',
)


class Fail(Exception):
    """可预期的失败：打印提示后以非零码退出。"""


# ── 母版读取与测量 ──────────────────────────────────────────────────────────

SVG_OPEN = re.compile(r'<svg\b[^>]*>', re.S)


def split_svg(text: str, path: Path) -> tuple[list[float], str]:
    """拆出 viewBox 四值与 svg 内部内容；结构异常时报错。"""
    opened = SVG_OPEN.search(text)
    if not opened or '</svg>' not in text:
        raise Fail(f'{path} 不是可识别的 SVG（找不到 svg 标签）')
    if 'xmlns="http://www.w3.org/2000/svg"' not in opened.group(0):
        raise Fail(f'{path} 缺少 xmlns 声明，无法光栅化')
    view_box = re.search(r'viewBox="([^"]+)"', opened.group(0))
    if not view_box:
        raise Fail(f'{path} 没有 viewBox，无法确定坐标系')
    parts = [float(v) for v in re.split(r'[\s,]+', view_box.group(1).strip())]
    if len(parts) != 4:
        raise Fail(f'{path} 的 viewBox 不是四个数值：{view_box.group(1)}')
    return parts, text[opened.end():text.rindex('</svg>')]


def wrap(inner: str, view_box: str, size: int, transform: str | None = None) -> str:
    """用给定的 viewBox 与尺寸重新包出一个 SVG，可套一层变换。"""
    body = f'<g transform="{transform}">{inner}</g>' if transform else inner
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}"'
        f' width="{size}" height="{size}">{body}</svg>\n'
    )


def render_jobs(jobs: list[dict], node: str) -> None:
    """把任务清单交给 Node 渲染器。"""
    job_file = WORKSPACE / 'jobs.json'
    job_file.parent.mkdir(parents=True, exist_ok=True)
    job_file.write_text(json.dumps(jobs, ensure_ascii=False), encoding='utf-8')

    env = dict(os.environ)
    env['NODE_PATH'] = str(REPO / 'scripts' / 'icons' / 'node_modules')
    result = subprocess.run(
        [node, str(REPO / 'scripts' / 'icons' / 'render_svg.js'), str(job_file)],
        cwd=str(REPO), env=env, capture_output=True, text=True,
    )
    if result.stdout.strip():
        print('    ' + result.stdout.strip())
    for line in result.stderr.strip().splitlines():
        print('    ' + line)
    if result.returncode != 0:
        raise Fail('光栅化失败，详见上面的输出')


def alpha_box(image_path: Path) -> tuple[int, int, int, int]:
    """图里可见内容的包围盒。"""
    from PIL import Image

    with Image.open(image_path) as image:
        alpha = image.convert('RGBA').getchannel('A')
        box = alpha.point(lambda v: 255 if v >= ALPHA_FLOOR else 0).getbbox()
    if not box:
        raise Fail(f'{image_path} 渲染后没有任何可见内容')
    return box


def measure_svg(role: str, source: Path, view_box: list[float], node: str) -> tuple[float, ...]:
    """探测母版里内容的实际范围（母版自身坐标）。

    直接渲染会被画布裁掉溢出的光晕，所以先向四周外扩再渲染，才能量到真实范围。
    """
    vx, vy, vw, vh = view_box
    _, inner = split_svg(source.read_text(encoding='utf-8'), source)
    probe_view = (f'{vx - PROBE_PAD:g} {vy - PROBE_PAD:g} '
                  f'{vw + 2 * PROBE_PAD:g} {vh + 2 * PROBE_PAD:g}')
    probe_size = int(round(max(vw, vh) + 2 * PROBE_PAD))
    probe_svg = WORKSPACE / f'{role}-probe.svg'
    probe_png = WORKSPACE / f'{role}-probe.png'
    probe_svg.parent.mkdir(parents=True, exist_ok=True)
    probe_svg.write_text(wrap(inner, probe_view, probe_size), encoding='utf-8')
    render_jobs([{'svg': str(probe_svg), 'out': str(probe_png), 'width': probe_size}], node)

    # 探测图与 viewBox 单位是 1:1，直接换算回母版绝对坐标
    x0, y0, x1, y1 = alpha_box(probe_png)
    return (vx, vy,
            x0 + vx - PROBE_PAD, y0 + vy - PROBE_PAD,
            x1 + vx - PROBE_PAD, y1 + vy - PROBE_PAD)


# ── 母版归一化 ──────────────────────────────────────────────────────────────

def normalize_svg(source: Path, view_box: list[float], group_box: list[float],
                  scale: float, label: str) -> dict[str, object]:
    """输出方形、居中、留足余量的 SVG。

    label 用来区分同一母版的不同比例：一份母版会按多个用途各归一一份，
    文件名必须带上它，否则后写的会把先写的覆盖掉。
    """
    vx, vy = view_box[0], view_box[1]
    center_x = (group_box[0] + group_box[2]) / 2
    center_y = (group_box[1] + group_box[3]) / 2
    offset_x = CANVAS / 2 - scale * (center_x - vx)
    offset_y = CANVAS / 2 - scale * (center_y - vy)
    transform = (
        f'translate({offset_x:.3f},{offset_y:.3f}) scale({scale:.6f})'
        f' translate({-vx:g},{-vy:g})'
    )
    _, inner = split_svg(source.read_text(encoding='utf-8'), source)
    out = WORKSPACE / f'{source.stem}-normalized-{label}.svg'
    out.write_text(wrap(inner, f'0 0 {CANVAS} {CANVAS}', CANVAS, transform), encoding='utf-8')
    return {'kind': 'svg', 'path': out}


def normalize_raster(source: Path) -> dict[str, object]:
    """位图母版按原样整幅使用。

    位图不参与画布归一化，也不放大：这类母版分辨率固定，放大只会把原图插值糊掉，
    缩小到目标尺寸一次即可。因此位图母版应当是「正方形、内容居中、留白符合预期」
    的成品构图。当前的托盘剪影占位即属此类。
    """
    return {'kind': 'raster', 'path': source}


def compose_plate(master: dict[str, object], plate: str, label: str,
                  polarity: str) -> dict[str, object]:
    """在母版下面垫一块不透明的底，得到可直接使用的成品。

    底铺满画布，图形按归一化后的比例居中。plate 决定底的形态：
    square 直角满幅 / rounded 圆角满幅 / macos 圆角且整体收小 ——
    Windows 与 macOS 的图标自带圆角，Android 与 iOS 由系统去裁，两者各取所需；
    macOS 规范还要求图标四周留白，所以连底一起收小。
    polarity 是这套图形为哪种底色而作，由调用方从 SOURCE_POLARITY 取；
    底的颜色跟着它定 —— 底板与图形必须反色，配错就会看不见。
    label 用来区分中间文件，必须逐形态唯一，否则后写的会把先写的覆盖掉。
    """
    if master['kind'] != 'svg':
        raise Fail('带底成品只能由矢量母版合成')
    if polarity not in PLATE_COLOR:
        raise Fail(f'未知的母版明暗 {polarity}，底板没有对应的颜色')

    shrink = PLATE_SHRINK_MACOS if plate == 'macos' else 1.0
    rounded = plate in ('rounded', 'macos')

    source = master['path']
    _, inner = split_svg(source.read_text(encoding='utf-8'), source)

    radius = CANVAS * PLATE_RADIUS_RATIO if rounded else 0
    background = (f'<rect x="0" y="0" width="{CANVAS}" height="{CANVAS}"'
                  f' rx="{radius:.1f}" fill="{PLATE_COLOR[polarity]}"/>')
    body = background + f'<g>{inner}</g>'
    if shrink != 1.0:
        center = CANVAS / 2
        body = (f'<g transform="translate({center:g},{center:g})'
                f' scale({shrink:g}) translate({-center:g},{-center:g})">{body}</g>')

    out = WORKSPACE / f'{source.stem}-plate-{label}.svg'
    out.write_text(wrap(body, f'0 0 {CANVAS} {CANVAS}', CANVAS), encoding='utf-8')
    return {'kind': 'svg', 'path': out}


# ── 产物写出 ────────────────────────────────────────────────────────────────

def render_frame(master: dict[str, object], size: int, dest: Path, node: str) -> None:
    """渲染成指定边长：矢量母版按尺寸原生渲染，位图母版整幅缩放一次。"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if master['kind'] == 'svg':
        render_jobs([{'svg': str(master['path']), 'out': str(dest), 'width': size}], node)
        return

    from PIL import Image

    with Image.open(master['path']) as opened:
        frame = opened.convert('RGBA').resize((size, size), Image.LANCZOS)
    frame.save(dest)
    frame.close()


def write_png(master: dict[str, object], out: Path, width: int, node: str) -> str:
    render_frame(master, width, out, node)
    return f'{out.relative_to(REPO).as_posix()}  {out.stat().st_size:>8} 字节'


def write_ico(out: Path, sizes: tuple[int, ...], pick_master, node: str) -> str:
    """打包多尺寸 ICO。

    pick_master(size) 给出这一档该用的成品：小档位可以换成另一套图形
    （例如迷你图形），所以同一个文件里可能混着两套图。
    """
    from PIL import Image

    frames: dict[int, Path] = {}
    for size in sizes:
        frame = WORKSPACE / 'staging' / f'{out.stem}-{size}.png'
        render_frame(pick_master(size), size, frame, node)
        frames[size] = frame

    largest = max(sizes)
    base = Image.open(frames[largest]).convert('RGBA')
    extras = [Image.open(frames[s]).convert('RGBA') for s in sorted(sizes) if s != largest]
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        base.save(out, format='ICO', sizes=[(s, s) for s in sizes], append_images=extras)
    finally:
        for image in (base, *extras):
            image.close()
    return (f'{out.relative_to(REPO).as_posix()}  {out.stat().st_size:>8} 字节'
            f'  含 {" / ".join(str(s) for s in sizes)}')


# ── 环境与外部命令 ──────────────────────────────────────────────────────────

def find_node(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get('NODE'):
        return os.environ['NODE']
    found = shutil.which('node')
    if found:
        return found
    raise Fail('找不到 node。请用 --node 指定，或设置 NODE 环境变量')


def check_environment() -> None:
    try:
        import PIL  # noqa: F401
    except ImportError:
        raise Fail('缺少 Pillow。请先安装：python -m pip install Pillow')

    if not (REPO / 'scripts' / 'icons' / 'node_modules' / '@resvg' / 'resvg-js').exists():
        raise Fail(
            '缺少 Node 依赖 @resvg/resvg-js。请先执行：\n'
            f'    cd {REPO / "scripts" / "icons"}  &&  npm install'
        )


def run_flutter(arguments: list[str]) -> int:
    """调用 Flutter 命令。

    Windows 上 flutter 是批处理文件，不能由 CreateProcess 直接启动，
    必须经 cmd.exe 转一层；在 Linux 与 macOS 上直接执行即可。
    """
    executable = shutil.which('flutter')
    if not executable:
        raise Fail('找不到 flutter，请确认 Flutter SDK 已加入 PATH')
    command = [executable, *arguments]
    if os.name == 'nt' and executable.lower().endswith(('.bat', '.cmd')):
        command = [os.environ.get('COMSPEC', 'cmd.exe'), '/c', *command]
    return subprocess.run(command, cwd=str(REPO), text=True).returncode


def restore_format_noise(relative: str) -> bool:
    """若文件相对仓库版本只差空白字符，就还原；返回是否还原。

    只比对空白差异，真有实质改动时会原样留下 —— 不会掩盖生成器的实际输出。
    """
    path = REPO / relative
    if not path.exists():
        return False
    original = subprocess.run(
        ['git', 'show', f'HEAD:{relative}'],
        cwd=str(REPO), capture_output=True).stdout
    if not original:
        return False

    def dense(data: bytes) -> bytes:
        return bytes(byte for byte in data if byte not in b' \t\r\n')

    if dense(original) != dense(path.read_bytes()):
        return False
    path.write_bytes(original)
    return True


# ── 主流程 ──────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description='从 SVG 母版派生全平台图标')
    parser.add_argument('--stage', choices=('raw', 'all'), default='all',
                        help='raw 只派生 PNG 与 ICO；all 再调用 flutter_launcher_icons'
                             ' 与 flutter_native_splash')
    parser.add_argument('--check', action='store_true', help='只体检并报告，不写任何文件')
    parser.add_argument('--node', help='node 可执行文件路径（缺省从 PATH 查找）')
    args = parser.parse_args()

    try:
        node = find_node(args.node)

        if args.check:
            print('〔体检〕不写入任何文件')
            for role, relative in SOURCES.items():
                mark = '有' if (REPO / relative).exists() else '缺'
                print(f'  母版 {role:<6} {mark}  {relative}')
            for spec in PNG_OUTPUTS:
                print(f'  PNG  {spec["out"]:<40} {spec["note"]}')
                print(f'       源 {" > ".join(spec["roles"]):<11} {spec["size"]:>4}px'
                      f'  比例 {RATIO[spec["ratio"]]:.2f}  底 {spec["plate"]}')
            for spec in ICO_OUTPUTS:
                swapped = f'  ≤{MINI_MAX_SIZE}px 换迷你' if 'mini' in spec else ''
                print(f'  ICO  {spec["out"]:<40} {spec["note"]}')
                print(f'       源 {" > ".join(spec["roles"]):<11} {len(spec["sizes"])} 档'
                      f'  比例 {RATIO[spec["ratio"]]:.2f}  底 {spec["plate"]}{swapped}')
            return 0

        check_environment()
        shutil.rmtree(WORKSPACE, ignore_errors=True)
        WORKSPACE.mkdir(parents=True, exist_ok=True)

        print('〔一〕母版归一化')
        # 每项：(角色, 类型, 母版路径, 母版单位下的内容范围)
        entries: list[tuple[str, str, Path, list[float]]] = []
        boxes_by_group: dict[str, list[float]] = {}

        for role, relative in SOURCES.items():
            source = REPO / relative
            if not source.exists():
                print(f'  母版 {role}：未提供（{relative}），相关产物跳过')
                continue
            if source.suffix.lower() == '.svg':
                view_box, _ = split_svg(source.read_text(encoding='utf-8'), source)
                _, _, x0, y0, x1, y1 = measure_svg(role, source, view_box, node)
                kind = 'svg'
            else:
                x0, y0, x1, y1 = alpha_box(source)
                kind = 'raster'
            box = boxes_by_group.setdefault(SOURCE_GROUP[role], [x0, y0, x1, y1])
            box[0], box[1] = min(box[0], x0), min(box[1], y0)
            box[2], box[3] = max(box[2], x1), max(box[3], y1)
            entries.append((role, kind, source, [x0, y0, x1, y1]))

        if not entries:
            raise Fail('assets/icon_sources 下没有任何可用的母版')

        # 同一组必须同类型：矢量走画布归一化，位图按原样使用，
        # 两种尺度体系混在一组里会让同组图形对不齐。
        for group in boxes_by_group:
            kinds = {kind for role, kind, _, _ in entries if SOURCE_GROUP[role] == group}
            if len(kinds) > 1:
                raise Fail(f'组「{group}」混用了 {" 与 ".join(sorted(kinds))} 母版；'
                           '同一组的母版必须同类，否则同组图形无法对齐')

        infos: dict[str, dict[str, object]] = {
            role: {'kind': kind, 'source': source}
            for role, kind, source, _ in entries
        }

        # 归一化成品缓存：同一份母版按不同比例各归一一份，用到才生成。
        # 内容范围（box）按组共用，保证同组（深浅两版）测量一致、图形对齐；
        # 缩放比例按用途给 —— 测量共用、缩放分开，两者不再互相牵连。
        normalized: dict[tuple[str, str], dict[str, object]] = {}

        def master_at(role: str, ratio_key: str) -> dict[str, object]:
            key = (role, ratio_key)
            if key in normalized:
                return normalized[key]
            info = infos[role]
            if info['kind'] != 'svg':
                result = normalize_raster(info['source'])
                print(f'  {role} @{RATIO[ratio_key]:.2f}（位图）：按原样使用，不归一化')
            else:
                box = boxes_by_group[SOURCE_GROUP[role]]
                usable = CANVAS * RATIO[ratio_key]
                scale = min(usable / (box[2] - box[0]), usable / (box[3] - box[1]))
                view_box, _ = split_svg(info['source'].read_text(encoding='utf-8'),
                                        info['source'])
                result = normalize_svg(info['source'], view_box, box, scale,
                                       label=f'{role}-{ratio_key}')
                print(f'  {role} @{RATIO[ratio_key]:.2f}：'
                      f'内容 {box[2] - box[0]:.0f}x{box[3] - box[1]:.0f}，'
                      f'缩放 {scale:.4f}')
            normalized[key] = result
            return result

        plated: dict[tuple[str, str, str], dict[str, object]] = {}

        def master_for(roles: tuple[str, ...], ratio_key: str, plate: str):
            """取最终成品：挑可用的母版 → 按比例归一 → 按形态垫底。"""
            role = next((r for r in roles if r in infos), None)
            if role is None:
                return None
            if plate == 'none':
                return master_at(role, ratio_key)
            key = (role, ratio_key, plate)
            if key not in plated:
                polarity = SOURCE_POLARITY.get(role)
                if polarity is None:
                    raise Fail(f'母版 {role} 没在 SOURCE_POLARITY 里声明明暗，'
                               f'无法决定底板颜色')
                plated[key] = compose_plate(master_at(role, ratio_key), plate,
                                            label=f'{role}-{ratio_key}-{plate}',
                                            polarity=polarity)
            return plated[key]

        print('〔二〕派生成品（归一化与垫底都按用途、按需进行）')

        print('〔三〕派生 PNG')
        for spec in PNG_OUTPUTS:
            master = master_for(spec['roles'], spec['ratio'], spec['plate'])
            if master is None:
                print(f'  {spec["out"]}  跳过（需要母版 '
                      f'{" > ".join(spec["roles"])}，尚未提供）')
                continue
            print(f'  {write_png(master, REPO / spec["out"], spec["size"], node)}')

        if args.stage == 'all':
            print('〔四〕生成各平台启动器图标')
            if run_flutter(['pub', 'run', 'flutter_launcher_icons']) != 0:
                raise Fail('flutter_launcher_icons 执行失败')
        else:
            print('〔三〕跳过 flutter_launcher_icons（--stage raw）')

        # ICO 必须最后打包：上面的生成器会把 Windows 图标写成单一尺寸，
        # 这一节再覆盖成多尺寸版本，确保两处 ICO 都由本脚本负责。
        print('〔五〕打包多尺寸 ICO')
        for spec in ICO_OUTPUTS:
            master = master_for(spec['roles'], spec['ratio'], spec['plate'])
            if master is None:
                print(f'  {spec["out"]}  跳过（需要母版 '
                      f'{" > ".join(spec["roles"])}，尚未提供）')
                continue

            def pick_master(size: int, _spec=spec, _master=master):
                """小档位改用迷你图形，其余档位用完整图形。"""
                mini = _spec.get('mini')
                if mini is not None and size <= MINI_MAX_SIZE:
                    return (master_for(mini['roles'], mini['ratio'], mini['plate'])
                            or _master)
                return _master

            print(f'  {write_ico(REPO / spec["out"], spec["sizes"], pick_master, node)}')

        if args.stage == 'all':
            # 启动画面与启动器图标是两条独立的生成链路，但共用同一批母版：
            # 启动器图标要带底（桌面只读一张死图），启动画面用透明版并由系统
            # 按深浅各取一份 —— 底色与图形都分两套。
            print('〔六〕生成各平台启动画面')
            if run_flutter(['pub', 'run', 'flutter_native_splash:create']) != 0:
                raise Fail('flutter_native_splash 执行失败')
            for relative in SPLASH_FORMAT_NOISE:
                if restore_format_noise(relative):
                    print(f'  已还原纯格式抖动：{relative}')

            print('\n完成。请核对 git status，确认改动符合预期。')
        else:
            print('\n未调用生成器（--stage raw）')
            print('下一步：flutter pub run flutter_launcher_icons'
                  ' && flutter pub run flutter_native_splash:create')
        return 0

    except Fail as error:
        print(f'\n中止：{error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
