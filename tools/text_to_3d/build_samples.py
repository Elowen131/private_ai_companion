#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成本地高质量样例 GLB —— 纯程序化建模，零下载 / 零花费 / 零 GPU。

为什么不继续用 Shap-E 的产物当样例
----------------------------------
Shap-E(text300M) 是 2023 年的早期文生 3D 模型，在 CPU 上把
num_inference_steps 降到 16、frame_size 降到 64 后，输出是一团无法辨认的
融化状网格：所谓「狗」只有一坨躯干、头尾不分、腿粘连；「龙」直接散架成碎片。
拿这种东西当 App 里的展示资产是不诚实的。

本脚本用基本几何体拼装**一眼可辨认**的卡通模型：
  dog / cat / dragon / robot / chair / flower
每个部件独立配色（顶点色，glTF COLOR_0，App 的 three.js 渲染器可直接显示），
带平滑法线，导出为体积极小的 GLB。

    python tools/text_to_3d/build_samples.py
    python tools/text_to_3d/build_samples.py --out /some/dir
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

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "samples")


def _rgb(hex_color: str) -> np.ndarray:
    h = hex_color.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)] + [255], dtype=np.uint8)


class Builder:
    """收集带颜色的部件，最后合并成单个带顶点色的 mesh。"""

    def __init__(self):
        self.parts: list[trimesh.Trimesh] = []

    @staticmethod
    def _paint(mesh: trimesh.Trimesh, color: str) -> trimesh.Trimesh:
        mesh = mesh.copy()
        c = _rgb(color)
        mesh.visual = trimesh.visual.ColorVisuals(
            mesh=mesh,
            vertex_colors=np.tile(c, (len(mesh.vertices), 1)),
        )
        return mesh

    def sphere(self, center, radii, color, subdivisions=3):
        m = trimesh.creation.icosphere(subdivisions=subdivisions, radius=1.0)
        m.apply_scale(radii)
        m.apply_translation(center)
        self.parts.append(self._paint(m, color))
        return self

    def box(self, center, extents, color, rot=None):
        m = trimesh.creation.box(extents=extents)
        if rot is not None:
            m.apply_transform(rot)
        m.apply_translation(center)
        self.parts.append(self._paint(m, color))
        return self

    def cylinder(self, start, end, radius, color, radius_top=None, sections=20):
        """沿 start->end 的圆柱 / 圆台。

        自己手工构造而非调用 trimesh.creation.cone：不同 trimesh 版本对
        `radius2` / `radius_top` 的支持不一致，静默忽略后会把「等半径柱体」
        画成尖锥（椅腿变成牙签）。手工构造彻底规避版本差异。
        """
        a, b = np.asarray(start, float), np.asarray(end, float)
        d = b - a
        length = float(np.linalg.norm(d))
        if length < 1e-9:
            return self
        r0 = float(radius)
        r1 = r0 if radius_top is None else float(radius_top)

        angles = np.linspace(0.0, 2 * np.pi, sections, endpoint=False)
        ca, sa = np.cos(angles), np.sin(angles)
        bottom = np.column_stack([r0 * ca, r0 * sa, np.zeros(sections)])
        verts = [bottom]
        faces = []
        if r1 > 1e-7:
            top = np.column_stack([r1 * ca, r1 * sa, np.full(sections, length)])
            verts.append(top)
            off = sections
            for i in range(sections):
                j = (i + 1) % sections
                faces.append([i, j, off + j])
                faces.append([i, off + j, off + i])
            # 顶盖：扇形三角化（保持全三角，避免 ragged faces）
            for i in range(1, sections - 1):
                faces.append([off, off + i, off + i + 1])
        else:
            # 尖顶：单个顶点
            apex = sections
            verts.append(np.array([[0.0, 0.0, length]]))
            for i in range(sections):
                j = (i + 1) % sections
                faces.append([i, j, apex])
        # 底盖：扇形三角化（反向绕序）
        for i in range(1, sections - 1):
            faces.append([0, i + 1, i])
        m = trimesh.Trimesh(
            vertices=np.vstack(verts), faces=np.asarray(faces, dtype=np.int64),
            process=False,
        )
        m.apply_translation([0, 0, -length / 2])
        # 对齐到 d
        z = np.array([0.0, 0.0, 1.0])
        v = np.cross(z, d / length)
        c = float(np.dot(z, d / length))
        if np.linalg.norm(v) > 1e-8:
            R = rotation_matrix(np.arccos(np.clip(c, -1, 1)), v / np.linalg.norm(v))
            m.apply_transform(R)
        else:
            axis = np.array([1.0, 0.0, 0.0])
            R = rotation_matrix(np.arccos(np.clip(c, -1, 1)), axis)
            m.apply_transform(R)
        m.apply_translation((a + b) / 2)
        self.parts.append(self._paint(m, color))
        return self

    def capsule(self, start, end, radius, color):
        """一条圆头线段：中间圆柱 + 两端球。"""
        self.cylinder(start, end, radius, color)
        self.sphere(start, (radius,) * 3, color)
        self.sphere(end, (radius,) * 3, color)
        return self

    def build(self) -> trimesh.Trimesh:
        return trimesh.util.concatenate(self.parts)


