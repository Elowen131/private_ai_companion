#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SDF 隐式曲面建模引擎 —— 纯 NumPy，零下载 / 零 GPU。

为什么不用「一堆球 + 圆柱硬拼」
--------------------------------
硬拼的部件各自是封闭网格，彼此只是互相穿插：头与脖子、腿与躯干的交接处
一定是一条硬折线（甚至能看到两个球相贯的圆），既不可能「流畅仿真」，
也做不出毛绒动物该有的圆润体块过渡。

这里的做法是：
  1. 每个部件只描述一个**有符号距离场**（椭球 / 胶囊 / 圆角盒）；
  2. 用 log-sum-exp smooth-min 把所有「躯干类」部件融合成**一张连续曲面**，
     头、身、腿、耳、尾之间自然长出圆润的过渡（数学上 C1 连续）；
  3. 颜色同样按距离场做 softmin 加权，毛色交界是渐变而不是色块；
  4. 眼睛 / 鼻子这类需要锐利边界的部件单独走 hard-min，只留极小的融合半径，
     看起来像嵌进毛里而不是贴在表面；
  5. marching tetrahedra 提取等值面，法线直接取 SDF 梯度（比面法线平滑得多）；
  6. 表面按面积撒一层短细绒毛锥 + 绒面噪声顶点色 + glTF sheen 织物材质。

