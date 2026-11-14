#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GLB 多视角软件渲染预览（纯 NumPy，无 OpenGL / 无 GPU / 无额外依赖）。

用途：在没有显示器的环境里也能**亲眼确认**生成的 3D 到底长什么样，
避免「只看文件大小和 glTF magic 就宣称成功」。

    python render_glb.py samples/dog.glb -o preview.png
    python render_glb.py samples/*.glb -o contact.png --grid
"""
from __future__ import annotations

import argparse
import json
import math
import os
import struct

import numpy as np
import trimesh
from PIL import Image, ImageDraw


def _vertex_colors_from_glb(path: str) -> np.ndarray | None:
    """直接从 GLB 二进制解析 COLOR_0。

    trimesh 遇到带 PBR material 的 GLB 会把 visual 切成 TextureVisuals，
    于是 `vertex_colors` 读不到、预览会误显示成灰色（白模假象）。这里绕过
    trimesh 的解释，直接读 accessor，验证文件里的颜色数据是否真实存在。
    """
    d = open(path, "rb").read()
    magic, ver, _ = struct.unpack_from("<4sII", d, 0)
    if magic != b"glTF" or ver != 2:
        return None
    off = 12
    jlen, _ = struct.unpack_from("<I4s", d, off)
    off += 8
    doc = json.loads(d[off:off + jlen].decode("utf-8"))
    off += jlen
    blen, _ = struct.unpack_from("<I4s", d, off)
    off += 8
    bin_ = d[off:off + blen]
    chunks = []
    for m in doc.get("meshes", []):
        for prim in m.get("primitives", []):
            idx = prim.get("attributes", {}).get("COLOR_0")
            if idx is None:
                continue
            acc = doc["accessors"][idx]
            bv = doc["bufferViews"][acc["bufferView"]]
            start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
            n = acc["count"]
            ncomp = 4 if acc["type"] == "VEC4" else 3
            ct = acc["componentType"]
            dt = {5121: np.uint8, 5123: np.uint16, 5126: np.float32}.get(ct)
            if dt is None:
                continue
            arr = np.frombuffer(bin_, dtype=dt, count=n * ncomp,
                                offset=start).reshape(n, ncomp)
            arr = arr[:, :3].astype(np.float64)
            if dt == np.float32 or acc.get("normalized") is False and dt != np.uint8:
                arr *= 255.0
            chunks.append(arr)
    return np.vstack(chunks) if chunks else None


def load_mesh(path: str) -> trimesh.Trimesh:
    scene = trimesh.load(path, force="scene")
    geoms = []
    for node in scene.graph.nodes_geometry:
        transform, geom_name = scene.graph[node]
        g = scene.geometry[geom_name].copy()
        g.apply_transform(transform)
        geoms.append(g)
    if not geoms:
        geoms = list(scene.geometry.values())
    mesh = trimesh.util.concatenate(geoms)
    vc = getattr(mesh.visual, "vertex_colors", None)
    if vc is None or len(vc) != len(mesh.vertices):
        c = _vertex_colors_from_glb(path)
        if c is not None and len(c) == len(mesh.vertices):
            rgba = np.column_stack([np.clip(c, 0, 255), np.full(len(c), 255)])
            mesh.visual = trimesh.visual.ColorVisuals(
                mesh=mesh, vertex_colors=rgba.astype(np.uint8)
            )
    return mesh


def normalize(mesh: trimesh.Trimesh) -> trimesh.Trimesh:
    """居中 + 等比缩放到 [-1, 1]，保证不同模型视角一致。"""
    v = mesh.vertices.copy()
    center = (v.min(0) + v.max(0)) / 2
    v -= center
    scale = float(np.abs(v).max())
    if scale > 0:
        v /= scale
    out = mesh.copy()
    out.vertices = v
    return out


def look_at(eye, target=(0, 0, 0), up=(0, 1, 0)):
    eye = np.asarray(eye, dtype=np.float64)
    f = np.asarray(target, dtype=np.float64) - eye
    f /= np.linalg.norm(f)
    u = np.asarray(up, dtype=np.float64)
    r = np.cross(f, u)
    r /= np.linalg.norm(r)
    u2 = np.cross(r, f)
    # 第三行取 +f（从相机指向物体），这样相机空间 +Z 为视线前方、物体深度为正。
    # 若取 -f 会让 z 全负，投影时除极小值产生天文数字坐标，画面被单个三角形涂满。
    return np.stack([r, u2, f], axis=0)  # (3,3) rows = camera basis


def render(mesh: trimesh.Trimesh, size: int = 420, yaw: float = 35.0,
           pitch: float = 18.0, bg=(248, 249, 252)) -> Image.Image:
    """Z-buffer 光栅化 + Lambert 漫反射 + 顶点色插值。"""
    v = np.asarray(mesh.vertices, dtype=np.float64)
    f = np.asarray(mesh.faces, dtype=np.int32)

    vis = mesh.visual
    vc = getattr(vis, "vertex_colors", None)
    if vc is None or len(vc) != len(v):
        colors = np.full((len(v), 3), 190.0)
    else:
        colors = np.asarray(vc, dtype=np.float64)[:, :3]

    # 相机：绕 Y 轴 yaw，抬高 pitch，看向原点。
    ay, ap = math.radians(yaw), math.radians(pitch)
    dist = 3.6
    eye = np.array([
        dist * math.sin(ay) * math.cos(ap),
        dist * math.sin(ap),
        dist * math.cos(ay) * math.cos(ap),
    ])
    R = look_at(eye)
    cam = (v - eye) @ R.T          # 相机坐标，+Z 朝向物体
    z = cam[:, 2]

    # 透视投影
    focal = 2.2
    px = cam[:, 0] / np.maximum(z, 1e-6) * focal
    py = cam[:, 1] / np.maximum(z, 1e-6) * focal
    sx = (px * 0.5 + 0.5) * size
    sy = (0.5 - py * 0.5) * size

    # 面法线（相机空间）用于光照
    tri = cam[f]
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    ln = np.linalg.norm(n, axis=1)
    ln[ln < 1e-12] = 1.0
    n /= ln[:, None]
    light = np.array([0.35, 0.75, -0.55])
    light /= np.linalg.norm(light)
    # 双面：取绝对值避免背面全黑
    diffuse = 0.42 + 0.58 * np.abs(n @ light)

    frame = np.zeros((size, size, 3), dtype=np.float64)
    frame[:] = np.asarray(bg, dtype=np.float64)
    zbuf = np.full((size, size), np.inf)

    fx0, fy0, fx1, fy1 = sx[f[:, 0]], sy[f[:, 0]], sx[f[:, 1]], sy[f[:, 1]]
    fx2, fy2 = sx[f[:, 2]], sy[f[:, 2]]
    area = (fx1 - fx0) * (fy2 - fy0) - (fy1 - fy0) * (fx2 - fx0)
    valid = np.abs(area) > 1e-9
    zt = z[f].mean(axis=1)

    # 由近到远绘制，减少覆盖计算
    order = np.argsort(zt)
    for i in order:
        if not valid[i]:
            continue
        t = f[i]
        x0, x1, x2 = fx0[i], fx1[i], fx2[i]
        y0, y1, y2 = fy0[i], fy1[i], fy2[i]
        minx = max(0, int(math.floor(min(x0, x1, x2))))
        maxx = min(size - 1, int(math.ceil(max(x0, x1, x2))))
        miny = max(0, int(math.floor(min(y0, y1, y2))))
        maxy = min(size - 1, int(math.ceil(max(y0, y1, y2))))
        if minx > maxx or miny > maxy:
            continue
        xs, ys = np.meshgrid(np.arange(minx, maxx + 1) + 0.5,
                             np.arange(miny, maxy + 1) + 0.5)
        a = area[i]
        w0 = ((x1 - x0) * (ys - y0) - (y1 - y0) * (xs - x0)) / a
        w1 = ((x2 - x1) * (ys - y1) - (y2 - y1) * (xs - x1)) / a
        w2 = ((x0 - x2) * (ys - y2) - (y0 - y2) * (xs - x2)) / a
        # 标准重心：lambda0 = 1 - w1... 这里改用直接公式更稳
        l1 = ((y1 - y2) * (xs - x2) + (x2 - x1) * (ys - y2)) / a
        l2 = ((y2 - y0) * (xs - x2) + (x0 - x2) * (ys - y2)) / a
        l0 = 1.0 - l1 - l2
        inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
        if not inside.any():
            continue
        dep = l0 * z[t[0]] + l1 * z[t[1]] + l2 * z[t[2]]
        sub = zbuf[miny:maxy + 1, minx:maxx + 1]
        mask = inside & (dep < sub)
        if not mask.any():
            continue
        col = (l0[..., None] * colors[t[0]] +
               l1[..., None] * colors[t[1]] +
               l2[..., None] * colors[t[2]])
        col = np.clip(col * diffuse[i], 0, 255)
        dst = frame[miny:maxy + 1, minx:maxx + 1]
        dst[mask] = col[mask]
        sub[mask] = dep[mask]

    return Image.fromarray(frame.astype(np.uint8), "RGB")


def contact_sheet(paths, out: str, size: int = 380, cols: int = 3):
    views = [("front", 0.0, 12.0), ("3/4", 38.0, 18.0), ("side", 90.0, 12.0)]
    rows = len(paths)
    W, H = cols * size, rows * (size + 26)
    sheet = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    for r, p in enumerate(paths):
        try:
            mesh = normalize(load_mesh(p))
        except Exception as e:  # noqa: BLE001
            print(f"[render] skip {p}: {e}")
            continue
        for c, (label, yaw, pitch) in enumerate(views):
            img = render(mesh, size=size, yaw=yaw, pitch=pitch)
            sheet.paste(img, (c * size, r * (size + 26)))
            d.text((c * size + 8, r * (size + 26) + size + 4),
                   f"{os.path.basename(p)}  /  {label}", fill=(30, 33, 40))
        print(f"[render] {p}: {len(mesh.vertices)} verts / {len(mesh.faces)} faces")
    sheet.save(out)
    print(f"[render] saved -> {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--out", default="preview.png")
    ap.add_argument("--size", type=int, default=380)
    ap.add_argument("--cols", type=int, default=3)
    args = ap.parse_args()
    contact_sheet(args.inputs, args.out, size=args.size, cols=args.cols)


if __name__ == "__main__":
    main()