_CONE_R2 = None


def _cone_accepts_radius2() -> bool:
    global _CONE_R2
    if _CONE_R2 is None:
        import inspect
        try:
            sig = inspect.signature(trimesh.creation.cone)
            _CONE_R2 = "radius2" in sig.parameters
        except (TypeError, ValueError):
            _CONE_R2 = False
    return bool(_CONE_R2)


# ---------------------------------------------------------------- 狗
def make_dog() -> trimesh.Trimesh:
    """暖棕色卡通小狗：圆头、垂耳、黑鼻、四腿、翘尾、红项圈。"""
    b = Builder()
    FUR = "#D9A05B"
    FUR_DARK = "#A9702F"
    CREAM = "#F6E7CE"
    BLACK = "#2A2622"
    RED = "#D8483F"

    # 躯干（前后略长）
    b.sphere((0, 0.10, -0.18), (0.55, 0.48, 0.78), FUR)
    b.sphere((0, 0.20, 0.30), (0.44, 0.44, 0.40), FUR)  # 胸
    # 四条腿（前后腿分开、带脚掌）
    for x in (-0.34, 0.34):
        for z in (0.34, -0.62):
            b.capsule((x, -0.22, z), (x, -0.80, z), 0.145, FUR_DARK)
            b.sphere((x, -0.82, z + 0.06), (0.185, 0.12, 0.22), FUR_DARK)
    # 头
    b.sphere((0, 0.72, 0.58), (0.46, 0.44, 0.43), FUR)
    # 口鼻（米白）+ 黑鼻头 + 嘴
    b.sphere((0, 0.60, 0.94), (0.27, 0.20, 0.26), CREAM)
    b.sphere((0, 0.66, 1.17), (0.115, 0.09, 0.085), BLACK)
    b.cylinder((0, 0.55, 1.18), (0, 0.52, 1.20), 0.018, BLACK, sections=10)
    # 眼睛 + 高光
    for x in (-0.20, 0.20):
        b.sphere((x, 0.82, 0.94), (0.085, 0.095, 0.065), BLACK)
        b.sphere((x - 0.025, 0.855, 0.995), (0.028, 0.028, 0.018), "#FFFFFF")
    # 下垂耳朵
    for x in (-0.43, 0.43):
        b.sphere((x, 0.66, 0.50), (0.155, 0.30, 0.13), FUR_DARK)
    # 项圈
    b.cylinder((0, 0.36, 0.42), (0, 0.46, 0.42), 0.375, RED, sections=24)
    b.sphere((0, 0.30, 0.67), (0.075, 0.075, 0.055), "#F2C14E")
    # 翘尾巴（三段递进）
    b.capsule((0, 0.34, -0.86), (0, 0.58, -1.06), 0.105, FUR_DARK)
    b.capsule((0, 0.58, -1.06), (0, 0.82, -1.02), 0.085, FUR_DARK)
    return b.build()


