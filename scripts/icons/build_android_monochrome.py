#!/usr/bin/env python3
"""从 Android 自适应图标的前景层派生「单色层」。

用途：安卓 13 起，系统设置里有个「主题图标」开关。用户打开后，系统会按壁纸
取色，把桌面上所有应用的图标统一刷成一套色调。它需要应用额外提供一份只有
轮廓的剪影（monochrome 层）才能这么做 —— 彩色图形系统没法直接刷。

本脚本产出 `assets/app_icon_android_monochrome.png`，由
`flutter_launcher_icons.yaml` 的 `adaptive_icon_monochrome` 消费。

为什么从前景层派生、而不是从母版重新画：
    单色层与前景层在 `ic_launcher.xml` 里共用同一个 inset，两者必须逐像素
    对齐，否则用户开关主题图标时会看到图形「跳」一下。直接从前景层取 alpha，
    位置与形状天然一致，不需要重新推算缩放与平移。

为什么必须去掉辉光：
    深色母版带霓虹辉光滤镜，前景层里只有约 8% 的像素是实心线条，另有约 20%
    是半透明辉光。辉光若一并保留，系统上色后是一团模糊的光斑，不是干净的
    剪影。官方对单色层的要求也是「简洁剪影、不要阴影」。故按透明度阈值把
    辉光滤掉，只留线条本体；阈值以上的像素保留原有 alpha，线条边缘仍有抗锯齿。

用法：
    python scripts/icons/build_android_monochrome.py

依赖：Python 3 与 Pillow。
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'assets' / 'app_icon_android.png'
DEST = REPO / 'assets' / 'app_icon_android_monochrome.png'

# 辉光与线条的分界。前景层里实心线条的 alpha 是 255，辉光分布在 1~191。
# 取 128：低于它的判为辉光丢弃，高于它的保留原值（边缘仍有抗锯齿过渡）。
GLOW_CUTOFF = 128

# 单色层的填充色。系统只读 alpha 通道并自行上色，写白色只是取惯例。
FILL = (255, 255, 255)


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f'找不到前景层源图：{SOURCE}\n'
                         '请先在仓库根目录执行 flutter_launcher_icons '
                         '（本脚本依赖它产出的 assets/app_icon_android.png）。')

    src = Image.open(SOURCE).convert('RGBA')
    alpha = src.getchannel('A')

    kept = sum(1 for v in alpha.getdata() if v >= GLOW_CUTOFF)
    total = src.size[0] * src.size[1]
    print(f'源图 {SOURCE.name} {src.size[0]}x{src.size[1]}')
    print(f'  阈值 {GLOW_CUTOFF}：保留 {kept} 像素（{100.0 * kept / total:.2f}%），'
          f'丢弃辉光 {100.0 * (total - kept) / total:.2f}%')

    # 去辉光：低于阈值的置 0，其余保留原 alpha（线条边缘的柔和过渡得以保留）
    cleaned = alpha.point(lambda v: v if v >= GLOW_CUTOFF else 0)

    out = Image.new('RGBA', src.size, FILL + (255,))
    out.putalpha(cleaned)
    out.save(DEST)

    box = cleaned.point(lambda v: 255 if v > 8 else 0).getbbox()
    print(f'  线条范围 {box}   尺寸 {box[2] - box[0]}x{box[3] - box[1]}')
    print(f'已写出 {DEST.relative_to(REPO)}')


if __name__ == '__main__':
    main()
