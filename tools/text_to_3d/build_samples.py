#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 App 里的六个样例 GLB —— 纯程序化建模，零下载 / 零花费 / 零 GPU。

三代演进（都是为了「亲眼看过再交付」）
------------------------------------
1. Shap-E text300M @ CPU：融化状团块，所谓「狗」头尾不分 → 已废弃。
2. 基础几何体硬拼：能辨认，但球与圆柱相贯处是硬折线，没有毛绒质感 → 已废弃。
3. 现在：SDF smooth-union 连续曲面（头/身/腿/耳/尾数学上平滑过渡）
   + 表面短绒几何层 + 绒面噪声毛色 + glTF sheen 织物材质 + 高精度五官。

    python tools/text_to_3d/build_samples.py
    python tools/text_to_3d/build_samples.py --out /some/dir --only dog --res 64
"""
from __future__ import annotations

import argparse
import io
import json
import os
import struct

import numpy as np
import trimesh
from trimesh.transformations import rotation_matrix

from fuzzy_sdf import SDFShape

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "samples")

# 样例版本：App 端缓存文件名带此 rev，服务端换了模型后新 APK 不会读到旧缓存
SAMPLE_REV = 4

# ------------------------------------------------------------------ 通用五官
BLACK = "#2B221E"
EYE_WHITE = "#FCF8F0"
GLINT = "#FFFFFF"


def _align_z(n):
    """把局部 +Z 轴转到表面法线 n 的 4x4 旋转（眼片要顺着脸的曲率贴）。"""
    z = np.array([0.0, 0.0, 1.0])
    c = float(np.clip(np.dot(z, n), -1.0, 1.0))
    v = np.cross(z, n)
    lv = float(np.linalg.norm(v))
    if lv < 1e-8:
        return rotation_matrix(0.0, [0, 1, 0]) if c > 0 \
            else rotation_matrix(np.pi, [1, 0, 0])
    return rotation_matrix(float(np.arccos(c)), v / lv)


def _embedded_nose(s, *, x, y, radii, color, embed=0.70, exclude=0.10):
    """鼻头同样按真实曲面向里嵌，别让侧面轮廓鼓出一个黑球。"""
    hit = s.surface_hit(x, y)
    if hit is None:
        return
    P, N = hit
    R = _align_z(N)
    s.ellipsoid_extra(P - N * (radii[2] * embed), radii, color,
                      rot=R, exclude_radius=exclude)


def _eyes(s, *, x, y, white_r, pupil_r, iris_color,
          pupil_color=BLACK, glint=True, socket_color=None,
          embed=0.62, exclude=0.145):
    """**嵌入式**卡通眼：沿融合曲面的真实表面贴一枚光滑圆眼片。

    旧版把「眼白球 + 虹膜球 + 瞳孔球 + 高光球」沿 +Z 一层层往外叠，
    球心还按椭球公式手算、正好落在脸表面上，结果 3/4 视角里就是两颗
    越来越小的球挂在脸外 —— 用户一眼看出的「眼珠子在外面」。

    现在：
    - 用 surface_hit(x, y) 问真实 SDF，拿到表面点 P 与外法线 N；
    - 眼白球心沿 N 往里埋 embed*rz，只露一个浅圆冠，且整枚眼片按 N 旋转，
      在脸侧也顺着曲率而不是一律朝正前方；
    - 虹膜 / 瞳孔 / 高光改成**薄圆片**，贴着眼白冠面，不再叠成球链；
    - 可选一圈淡色眼窝暗边，强化「嵌进毛里」的观感。
    """
    for sgn in (-1, 1):
        hit = s.surface_hit(sgn * x, y)
        if hit is None:  # 理论上不会发生；保底不让整个模型崩掉
            continue
        P, N = hit
        # 眼片朝向比表面法线更偏正前方：玩偶眼睛是朝前贴的扁片，严格沿
        # 法线倾斜会让远侧那只眼在 3/4 视角侧贴到头部轮廓上、露出一条白边。
        Ne = 0.55 * N + 0.45 * np.array([0.0, 0.0, 1.0])
        Ne /= float(np.linalg.norm(Ne))
        R = _align_z(Ne)
        rz = float(white_r[2])
        crown = rz * (1.0 - embed)         # 眼白露出脸表面的高度

        if socket_color:
            # 略大、埋得更深，只露出一圈窄边当作眼眶
            s.ellipsoid_extra(
                P - N * (rz * 0.84),
                (white_r[0] * 1.15, white_r[1] * 1.15, rz),
                socket_color, rot=R, exclude_radius=exclude * 1.15)

        C = P - N * (rz * embed)          # 眼白球心：大部分埋在脸里
        s.ellipsoid_extra(C, white_r, EYE_WHITE, rot=R,
                          exclude_radius=exclude)

        # 虹膜 / 瞳孔 / 高光的位移全部**相对表面 P**，而不是相对眼白球心：
        # 否则调 embed 时这几层会跟着往里陷或往外鼓，又变回一串球。
        I = P + N * (crown * 0.82)
        s.ellipsoid_extra(I, (pupil_r[0], pupil_r[1], 0.006),
                          iris_color, rot=R)
        if pupil_color != iris_color:
            s.ellipsoid_extra(I + N * 0.004,
                              (pupil_r[0] * 0.44, pupil_r[1] * 0.86, 0.004),
                              pupil_color, rot=R)
        if glint:
            side = np.cross(N, np.array([0.0, 1.0, 0.0]))
            sl = float(np.linalg.norm(side))
            side = side / sl if sl > 1e-6 else np.array([1.0, 0.0, 0.0])
            up = np.cross(side, N)
            G = (I + N * 0.005
                 - side * (pupil_r[0] * 0.34) + up * (pupil_r[1] * 0.36))
            s.ellipsoid_extra(G, (0.020, 0.022, 0.003), GLINT,
                              subdivisions=2, rot=R)


# ------------------------------------------------------------------ 小狗
def make_dog() -> SDFShape:
    """奶油金幼犬 —— 按犬类解剖分节，而不是「一个椭球当身子 + 四根圆柱」。

    与上一代玩偶比例的区别：胸廓 / 腰 / 臀三段各自成形（背线有起伏、腰收窄），
    有明确的颈、肩胛与髋隆起；四肢分上臂-肘-前臂-腕-脚掌，后腿带膝与跗的
    折角；颅骨、额段、口吻、下颌分开；垂耳有耳根与耳廓厚度。所有部件仍由
    smooth-min 融成一张连续曲面，不会有相贯硬缝。
    """
    s = SDFShape(blend_k=0.115, color_k=0.070)
    FUR, EAR, CREAM = "#E9B979", "#B87C46", "#F8ECD6"

    # ── 躯干：胸廓宽厚、腰收窄、臀圆，腹侧奶白 ──────────────────
    s.ellipsoid((0, 0.02, 0.20), (0.385, 0.390, 0.360), FUR)      # 胸廓
    s.ellipsoid((0, -0.01, -0.20), (0.305, 0.335, 0.320), FUR)    # 腰
    s.ellipsoid((0, 0.03, -0.55), (0.355, 0.365, 0.320), FUR)     # 臀
    s.ellipsoid((0, -0.22, 0.06), (0.260, 0.220, 0.440), CREAM)   # 腹
    s.ellipsoid((0, -0.08, 0.40), (0.235, 0.220, 0.190), CREAM)   # 前胸

    # ── 颈与头：颈把头从躯干上抬起来，不再是「球直接坐在桶上」 ──
    s.ellipsoid((0, 0.36, 0.47), (0.275, 0.300, 0.300), FUR)
    s.ellipsoid((0, 0.53, 0.53), (0.250, 0.240, 0.240), FUR)
    s.ellipsoid((0, 0.72, 0.56), (0.375, 0.360, 0.365), FUR)      # 颅
    s.ellipsoid((0, 0.62, 0.76), (0.245, 0.185, 0.200), FUR)      # 额段 stop
    s.ellipsoid((0, 0.555, 0.90), (0.225, 0.155, 0.265), CREAM)   # 口吻
    s.ellipsoid((0, 0.475, 0.875), (0.205, 0.095, 0.235), CREAM)  # 下颌

    # ── 肩胛 / 髋：真实四肢根部有骨性隆起 ──────────────────────
    for sgn in (-1, 1):
        jx = sgn * 0.285   # 肩胛 / 髋：贴着躯干侧面
        x = sgn * 0.320    # 四肢轴线：比躯干略外，正面能看出四条分开的腿
        s.sphere((jx, 0.10, 0.22), 0.205, FUR)
        s.sphere((jx, 0.09, -0.50), 0.215, FUR)

        # 前腿：上臂 → 肘 → 前臂 → 腕 → 有厚度的脚掌
        s.capsule((x, -0.02, 0.26), (x, -0.32, 0.29), 0.135, FUR)
        s.sphere((x, -0.32, 0.29), 0.125, FUR)
        s.capsule((x, -0.32, 0.29), (x, -0.58, 0.28), 0.100, FUR)
        s.sphere((x, -0.58, 0.28), 0.098, FUR)
        s.ellipsoid((x, -0.655, 0.315), (0.125, 0.075, 0.155), CREAM)

        # 后腿：股骨前下 → 膝 → 胫骨后下 → 跗 → 脚掌（犬类特有折角）
        s.capsule((x, 0.02, -0.47), (x, -0.27, -0.36), 0.165, FUR)
        s.sphere((x, -0.27, -0.36), 0.140, FUR)
        s.capsule((x, -0.27, -0.36), (x, -0.50, -0.55), 0.105, FUR)
        s.sphere((x, -0.50, -0.55), 0.095, FUR)
        s.capsule((x, -0.50, -0.55), (x, -0.64, -0.49), 0.082, FUR)
        s.ellipsoid((x, -0.665, -0.44), (0.125, 0.075, 0.155), CREAM)

        # 垂耳：耳根 → 薄耳廓 → 圆耳垂，向外倾不糊住脸
        s.sphere((sgn * 0.325, 0.92, 0.52), 0.110, EAR)
        s.ellipsoid((sgn * 0.365, 0.72, 0.55),
                    (0.095, 0.245, 0.115), EAR,
                    rot=rotation_matrix(sgn * 0.22, [0, 0, 1]))
        s.sphere((sgn * 0.390, 0.50, 0.55), 0.120, EAR)
        # 颊部让口吻与颅骨之间的过渡更饱满
        s.ellipsoid((sgn * 0.265, 0.62, 0.68),
                    (0.155, 0.170, 0.155), FUR)

    # 尾：从臀后自然下垂再上翘，chain 会自动补胶囊不断成浮空小球
    s.chain([(0, 0.14, -0.84), (0, 0.30, -0.99), (0, 0.52, -1.00),
             (0, 0.68, -0.90)], [0.125, 0.115, 0.095, 0.065], FUR)

    _embedded_nose(s, x=0, y=0.555, radii=(0.100, 0.080, 0.075),
                   color=BLACK, exclude=0.125)
    _eyes(s, x=0.170, y=0.820,
          white_r=(0.098, 0.108, 0.034), pupil_r=(0.066, 0.082, 0.048),
          iris_color="#4A3025", socket_color="#D6A160")
    return s


# ------------------------------------------------------------------ 小猫
def make_cat() -> SDFShape:
    """橘白幼猫 —— 猫科解剖：柔韧脊柱、楔形头、直立耳廓、细长尾、四肢折角。

    与狗共用三段躯干 / 分段四肢 / 颈颅分离的做法，但比例按猫调整：
    腰更细、四肢更修长、头更小且吻部收成楔形、尾更细更长并带自然弧度。
    """
    s = SDFShape(blend_k=0.110, color_k=0.068)
    ORANGE, DARK, WHITE = "#EDA86B", "#D2894C", "#FAF4E8"

    # ── 躯干：猫的胸窄、腰柔韧、背线略拱 ────────────────────────
    s.ellipsoid((0, 0.02, 0.20), (0.360, 0.370, 0.350), ORANGE)   # 胸廓
    s.ellipsoid((0, -0.01, -0.20), (0.290, 0.310, 0.310), ORANGE) # 腰
    s.ellipsoid((0, 0.04, -0.54), (0.340, 0.350, 0.310), ORANGE)  # 臀
    s.ellipsoid((0, -0.22, 0.04), (0.250, 0.200, 0.420), WHITE)   # 腹
    s.ellipsoid((0, -0.06, 0.40), (0.220, 0.220, 0.180), WHITE)   # 前胸

    # ── 颈 / 楔形头 / 短吻 / 下颌 ──────────────────────────────
    s.ellipsoid((0, 0.34, 0.46), (0.250, 0.280, 0.280), ORANGE)
    s.ellipsoid((0, 0.52, 0.51), (0.230, 0.220, 0.220), ORANGE)
    s.ellipsoid((0, 0.72, 0.56), (0.355, 0.345, 0.340), ORANGE)   # 颅
    s.ellipsoid((0, 0.62, 0.75), (0.225, 0.170, 0.190), ORANGE)   # 额段
    s.ellipsoid((0, 0.545, 0.87), (0.190, 0.135, 0.210), WHITE)   # 吻
    s.ellipsoid((0, 0.475, 0.85), (0.180, 0.085, 0.190), WHITE)   # 下颌

    for sgn in (-1, 1):
        jx, x = sgn * 0.270, sgn * 0.300
        s.sphere((jx, 0.10, 0.22), 0.190, ORANGE)
        s.sphere((jx, 0.09, -0.50), 0.200, ORANGE)

        # 前腿：比犬更细，腕部收窄，小圆脚掌
        s.capsule((x, -0.02, 0.26), (x, -0.32, 0.28), 0.115, ORANGE)
        s.sphere((x, -0.32, 0.28), 0.105, ORANGE)
        s.capsule((x, -0.32, 0.28), (x, -0.60, 0.27), 0.085, ORANGE)
        s.sphere((x, -0.60, 0.27), 0.085, ORANGE)
        s.ellipsoid((x, -0.665, 0.30), (0.105, 0.065, 0.135), WHITE)

        # 后腿：股骨 → 膝 → 胫骨 → 跗 → 脚掌
        s.capsule((x, 0.02, -0.47), (x, -0.28, -0.37), 0.145, ORANGE)
        s.sphere((x, -0.28, -0.37), 0.120, ORANGE)
        s.capsule((x, -0.28, -0.37), (x, -0.52, -0.54), 0.090, ORANGE)
        s.sphere((x, -0.52, -0.54), 0.082, ORANGE)
        s.capsule((x, -0.52, -0.54), (x, -0.64, -0.49), 0.072, ORANGE)
        s.ellipsoid((x, -0.665, -0.44), (0.105, 0.065, 0.135), WHITE)

        # 直立三角耳：耳根 + 递变球链（smooth-min 融合，没有尖锥硬边）
        # 耳长要跟缩小的头匹配：上一版头大、这版头小，沿用旧坐标会变成驴耳
        s.sphere((sgn * 0.255, 0.94, 0.50), 0.090, ORANGE)
        s.chain([(sgn * 0.255, 0.97, 0.47), (sgn * 0.278, 1.07, 0.45),
                 (sgn * 0.298, 1.16, 0.43)],
                [0.115, 0.082, 0.026], ORANGE)
        s.ellipsoid_extra((sgn * 0.272, 1.025, 0.555),
                          (0.058, 0.088, 0.022), "#E79A9E",
                          subdivisions=2)                         # 内耳粉
        s.ellipsoid((sgn * 0.245, 0.62, 0.67),
                    (0.140, 0.155, 0.145), ORANGE)               # 颊

    # 猫尾：细长、带 S 形弧度，末端渐尖
    # 尾尖不超过头顶：否则正面会在头旁边竖出一根「天线」
    s.chain([(0, 0.16, -0.82), (0, 0.36, -0.98), (0.06, 0.60, -1.02),
             (0.10, 0.78, -0.94), (0.12, 0.86, -0.82)],
            [0.105, 0.098, 0.090, 0.075, 0.050], DARK)

    _embedded_nose(s, x=0, y=0.545, radii=(0.065, 0.050, 0.048),
                   color="#E28E95", exclude=0.10)
    _eyes(s, x=0.165, y=0.815,
          white_r=(0.112, 0.122, 0.034), pupil_r=(0.078, 0.098, 0.048),
          iris_color="#C9913F", pupil_color="#2C231D", exclude=0.145,
          socket_color="#DB9655")
    # 胡须：贴着脸颊真实曲面走，别像几根白针浮在空中
    for sgn in (-1, 1):
        for dy, ang in ((-0.02, 0.12), (0.045, -0.10)):
            hy = 0.545 + dy
            hit = s.surface_hit(sgn * 0.30, hy)
            hz = (hit[0][2] + 0.008) if hit else 0.86
            s.ellipsoid_extra((sgn * 0.32, hy, hz),
                              (0.14, 0.007, 0.007), WHITE, subdivisions=2,
                              rot=rotation_matrix(sgn * ang, [0, 1, 0]))
    return s


# ------------------------------------------------------------------ 小龙
def make_dragon() -> SDFShape:
    """薄荷绿毛绒小龙：圆润短角、软翼、背脊圆刺、粗尾，解剖连贯不散架。"""
    s = SDFShape(blend_k=0.125, color_k=0.080)
    GREEN, DEEP, BELLY = "#8FC79B", "#5E9C6C", "#EADDA9"
    HORN, WING = "#F3E7C9", "#B4DBBD"

    # 躯干同样分胸廓 / 腰 / 臀三段，腹侧浅色，背线由 dorsal_shade 压深
    s.ellipsoid((0, 0.06, 0.24), (0.420, 0.420, 0.380), GREEN)    # 胸廓
    s.ellipsoid((0, 0.04, -0.20), (0.350, 0.370, 0.340), GREEN)   # 腰
    s.ellipsoid((0, 0.08, -0.54), (0.390, 0.380, 0.330), GREEN)   # 臀
    s.ellipsoid((0, -0.20, 0.06), (0.300, 0.250, 0.460), BELLY)   # 腹甲
    s.ellipsoid((0, 0.40, 0.36), (0.260, 0.300, 0.300), GREEN)    # 颈根
    s.ellipsoid((0, 0.62, 0.46), (0.235, 0.260, 0.260), GREEN)    # 颈
    s.ellipsoid((0, 0.84, 0.58), (0.400, 0.370, 0.380), GREEN)    # 颅
    s.ellipsoid((0, 0.76, 0.78), (0.270, 0.200, 0.220), GREEN)    # 额段
    s.ellipsoid((0, 0.70, 0.92), (0.245, 0.180, 0.260), GREEN)    # 吻
    s.ellipsoid((0, 0.625, 0.90), (0.220, 0.100, 0.230), BELLY)   # 下颌

    for sgn in (-1, 1):
        jx, x = sgn * 0.300, sgn * 0.320
        s.sphere((jx, 0.16, 0.26), 0.220, GREEN)                  # 肩
        s.sphere((jx, 0.14, -0.50), 0.230, GREEN)                 # 髋
        # 前肢：上臂 → 肘 → 前臂 → 腕 → 三趾感的宽爪
        s.capsule((x, 0.02, 0.30), (x, -0.32, 0.32), 0.140, DEEP)
        s.sphere((x, -0.32, 0.32), 0.130, DEEP)
        s.capsule((x, -0.32, 0.32), (x, -0.60, 0.30), 0.100, DEEP)
        s.sphere((x, -0.60, 0.30), 0.100, DEEP)
        s.ellipsoid((x, -0.665, 0.34), (0.130, 0.075, 0.160), DEEP)
        # 后肢：股 → 膝 → 胫 → 跗 → 爪
        s.capsule((x, 0.04, -0.48), (x, -0.28, -0.36), 0.170, DEEP)
        s.sphere((x, -0.28, -0.36), 0.145, DEEP)
        s.capsule((x, -0.28, -0.36), (x, -0.52, -0.55), 0.110, DEEP)
        s.sphere((x, -0.52, -0.55), 0.100, DEEP)
        s.capsule((x, -0.52, -0.55), (x, -0.64, -0.49), 0.085, DEEP)
        s.ellipsoid((x, -0.665, -0.44), (0.130, 0.075, 0.160), DEEP)

        # 翼：薄翼膜 + 前缘翼骨 + 一根翼指，不再是一片没有结构的扁椭球
        s.ellipsoid((sgn * 0.68, 0.70, -0.20), (0.500, 0.105, 0.380), WING,
                    rot=rotation_matrix(sgn * 0.72, [0, 0, 1]))
        s.sphere((sgn * 0.38, 0.70, -0.12), 0.125, WING)         # 翼根
        s.chain([(sgn * 0.42, 0.78, -0.14), (sgn * 0.72, 0.96, -0.18),
                 (sgn * 1.02, 1.06, -0.22), (sgn * 1.20, 1.10, -0.24)],
                [0.105, 0.080, 0.052, 0.024], WING)               # 前缘翼骨
        s.chain([(sgn * 0.55, 0.60, -0.30), (sgn * 0.82, 0.52, -0.42)],
                [0.060, 0.024], WING)                             # 翼指
        # 短角：向后掠、圆头，不做竖直长锥（否则像兔耳朵）
        s.chain([(sgn * 0.22, 1.12, 0.48), (sgn * 0.30, 1.28, 0.36),
                 (sgn * 0.34, 1.34, 0.28)], [0.075, 0.050, 0.025], HORN)

    for z, h in ((0.10, 0.62), (-0.16, 0.58), (-0.42, 0.50)):
        s.chain([(0, h - 0.08, z), (0, h + 0.10, z - 0.04)],
                [0.075, 0.032], HORN)                              # 背脊圆刺

    s.chain([(0, 0.18, -0.70), (0, 0.22, -0.98), (0.08, 0.30, -1.24),
             (0.18, 0.40, -1.44)], [0.145, 0.120, 0.092, 0.055], DEEP)

    _eyes(s, x=0.170, y=0.925,
          white_r=(0.100, 0.108, 0.034), pupil_r=(0.064, 0.080, 0.046),
          iris_color="#3E6B48", pupil_color=BLACK, exclude=0.13,
          socket_color="#79B488")
    for sgn in (-1, 1):
        _embedded_nose(s, x=sgn * 0.115, y=0.79,
                       radii=(0.030, 0.026, 0.020), color="#4C7A55",
                       embed=0.55, exclude=0.05)
    return s


# ------------------------------------------------------------------ 非动物：圆角化但无绒毛
def make_robot() -> SDFShape:
    """蓝黄圆角玩具机器人：倒角机体与四肢用 SDF 融合，衔接处没有硬缝。"""
    s = SDFShape(blend_k=0.10, color_k=0.06)
    BLUE, DEEP, YELLOW = "#4A7CB8", "#33598B", "#F2C14E"
    DARK, GLOW = "#2A3542", "#8DE9F2"

    s.round_box((0, 0.04, 0), (0.78, 0.84, 0.52), 0.16, BLUE)
    s.round_box((0, 0.86, 0), (0.68, 0.56, 0.50), 0.14, BLUE)
    s.capsule((0, 0.40, 0), (0, 0.62, 0), 0.13, DEEP)
    for x in (-0.50, 0.50):
        s.capsule((x, 0.34, 0), (x, -0.14, 0), 0.105, DEEP)
        s.sphere((x, -0.19, 0), 0.135, YELLOW)
        s.round_box((x * 0.77, 0.86, 0), (0.10, 0.24, 0.26), 0.045, YELLOW)
    for x in (-0.22, 0.22):
        s.capsule((x, -0.38, 0), (x, -0.78, 0), 0.125, DEEP)
        s.round_box((x, -0.82, 0.07), (0.30, 0.13, 0.42), 0.055, DARK)
    s.capsule((0, 1.12, 0), (0, 1.34, 0), 0.028, DARK)
    s.sphere((0, 1.39, 0), 0.085, YELLOW)

    visor = trimesh.creation.box(extents=(0.50, 0.30, 0.035))
    visor.apply_translation([0, 0.86, 0.262])
    s.extra(visor, DARK)  # 面罩底
    for x in (-0.145, 0.145):
        s.ellipsoid_extra((x, 0.87, 0.288), (0.078, 0.086, 0.022), GLOW,
                          subdivisions=2)
    s.ellipsoid_extra((0, 0.06, 0.275), (0.105, 0.105, 0.025), GLOW,
                      subdivisions=2)
    s.ellipsoid_extra((0, 0.06, 0.298), (0.045, 0.045, 0.012), YELLOW,
                      subdivisions=2)
    return s


def make_chair() -> SDFShape:
    """木椅：座面 / 靠背 / 四腿用圆角 SDF 融合，像真实实木倒角家具。"""
    s = SDFShape(blend_k=0.105, color_k=0.06)
    WOOD, DEEP = "#B5793E", "#8C5628"

    s.round_box((0, 0.04, 0), (1.00, 0.14, 0.92), 0.055, WOOD)
    for x in (-0.40, 0.40):
        for z in (-0.37, 0.37):
            s.capsule((x, 0.02, z), (x, -0.90, z), 0.075, DEEP)
        s.capsule((x, 0.10, -0.40), (x, 1.10, -0.40), 0.070, DEEP)
    for y in (0.70, 1.02):
        s.round_box((0, y, -0.40), (0.92, 0.15, 0.11), 0.055, WOOD)
    return s


def make_flower() -> SDFShape:
    """粉色柔润花朵：花瓣用倾斜椭球与花心自然融合，无硬拼接。"""
    s = SDFShape(blend_k=0.075, color_k=0.05)
    PINK, PINK_D, YELLOW = "#EE8FB0", "#D97198", "#F5C542"
    GREEN, DEEP = "#4E9B5B", "#357A43"

    s.capsule((0, -0.95, 0), (0, 0.38, 0), 0.055, GREEN)
    for sgn in (-1, 1):
        s.ellipsoid((sgn * 0.30, -0.36, 0), (0.30, 0.10, 0.16), DEEP,
                    rot=rotation_matrix(sgn * 0.30, [0, 0, 1]))
    for i in range(8):
        a = 2 * np.pi * i / 8
        c = np.array([0.34 * np.cos(a), 0.34 * np.sin(a), 0.52])
        s.ellipsoid(c, (0.27, 0.17, 0.10), PINK if i % 2 == 0 else PINK_D,
                    rot=rotation_matrix(a, [0, 0, 1]))
    s.ellipsoid((0, 0, 0.58), (0.22, 0.22, 0.13), YELLOW)
    s.ellipsoid_extra((0, 0, 0.685), (0.13, 0.13, 0.055), "#E8A92E",
                      subdivisions=2)
    return s


BUILDERS = {
    "dog": make_dog, "cat": make_cat, "dragon": make_dragon,
    "robot": make_robot, "chair": make_chair, "flower": make_flower,
}
PROMPTS = {
    "dog": "a cute fluffy cartoon dog", "cat": "a cute fluffy cartoon cat",
    "dragon": "a cute green dragon", "robot": "a friendly robot",
    "chair": "a wooden chair", "flower": "a pink flower",
}
NAMES = {
    "dog": "小狗", "cat": "小猫", "dragon": "小龙",
    "robot": "机器人", "chair": "木椅", "flower": "小花",
}
# 只有动物长绒毛；家具/机械/植物保持干净表面
FURRY = {"dog", "cat", "dragon"}


def patch_glb(glb: bytes, normals: np.ndarray | None = None) -> bytes:
    """补齐平滑法线 + 织物 sheen 材质。

    trimesh 的 ColorVisuals 只写 POSITION/COLOR_0：缺 NORMAL 时 three.js 会
    computeVertexNormals() 退化成硬边；缺 material 时部分版本会忽略 COLOR_0。
    法线优先用传入的 SDF 梯度（比面法线平滑得多）。
    KHR_materials_sheen 给绒毛/织物一层掠射角柔光，是「毛绒感」的材质部分。
    """
    magic, version, _ = struct.unpack_from("<4sII", glb, 0)
    assert magic == b"glTF" and version == 2
    off = 12
    json_len, _ = struct.unpack_from("<I4s", glb, off)
    off += 8
    doc = json.loads(glb[off:off + json_len].decode("utf-8"))
    off += json_len
    bin_len, _ = struct.unpack_from("<I4s", glb, off)
    off += 8
    bin_data = bytearray(glb[off:off + bin_len])

    while len(bin_data) % 4:
        bin_data.append(0)
    nv_off = len(bin_data)
    nbytes = normals.astype(np.float32).tobytes()
    bin_data.extend(nbytes)

    doc["buffers"][0]["byteLength"] = len(bin_data)
    doc["bufferViews"].append({
        "buffer": 0, "byteOffset": nv_off,
        "byteLength": len(nbytes), "target": 34962,
    })
    doc["accessors"].append({
        "bufferView": len(doc["bufferViews"]) - 1,
        "componentType": 5126, "count": len(normals), "type": "VEC3",
    })
    # 导出的 POSITION 顶点数必须与法线数组一致，否则 accessor 会错位、GLB 直接损坏
    npos = None
    for m in doc["meshes"]:
        for prim in m["primitives"]:
            idx = prim.get("attributes", {}).get("POSITION")
            if idx is not None:
                npos = doc["accessors"][idx]["count"]
                break
    if npos is not None and npos != len(normals):
        raise RuntimeError(f"GLB 顶点数错位：POSITION={npos} NORMAL={len(normals)}")

    used = doc.get("extensionsUsed", [])
    if "KHR_materials_sheen" not in used:
        used = used + ["KHR_materials_sheen"]
    doc["extensionsUsed"] = used
    doc["materials"] = [{
        "name": "fuzzyFabric",
        "pbrMetallicRoughness": {
            "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.95,
        },
        "doubleSided": True,
        "extensions": {
            "KHR_materials_sheen": {
                "sheenColorFactor": [0.85, 0.85, 0.85],
                "sheenRoughnessFactor": 0.85,
            },
        },
    }]
    for m in doc["meshes"]:
        for prim in m["primitives"]:
            prim["attributes"]["NORMAL"] = len(doc["accessors"]) - 1
            prim.setdefault("material", 0)

    jb = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    jb += b" " * ((4 - len(jb) % 4) % 4)
    while len(bin_data) % 4:
        bin_data.append(0)
    body = (struct.pack("<I4s", len(jb), b"JSON") + jb +
            struct.pack("<I4s", len(bin_data), b"BIN\x00") + bytes(bin_data))
    return struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--only", default=None, help="只生成指定 id，便于快速迭代")
    ap.add_argument("--res", type=int, default=88, help="SDF 采样分辨率")
    ap.add_argument("--fur", type=int, default=14000, help="绒毛根数（动物）")
    ap.add_argument("--fur-length", type=float, default=0.020, help="绒毛长度")
    ap.add_argument("--fur-radius", type=float, default=0.0045, help="绒毛根部半径")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    keys = [args.only] if args.only else list(BUILDERS)
    manifest = []
    for key in keys:
        shape = BUILDERS[key]()
        res = args.res if key in FURRY else max(64, args.res - 16)
        fur = args.fur if key in FURRY else 0
        print(f"[build] {key} ...", flush=True)
        mesh, normals = shape.build(
            res=res, fur_count=fur,
            seed={"dog": 7, "cat": 13, "dragon": 23}.get(key, 5),
            fur_length=args.fur_length, fur_radius=args.fur_radius,
            noise_strength=0.075 if key in FURRY else 0.025,
            dorsal_shade=0.11 if key in FURRY else 0.0,
        )
        buf = io.BytesIO()
        mesh.export(buf, file_type="glb")
        data = patch_glb(buf.getvalue(), normals)
        path = os.path.join(args.out, f"{key}.glb")
        with open(path, "wb") as f:
            f.write(data)
        manifest.append({
            "id": key, "name": NAMES[key], "prompt": PROMPTS[key],
            "file": f"{key}.glb", "source": "procedural-sdf",
            "rev": SAMPLE_REV,
        })
        print(f"[build] {key:8s} verts={len(mesh.vertices):7d} "
              f"faces={len(mesh.faces):7d} size={len(data)/1024:8.1f} KB", flush=True)

    if args.only and os.path.exists(os.path.join(args.out, "manifest.json")):
        with open(os.path.join(args.out, "manifest.json"), encoding="utf-8") as f:
            old = json.load(f)
        by_id = {m["id"]: m for m in old}
        by_id.update({m["id"]: m for m in manifest})
        manifest = [by_id[k] for k in BUILDERS if k in by_id]
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f"[build] manifest -> {os.path.join(args.out, 'manifest.json')}")


if __name__ == "__main__":
    main()