# ---------------------------------------------------------------- 猫
def make_cat() -> trimesh.Trimesh:
    """橘白卡通猫：尖耳、大眼、粉鼻、胡须、竖长尾。"""
    b = Builder()
    ORANGE = "#E8944A"
    ORANGE_D = "#C8762F"
    WHITE = "#F7F1E4"
    BLACK = "#2A2622"
    PINK = "#E8888C"

    b.sphere((0, 0.06, -0.16), (0.48, 0.46, 0.70), ORANGE)
    b.sphere((0, -0.02, 0.28), (0.34, 0.36, 0.32), WHITE)  # 胸白
    for x in (-0.30, 0.30):
        for z in (0.34, -0.58):
            b.capsule((x, -0.26, z), (x, -0.78, z), 0.125, ORANGE_D)
            b.sphere((x, -0.80, z + 0.05), (0.16, 0.10, 0.19), WHITE)
    # 头（比狗更圆更大）
    b.sphere((0, 0.70, 0.52), (0.48, 0.46, 0.44), ORANGE)
    b.sphere((0, 0.60, 0.88), (0.26, 0.18, 0.16), WHITE)  # 口鼻白
    # 尖耳（三角锥）+ 内耳粉
    for x in (-0.30, 0.30):
        b.cylinder((x, 0.98, 0.46), (x * 1.08, 1.32, 0.44), 0.16, ORANGE,
                   radius_top=0.0, sections=4)
        b.sphere((x, 1.03, 0.56), (0.075, 0.13, 0.03), PINK)
    # 大眼（黑瞳 + 白眼白 + 高光）
    for x in (-0.21, 0.21):
        b.sphere((x, 0.76, 0.90), (0.135, 0.15, 0.07), WHITE)
        b.sphere((x, 0.76, 0.965), (0.075, 0.12, 0.045), BLACK)
        b.sphere((x - 0.03, 0.81, 1.005), (0.032, 0.035, 0.018), "#FFFFFF")
    b.sphere((0, 0.65, 1.03), (0.065, 0.05, 0.045), PINK)
    # 胡须
    for x in (-1, 1):
        for dy in (-0.02, 0.05):
            b.cylinder((x * 0.14, 0.62 + dy, 1.00),
                       (x * 0.52, 0.64 + dy * 2, 0.98), 0.012, WHITE, sections=8)
    # 竖长尾
    b.capsule((0, 0.22, -0.78), (0, 0.70, -1.00), 0.10, ORANGE_D)
    b.capsule((0, 0.70, -1.00), (0.06, 1.02, -0.92), 0.085, ORANGE_D)
    return b.build()


# ---------------------------------------------------------------- 龙
def make_dragon() -> trimesh.Trimesh:
    """绿色卡通小龙：角、吻部、双翼、背刺、四足、长尾。"""
    b = Builder()
    GREEN = "#5FA86A"
    GREEN_D = "#3C7A4B"
    BELLY = "#D8D48C"
    HORN = "#F0E2B6"
    BLACK = "#2A2622"
    WING = "#8CC79A"

    b.sphere((0, 0.16, -0.10), (0.52, 0.50, 0.72), GREEN)
    b.sphere((0, 0.02, 0.30), (0.36, 0.34, 0.36), BELLY)
    # 四足
    for x in (-0.34, 0.34):
        for z in (0.34, -0.56):
            b.capsule((x, -0.16, z), (x, -0.70, z), 0.15, GREEN_D)
            b.sphere((x, -0.72, z + 0.09), (0.20, 0.11, 0.24), GREEN_D)
    # 脖子 + 头
    b.cylinder((0, 0.40, 0.30), (0, 0.78, 0.52), 0.24, GREEN, sections=20)
    b.sphere((0, 0.90, 0.66), (0.40, 0.34, 0.40), GREEN)
    b.sphere((0, 0.80, 0.98), (0.27, 0.19, 0.28), GREEN)  # 吻
    for x in (-0.13, 0.13):
        b.sphere((x, 0.86, 1.22), (0.035, 0.03, 0.03), BLACK)  # 鼻孔
    for x in (-0.22, 0.22):
        b.sphere((x, 0.98, 0.94), (0.09, 0.09, 0.06), BLACK)  # 眼
        b.sphere((x - 0.025, 1.005, 0.985), (0.028, 0.028, 0.016), "#FFFFFF")
        # 角
        b.cylinder((x * 0.9, 1.14, 0.58), (x * 1.25, 1.46, 0.44),
                   0.075, HORN, radius_top=0.0, sections=12)
    # 双翼（扁平椭球，向外张开）
    for s in (-1, 1):
        wing = b.sphere((s * 0.72, 0.52, -0.16), (0.62, 0.10, 0.46), WING)
        # 翼骨
        b.cylinder((s * 0.30, 0.36, -0.12), (s * 1.28, 0.72, -0.26),
                   0.035, GREEN_D, sections=10)
    # 背刺
    for z in (0.10, -0.18, -0.44):
        b.cylinder((0, 0.58, z), (0, 0.90, z - 0.06), 0.09, HORN,
                   radius_top=0.0, sections=6)
    # 长尾
    b.capsule((0, 0.20, -0.72), (0, 0.26, -1.16), 0.15, GREEN_D)
    b.capsule((0, 0.26, -1.16), (0.14, 0.36, -1.52), 0.10, GREEN_D)
    return b.build()