坐标约定：Y 向上，Z 向前（脸朝 +Z），X 左右。SDF 负值 = 物体内部。
"""
from __future__ import annotations

import math

import numpy as np
import trimesh

# 立方体 8 个角点的局部偏移（与 marching tetrahedra 的 6-tet 分解配套）
CORNER = np.array([
    [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
    [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
], dtype=np.int64)

# 把每个立方体切成 6 个四面体（共用对角线 0-6），保证相邻立方体共面一致
TETS = np.array([
    [0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6],
    [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6],
], dtype=np.int64)

# 四面体 4 个顶点之间的 6 条边
EDGES = np.array([
    [0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3],
], dtype=np.int64)


def _hex(s: str) -> np.ndarray:
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], np.float32) / 255.0


def _unit(v, eps: float = 1e-9):
    v = np.asarray(v, np.float64)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, eps)


def _face_normals(verts: np.ndarray, faces: np.ndarray) -> np.ndarray:
    """面法线按面积加权累加到顶点。绒毛这类非 SDF 几何用它。"""
    v = np.asarray(verts, np.float64)
    f = np.asarray(faces, np.int64)
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    out = np.zeros_like(v)
    np.add.at(out, f[:, 0], fn)
    np.add.at(out, f[:, 1], fn)
    np.add.at(out, f[:, 2], fn)
    return _unit(out).astype(np.float32)


def _value_noise(p: np.ndarray, freq: float, seed: int = 0) -> np.ndarray:
    """3D 值噪声（hash lattice + smoothstep 插值），用于绒面毛色斑驳。"""
    q = np.asarray(p, np.float64) * freq
    i = np.floor(q).astype(np.int64)
    t = q - i
    t = t * t * (3.0 - 2.0 * t)

    def hsh(dx, dy, dz):
        x = (i[:, 0] + dx + seed * 17).astype(np.uint32)
        y = (i[:, 1] + dy + seed * 31).astype(np.uint32)
        z = (i[:, 2] + dz + seed * 47).astype(np.uint32)
        h = x * np.uint32(374761393) + y * np.uint32(668265263) + z * np.uint32(1274126177)
        h = (h ^ (h >> np.uint32(13))) * np.uint32(1274126177)
        h = h ^ (h >> np.uint32(16))
        return (h & np.uint32(0xFFFF)).astype(np.float64) / 65535.0

    c000, c100 = hsh(0, 0, 0), hsh(1, 0, 0)
    c010, c110 = hsh(0, 1, 0), hsh(1, 1, 0)
    c001, c101 = hsh(0, 0, 1), hsh(1, 0, 1)
    c011, c111 = hsh(0, 1, 1), hsh(1, 1, 1)
    x, y, z = t[:, 0], t[:, 1], t[:, 2]
    x0 = c000 + (c100 - c000) * x
    x1 = c010 + (c110 - c010) * x
    x2 = c001 + (c101 - c001) * x
    x3 = c011 + (c111 - c011) * x
    y0 = x0 + (x1 - x0) * y
    y1 = x2 + (x3 - x2) * y
    return y0 + (y1 - y0) * z


class SDFShape:
    """带毛色与绒毛权重的隐式曲面。"""

    def __init__(self, blend_k: float = 0.13, detail_k: float = 0.018,
                 color_k: float | None = None):
        self.blend: list[dict] = []
        self.detail: list[dict] = []
        # 五官等精细部件：SDF 网格分辨率有限，小于一个格子的高光/瞳孔会被抹平，
        # 所以身体走融合曲面、五官用高精度球体单独叠加。
        self.extras: list[tuple] = []
        self.fur_exclusions: list[tuple] = []
        self.blend_k = blend_k
        self.detail_k = detail_k
        # 颜色过渡比几何融合更窄，避免胸口白毛和身体毛色糊成一片脏渐变
        self.color_k = color_k if color_k is not None else blend_k * 0.55

    # ------------------------------------------------------------ 部件 API
    def ellipsoid(self, center, radii, color, *, detail=False, rot=None):
        self._add("ellipsoid", detail, color,
                  c=np.asarray(center, np.float64), r=np.asarray(radii, np.float64),
                  rot=None if rot is None else np.asarray(rot, np.float64)[:3, :3])
        return self

    def sphere(self, center, radius, color, *, detail=False):
        return self.ellipsoid(center, (radius,) * 3, color, detail=detail)

    def capsule(self, a, b, radius, color, *, detail=False):
        self._add("capsule", detail, color,
                  a=np.asarray(a, np.float64), b=np.asarray(b, np.float64), r=float(radius))
        return self

    def round_box(self, center, extents, radius, color, *, detail=False):
        self._add("roundbox", detail, color,
                  c=np.asarray(center, np.float64),
                  e=np.asarray(extents, np.float64), r=float(radius))
        return self

    def chain(self, points, radii, color, *, detail=False):
        """一串半径递变的球 —— 用 smooth-min 连成圆润的锥形肢体 / 蓬松尾巴。

        相邻球之间必须补一段胶囊：poly smooth-min 只在距离差 < blend_k 时
        生效，球的间距一旦大于两半径之和就完全不相连，尾巴会断成一串
        浮空小球（第一版猫尾 / 龙尾就栽在这里）。
        """
        pts = np.asarray(points, np.float64)
        rr = np.asarray(radii, np.float64)
        for p, r in zip(pts, rr):
            self.sphere(p, r, color, detail=detail)
        for i in range(len(pts) - 1):
            self.capsule(pts[i], pts[i + 1],
                         float(min(rr[i], rr[i + 1]) * 0.90),
                         color, detail=detail)
        return self

    def extra(self, mesh: trimesh.Trimesh, color, *, exclude_radius: float | None = None):
        """叠加一个高精度部件（眼睛、瞳孔、鼻头、高光、内耳等）。

        [exclude_radius] 内的表面不长绒毛，避免毛刺盖住五官。None 表示不排除。
        """
        c = _hex(color) if isinstance(color, str) else np.asarray(color, np.float32)
        v = np.asarray(mesh.vertices, np.float64).copy()
        f = np.asarray(mesh.faces, np.int64).copy()
        # 不用 mesh.vertex_normals：trimesh 的加权法线走 scipy.sparse，
        # 这个离线 venv 故意没装 scipy。面法线累加对高密度球体等价平滑。
        n = _face_normals(v, f)
        self.extras.append((v, f, c, n.astype(np.float32)))
        if exclude_radius is not None:
            self.fur_exclusions.append((np.asarray(mesh.vertices).mean(0), exclude_radius))
        return self

    def ellipsoid_extra(self, center, radii, color, *, subdivisions=3,
                        exclude_radius: float | None = None, rot=None):
        m = trimesh.creation.icosphere(subdivisions=subdivisions, radius=1.0)
        m.apply_scale(radii)
        if rot is not None:
            R = np.eye(4)
            R[:3, :3] = np.asarray(rot, np.float64)[:3, :3]
            m.apply_transform(R)
        m.apply_translation(center)
        return self.extra(m, color, exclude_radius=exclude_radius)

    def _add(self, kind, detail, color, **params):
        part = {"type": kind, "color": _hex(color) if isinstance(color, str)
                else np.asarray(color, np.float32), **params}
        (self.detail if detail else self.blend).append(part)

    # ------------------------------------------------------------ SDF 计算
    @staticmethod
    def _sdf(points: np.ndarray, part: dict) -> np.ndarray:
        k = part["type"]
        if k == "ellipsoid":
            q = points - part["c"]
            if part.get("rot") is not None:
                q = q @ part["rot"]
            r = part["r"]
            k0 = np.linalg.norm(q / r, axis=1)
            k1 = np.linalg.norm(q / (r * r), axis=1)
            return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)
        if k == "capsule":
            a, b = part["a"], part["b"]
            ba = b - a
            t = np.clip((points - a) @ ba / max(float(ba @ ba), 1e-12), 0.0, 1.0)
            return np.linalg.norm(points - (a + t[:, None] * ba), axis=1) - part["r"]
        if k == "roundbox":
            q = np.abs(points - part["c"]) - (part["e"] / 2.0 - part["r"])
            outside = np.linalg.norm(np.maximum(q, 0.0), axis=1)
            inside = np.minimum(np.maximum.reduce([q[:, 0], q[:, 1], q[:, 2]]), 0.0)
            return outside + inside - part["r"]
        raise ValueError(f"unknown sdf primitive: {k}")

    def eval_field(self, points: np.ndarray, chunk: int = 60000):
        """返回 (signed_distance, [rgb, fur_weight])；分批避免峰值内存过高。"""
        n = len(points)
        ds = np.empty(n, np.float32)
        cs = np.empty((n, 4), np.float32)
        for s in range(0, n, chunk):
            p = points[s:s + chunk]
            m = len(p)
            D = np.stack([self._sdf(p, q) for q in self.blend], axis=1)
            dm = D.min(1)
            # 局部 polynomial smooth-min：只有距离差 < blend_k 的部件才融合。
            # 不能用 log-sum-exp：它的外扩量 ~k*log(部件数)，20 个部件会把
            # 整只动物肿成一坨、四条腿直接粘在一起。
            body_d = D[:, 0].copy()
            k = self.blend_k
            for i in range(1, D.shape[1]):
                a, b = body_d, D[:, i]
                h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
                body_d = b * (1 - h) + a * h - k * h * (1 - h)
            Wc = np.exp(-(D - dm[:, None]) / self.color_k)
            W = Wc / Wc.sum(1, keepdims=True)
            C = np.asarray([q["color"] for q in self.blend], np.float32)
            body_c = W @ C
            final_d = body_d
            fur = np.ones(m, np.float32)

            if self.detail:
                Dd = np.stack([self._sdf(p, q) for q in self.detail], axis=1)
                j = Dd.argmin(1)
                det_d = Dd[np.arange(m), j]
                det_c = np.asarray([q["color"] for q in self.detail], np.float32)[j]
                t = np.clip((body_d - det_d) / max(self.detail_k * 1.6, 1e-6), 0.0, 1.0)
                # poly smooth-min：只在两者距离很近时局部融合，不会把整张脸吸变形
                h = np.maximum(self.detail_k - np.abs(body_d - det_d), 0.0) / self.detail_k
                final_d = np.minimum(body_d, det_d) - h * h * self.detail_k * 0.25
                body_c = body_c * (1.0 - t[:, None]) + det_c * t[:, None]
                fur = 1.0 - t

            ds[s:s + chunk] = final_d
            cs[s:s + chunk, :3] = body_c
            cs[s:s + chunk, 3] = fur
        return ds, cs

    def bounds(self, pad: float = 0.22):
        lo = np.full(3, np.inf)
        hi = np.full(3, -np.inf)
        for q in self.blend + self.detail:
            k = q["type"]
            if k == "ellipsoid":
                a, b = q["c"] - q["r"], q["c"] + q["r"]
            elif k == "capsule":
                a = np.minimum(q["a"], q["b"]) - q["r"]
                b = np.maximum(q["a"], q["b"]) + q["r"]
            else:
                a, b = q["c"] - q["e"] / 2, q["c"] + q["e"] / 2
            lo, hi = np.minimum(lo, a), np.maximum(hi, b)
        return lo - pad, hi + pad

    # ------------------------------------------------------------ 等值面
    def build(self, res: int = 72, fur_count: int = 7000, seed: int = 7,
              fur_length: float = 0.032, fur_radius: float = 0.0085,
              noise_strength: float = 0.11):
        lo, hi = self.bounds()
        step = float((hi - lo).max() / res)
        shape = tuple((np.ceil((hi - lo) / step) + 1).astype(int))
        axes = [lo[i] + np.arange(shape[i]) * step for i in range(3)]
        gx, gy, gz = np.meshgrid(*axes, indexing="ij")
        grid_pts = np.column_stack([gx.ravel(), gy.ravel(), gz.ravel()])
        gd, gc = self.eval_field(grid_pts)
        D = gd.reshape(shape)
        CF = gc.reshape(shape + (4,))
        print(f"  [sdf] grid={shape} active_cubes=", end="")
        verts, faces, colors, normals, furw = self._marching_tetra(D, CF, lo, step)

        # 绒面毛色：多频值噪声让表面有细密、不均匀的绒毛质感
        if noise_strength > 0:
            n1 = _value_noise(verts, 17.0, seed)
            n2 = _value_noise(verts, 41.0, seed + 3)
            n3 = _value_noise(verts, 83.0, seed + 7)
            tex = (n1 - 0.5) * 0.55 + (n2 - 0.5) * 0.30 + (n3 - 0.5) * 0.15
            colors = np.clip(colors * (1.0 + noise_strength * tex[:, None] * 2.2), 0, 1)

        if fur_count > 0:
            fv, ff, fc, fn = self._fur(verts, faces, colors, normals, furw,
                                       fur_count, seed, fur_length, fur_radius,
                                       self.fur_exclusions)
            off = len(verts)
            verts = np.vstack([verts, fv])
            faces = np.vstack([faces, ff + off])
            colors = np.vstack([colors, fc])
            normals = np.vstack([normals, fn])

        # 高精度五官：位置略微嵌入皮肤，只露出球冠，接缝被周围绒毛遮住
        for v, f, c, n in self.extras:
            off = len(verts)
            verts = np.vstack([verts, v])
            faces = np.vstack([faces, f + off])
            colors = np.vstack([colors, np.tile(c, (len(v), 1))])
            normals = np.vstack([normals, n])

        rgba = np.column_stack([
            np.clip(colors * 255.0, 0, 255).astype(np.uint8),
            np.full(len(colors), 255, np.uint8),
        ])
        mesh = trimesh.Trimesh(vertices=verts.astype(np.float32),
                               faces=faces.astype(np.int64), process=False)
        mesh.visual = trimesh.visual.ColorVisuals(mesh=mesh, vertex_colors=rgba)
        print(f"  [sdf] verts={len(verts)} faces={len(faces)}")
        return mesh, normals.astype(np.float32)

    def _marching_tetra(self, D, CF, origin, step):
        nx, ny, nz = D.shape
        ix, iy, iz = np.meshgrid(np.arange(nx - 1), np.arange(ny - 1),
                                 np.arange(nz - 1), indexing="ij")
        ix, iy, iz = ix.ravel(), iy.ravel(), iz.ravel()
        vals = np.stack([D[ix + CORNER[c, 0], iy + CORNER[c, 1], iz + CORNER[c, 2]]
                         for c in range(8)], axis=1).astype(np.float32)
        active = (vals.min(1) < 0) & (vals.max(1) >= 0)
        ix, iy, iz, vals = ix[active], iy[active], iz[active], vals[active]
        M = len(ix)
        print(M, end=" ", flush=True)
        if M == 0:
            raise RuntimeError("SDF 等值面为空：检查部件坐标与包围盒")

        base = np.asarray(origin, np.float64) + np.column_stack([ix, iy, iz]) * step
        pos = base[:, None, :] + CORNER[None, :, :] * step             # (M,8,3)
        cf = np.stack([CF[ix + CORNER[c, 0], iy + CORNER[c, 1], iz + CORNER[c, 2]]
                       for c in range(8)], axis=1)                      # (M,8,4)

        tv = np.take(vals, TETS, axis=1).reshape(-1, 4)                 # (T,4)
        tp = np.take(pos, TETS, axis=1).reshape(-1, 4, 3)               # (T,4,3)
        tc = np.take(cf, TETS, axis=1).reshape(-1, 4, 4)                # (T,4,4)
        T = M * 6

        ea, eb = EDGES[:, 0], EDGES[:, 1]
        va, vb = tv[:, ea], tv[:, eb]
        cross = (va < 0) != (vb < 0)
        tt = np.where(cross, va / (va - vb + 1e-20), 0.0)
        pa, pb = tp[:, ea, :], tp[:, eb, :]
        P = pa + tt[..., None] * (pb - pa)
        ca, cb = tc[:, ea, :], tc[:, eb, :]
        C = ca + tt[..., None] * (cb - ca)

        # 把每条四面体的有效交点按边序挪到前面
        order = np.argsort(~cross, axis=1, kind="stable")
        Ps = np.take_along_axis(P, np.repeat(order[..., None], 3, axis=2), axis=1)
        Cs = np.take_along_axis(C, np.repeat(order[..., None], 4, axis=2), axis=1)
        cnt = cross.sum(1)

        # 外向参考方向：外侧顶点重心 - 内侧顶点重心
        inside = tv < 0
        nin = inside.sum(1)
        nout = 4 - nin
        in_c = (tp * inside[..., None]).sum(1) / np.maximum(nin[:, None], 1)
        out_c = (tp * (~inside)[..., None]).sum(1) / np.maximum(nout[:, None], 1)
        dirv = out_c - in_c

        m3, m4 = cnt == 3, cnt == 4
        tri3, col3, dir3 = Ps[m3][:, :3], Cs[m3][:, :3], dirv[m3]

        Q4, C4, dir4 = Ps[m4][:, :4], Cs[m4][:, :4], dirv[m4]
        if len(Q4):
            o = Q4.mean(1, keepdims=True)
            d = Q4 - o
            nn = _unit(np.cross(d[:, 1] - d[:, 0], d[:, 2] - d[:, 0]))
            u = _unit(d[:, 0])
            v = np.cross(nn, u)
            ang = np.arctan2((d * v[:, None, :]).sum(2), (d * u[:, None, :]).sum(2))
            o2 = np.argsort(ang, axis=1)
            Q4 = np.take_along_axis(Q4, np.repeat(o2[..., None], 3, axis=2), axis=1)
            C4 = np.take_along_axis(C4, np.repeat(o2[..., None], 4, axis=2), axis=1)
            t4 = np.concatenate([
                np.stack([Q4[:, 0], Q4[:, 1], Q4[:, 2]], axis=1),
                np.stack([Q4[:, 0], Q4[:, 2], Q4[:, 3]], axis=1),
            ], axis=0)
            c4 = np.concatenate([
                np.stack([C4[:, 0], C4[:, 1], C4[:, 2]], axis=1),
                np.stack([C4[:, 0], C4[:, 2], C4[:, 3]], axis=1),
            ], axis=0)
            d4 = np.concatenate([dir4, dir4], axis=0)
        else:
            t4 = np.zeros((0, 3, 3)); c4 = np.zeros((0, 3, 4)); d4 = np.zeros((0, 3))

        TRI = np.concatenate([tri3, t4], axis=0)
        COL = np.concatenate([col3, c4], axis=0)
        DIR = np.concatenate([dir3, d4], axis=0)

        fn = np.cross(TRI[:, 1] - TRI[:, 0], TRI[:, 2] - TRI[:, 0])
        flip = (fn * DIR).sum(1) < 0
        TRI[flip] = TRI[flip][:, [0, 2, 1]]
        COL[flip] = COL[flip][:, [0, 2, 1]]
        area = np.linalg.norm(np.cross(TRI[:, 1] - TRI[:, 0],
                                       TRI[:, 2] - TRI[:, 0]), axis=1)
        ok = area > 1e-10
        TRI, COL = TRI[ok], COL[ok]

        # 合并共享顶点：等值面相邻三角形本来共用交点，不合并会让 GLB 膨胀 3 倍
        pf = TRI.reshape(-1, 3)
        cf4 = COL.reshape(-1, 4)
        key = np.round(np.column_stack([pf, cf4[:, :3] * 63.0, cf4[:, 3]]), 4).astype(np.float32)
        _, inv = np.unique(key, axis=0, return_inverse=True)
        faces = inv.reshape(-1, 3)
        keep = ((faces[:, 0] != faces[:, 1]) & (faces[:, 1] != faces[:, 2]) &
                (faces[:, 0] != faces[:, 2]))
        faces = faces[keep]
        rep = np.full(len(_), np.iinfo(np.int64).max, np.int64)
        np.minimum.at(rep, inv, np.arange(len(inv), dtype=np.int64))
        verts = pf[rep]
        colors = cf4[rep, :3]
        furw = cf4[rep, 3]

        # 法线直接取 SDF 梯度：比面法线平滑得多，是「连接处流畅」的关键
        eps = step * 0.55
        grad = []
        for ax in range(3):
            off = np.zeros_like(verts)
            off[:, ax] = eps
            dp, _ = self.eval_field(verts + off)
            dn, _ = self.eval_field(verts - off)
            grad.append((dp - dn) / (2 * eps))
        normals = _unit(np.stack(grad, axis=1)).astype(np.float32)
        return verts, faces, colors, normals, furw

    @staticmethod
    def _fur(verts, faces, colors, normals, furw, count, seed, length, radius,
             exclusions):
        """沿表面法线撒短细绒毛锥：轮廓毛茸茸、表面有细密绒感。"""
        rng = np.random.default_rng(seed)
        tri = verts[faces]
        area = 0.5 * np.linalg.norm(np.cross(tri[:, 1] - tri[:, 0],
                                             tri[:, 2] - tri[:, 0]), axis=1)
        cum = np.cumsum(area)
        if cum[-1] <= 0:
            raise RuntimeError("表面面积为 0，无法生成绒毛")
        cum /= cum[-1]
        fi = np.searchsorted(cum, rng.random(count)).clip(0, len(faces) - 1)
        u, v = rng.random(count), rng.random(count)
        s = np.sqrt(u)
        w0, w1, w2 = (1 - s)[:, None], (s * (1 - v))[:, None], (s * v)[:, None]
        P = w0 * tri[fi, 0] + w1 * tri[fi, 1] + w2 * tri[fi, 2]
        N = _unit(w0 * normals[faces[fi, 0]] +
                  w1 * normals[faces[fi, 1]] +
                  w2 * normals[faces[fi, 2]])
        C = (w0 * colors[faces[fi, 0]] + w1 * colors[faces[fi, 1]] +
             w2 * colors[faces[fi, 2]])
        F = (w0.ravel() * furw[faces[fi, 0]] + w1.ravel() * furw[faces[fi, 1]] +
             w2.ravel() * furw[faces[fi, 2]])
        m = rng.random(count) < np.clip(F * 0.96, 0, 1)
        # 五官附近清出一块无毛区，避免绒毛盖住眼睛/鼻头
        for center, rad in exclusions:
            m &= np.linalg.norm(P - np.asarray(center), axis=1) > rad
        P, N, C = P[m], N[m], C[m]
        K = len(P)
        if K == 0:
            return (np.zeros((0, 3)), np.zeros((0, 3), np.int64),
                    np.zeros((0, 3)), np.zeros((0, 3)))

        tmp = np.tile(np.array([0.0, 1.0, 0.0]), (K, 1))
        tmp[np.abs(N[:, 1]) > 0.92] = np.array([1.0, 0.0, 0.0])
        t1 = _unit(np.cross(N, tmp))
        t2 = np.cross(N, t1)
        # 毛流：略向后（-Z）与向下，模拟顺毛方向；再叠随机扰动
        flow = np.column_stack([np.zeros(K), np.full(K, -0.10), np.full(K, -0.16)])
        jitter = (rng.normal(0, 0.28, (K, 1)) * t1 +
                  rng.normal(0, 0.28, (K, 1)) * t2)
        D = _unit(N + jitter + flow)
        # 绝大多数是贴体的短绒，极少数略长用来打破轮廓的完美圆弧。
        # 绒毛越长越粗、颜色越偏离底色，就越像「刺」而不是「毛」。
        long = rng.random(K) < 0.08
        L = length * (0.62 + 0.62 * rng.random(K)) * np.where(long, 1.45, 1.0)
        R = radius * (0.70 + 0.60 * rng.random(K))
        base = P + N * 0.0015
        tip = base + D * L[:, None]
        ang = rng.uniform(0, 2 * np.pi, (K, 1)) + np.array([0, 2 * np.pi / 3, 4 * np.pi / 3])
        ring = (base[:, None, :] + R[:, None, None] *
                (np.cos(ang)[..., None] * t1[:, None, :] +
                 np.sin(ang)[..., None] * t2[:, None, :]))
        V = np.concatenate([ring, tip[:, None, :]], axis=1).reshape(-1, 3)
        FV = (np.array([[0, 1, 3], [1, 2, 3], [2, 0, 3]], np.int64)[None, :, :] +
              4 * np.arange(K)[:, None, None]).reshape(-1, 3)
        shade = (0.95 + 0.10 * rng.random(K))[:, None]
        VC = np.empty((K, 4, 3))
        VC[:, :3, :] = np.clip(C[:, None, :] * shade[:, None, :], 0, 1)
        VC[:, 3, :] = np.clip(C * 1.05, 0, 1)
        # 绒毛法线继承所在表面的法线，而不是细锥侧面的几何法线。
        # 否则每根锥的侧面在漫反射下都是背光面，会渲染成一粒粒黑芝麻
        # （刺猬观感）；用表面法线后颜色与底色一致，只在轮廓留下柔软细绒。
        FN = np.repeat(N[:, None, :], 4, axis=1)
        return (V, FV, VC.reshape(-1, 3),
                FN.reshape(-1, 3).astype(np.float32))