# ---------------------------------------------------------------- 机器人
def make_robot() -> trimesh.Trimesh:
    """蓝黄卡通机器人：方头、发光眼、天线、双臂双腿。"""
    b = Builder()
    BLUE = "#3E6FB0"
    BLUE_D = "#2A4E80"
    YELLOW = "#F2C14E"
    DARK = "#26303B"
    EYE = "#7FE3F0"

    b.box((0, 0.05, 0), (0.78, 0.86, 0.52), BLUE)
    b.box((0, 0.10, 0.27), (0.44, 0.42, 0.04), YELLOW)  # 胸前面板
    b.sphere((0, 0.10, 0.30), (0.10, 0.10, 0.025), EYE)
    # 头
    b.box((0, 0.82, 0), (0.66, 0.54, 0.50), BLUE)
    b.box((0, 0.84, 0.255), (0.50, 0.30, 0.03), DARK)  # 面罩
    for x in (-0.14, 0.14):
        b.sphere((x, 0.85, 0.278), (0.075, 0.085, 0.022), EYE)
    b.cylinder((0, 1.09, 0), (0, 1.36, 0), 0.028, DARK, sections=10)
    b.sphere((0, 1.40, 0), (0.09, 0.09, 0.09), YELLOW)
    # 耳朵
    for x in (-0.37, 0.37):
        b.box((x, 0.82, 0), (0.10, 0.24, 0.26), YELLOW)
    # 手臂
    for x in (-0.50, 0.50):
        b.capsule((x, 0.36, 0), (x, -0.14, 0), 0.10, BLUE_D)
        b.sphere((x, -0.20, 0), (0.14, 0.14, 0.14), YELLOW)
    # 腿
    for x in (-0.22, 0.22):
        b.capsule((x, -0.38, 0), (x, -0.82, 0), 0.13, BLUE_D)
        b.box((x, -0.86, 0.06), (0.30, 0.12, 0.42), DARK)
    return b.build()


# ---------------------------------------------------------------- 椅子
def make_chair() -> trimesh.Trimesh:
    """木椅：座面、靠背横档、四条腿。"""
    b = Builder()
    WOOD = "#B5793E"
    WOOD_D = "#8C5628"

    b.box((0, 0.05, 0), (1.00, 0.12, 0.92), WOOD)  # 座面
    for x in (-0.42, 0.42):
        for z in (-0.38, 0.38):
            b.cylinder((x, 0.00, z), (x, -0.92, z), 0.075, WOOD_D, sections=12)
    # 靠背立柱 + 两根横档
    for x in (-0.42, 0.42):
        b.cylinder((x, 0.10, -0.40), (x, 1.12, -0.40), 0.070, WOOD_D, sections=12)
    for y in (0.72, 1.02):
        b.box((0, y, -0.40), (0.94, 0.14, 0.10), WOOD)
    return b.build()


# ---------------------------------------------------------------- 花
def make_flower() -> trimesh.Trimesh:
    """粉色花朵：8 瓣、黄花心、绿茎、两片叶。"""
    b = Builder()
    PINK = "#EE8FB0"
    PINK_D = "#D97198"
    YELLOW = "#F5C542"
    GREEN = "#4E9B5B"
    GREEN_D = "#357A43"

    b.cylinder((0, -0.95, 0), (0, 0.42, 0), 0.055, GREEN, sections=14)
    # 叶片
    for s in (-1, 1):
        b.sphere((s * 0.30, -0.36, 0), (0.30, 0.11, 0.16), GREEN_D)
    # 花瓣（绕 Z 轴一圈，朝外张开）
    for i in range(8):
        a = 2 * np.pi * i / 8
        cx, cy = 0.34 * np.cos(a), 0.34 * np.sin(a)
        m = trimesh.creation.icosphere(subdivisions=2, radius=1.0)
        m.apply_scale((0.26, 0.17, 0.10))
        m.apply_transform(rotation_matrix(a, [0, 0, 1]))
        m.apply_translation((cx, cy, 0.52))
        b.parts.append(Builder._paint(m, PINK if i % 2 == 0 else PINK_D))
    b.sphere((0, 0, 0.60), (0.22, 0.22, 0.13), YELLOW)
    b.sphere((0, 0, 0.70), (0.13, 0.13, 0.06), "#E8A92E")
    return b.build()


def patch_glb(glb: bytes, mesh: trimesh.Trimesh) -> bytes:
    """给 trimesh 导出的 GLB 补上平滑法线 + PBR 材质。

    trimesh 的 ColorVisuals 只写 POSITION/COLOR_0：没有 NORMAL 时 three.js 会
    computeVertexNormals() 退化成硬边着色；没有 material 时部分版本会把
    COLOR_0 忽略、显示成白模。这里在二进制层补齐，保证 App 里颜色与圆润度都在。
    """
    magic, version, total = struct.unpack_from("<4sII", glb, 0)
    assert magic == b"glTF" and version == 2
    off = 12
    json_len, json_type = struct.unpack_from("<I4s", glb, off)
    off += 8
    doc = json.loads(glb[off:off + json_len].decode("utf-8"))
    off += json_len
    bin_len, bin_type = struct.unpack_from("<I4s", glb, off)
    off += 8
    bin_data = bytearray(glb[off:off + bin_len])

    # 面法线按面积加权累加到顶点（纯 NumPy，不依赖 scipy）
    v = np.asarray(mesh.vertices, dtype=np.float64)
    f = np.asarray(mesh.faces, dtype=np.int64)
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    normals = np.zeros_like(v)
    np.add.at(normals, f[:, 0], fn)
    np.add.at(normals, f[:, 1], fn)
    np.add.at(normals, f[:, 2], fn)
    lens = np.linalg.norm(normals, axis=1)
    lens[lens < 1e-12] = 1.0
    normals = (normals / lens[:, None]).astype(np.float32)

    while len(bin_data) % 4:
        bin_data.append(0)
    nv_off = len(bin_data)
    bin_data.extend(normals.tobytes())

    doc["buffers"][0]["byteLength"] = len(bin_data)
    doc["bufferViews"].append({
        "buffer": 0, "byteOffset": nv_off,
        "byteLength": len(normals.tobytes()), "target": 34962,
    })
    doc["accessors"].append({
        "bufferView": len(doc["bufferViews"]) - 1,
        "componentType": 5126, "count": len(normals), "type": "VEC3",
    })
    doc["materials"] = [{
        "name": "vertexColor",
        "pbrMetallicRoughness": {
            "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.85,
        },
        "doubleSided": True,
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


BUILDERS = {
    "dog": make_dog,
    "cat": make_cat,
    "dragon": make_dragon,
    "robot": make_robot,
    "chair": make_chair,
    "flower": make_flower,
}

PROMPTS = {
    "dog": "a cute cartoon dog",
    "cat": "a cute cartoon cat",
    "dragon": "a cute green dragon",
    "robot": "a friendly robot",
    "chair": "a wooden chair",
    "flower": "a pink flower",
}

NAMES = {
    "dog": "小狗", "cat": "小猫", "dragon": "小龙",
    "robot": "机器人", "chair": "木椅", "flower": "小花",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    manifest = []
    for key, fn in BUILDERS.items():
        mesh = fn()
        buf = io.BytesIO()
        mesh.export(buf, file_type="glb")
        data = patch_glb(buf.getvalue(), mesh)
        path = os.path.join(args.out, f"{key}.glb")
        with open(path, "wb") as f:
            f.write(data)
        manifest.append({
            "id": key,
            "name": NAMES[key],
            "prompt": PROMPTS[key],
            "file": f"{key}.glb",
            "source": "procedural",
        })
        print(f"[build] {key:8s} verts={len(mesh.vertices):6d} "
              f"faces={len(mesh.faces):6d} size={len(data)/1024:8.1f} KB")

    import json
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f"[build] manifest -> {os.path.join(args.out, 'manifest.json')}")


if __name__ == "__main__":
    main()
