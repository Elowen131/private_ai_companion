#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
私人 AI 陪伴 · 自托管 GGUF 下载源（参考实现，零依赖，仅用 Python 标准库）。

为什么需要它
------------
App 端侧模型**外置下载、不打进 APK**（方案 9 / 11）。本脚本在你自己的机器 / 内网
起一个合规的下载源：自动按目录生成 `manifest.json`（含每个文件的 SHA-256），并支持
HTTP Range 断点续传，正好对接 App 侧 `ModelSource` + `ModelDownloader`。

用法
----
    # 把你的 GGUF / ONNX 模型放进 ./gguf_models，然后：
    python tools/gguf_server.py --dir ./gguf_models --host 0.0.0.0 --port 8080

    # 带鉴权的私有源（App 侧在「添加自托管源」里填同样的 Token）：
    python tools/gguf_server.py --dir ./gguf_models --token YOUR_TOKEN

App 侧
------
1. 设置 → 模型源与下载 → 添加自托管源
2. 名称随便（如「我的 NAS」），根地址填 http://<本机IP>:8080
3. 若设了 --token，Token 一栏填同样的值
4. 展开源即可看到 manifest 中的模型，点下载（支持断点续传 + SHA256 校验）

manifest 约定（与 lib/core/model/model_manifest.dart 对齐）
---------------------------------------------------------
GET /manifest.json ->
{
  "name": "...",
  "models": [
    {"id","name","kind","fileName","url","sizeBytes","sha256","description"}
  ]
}
其中 url 缺省时由 App 侧拼为 <baseUrl>/models/<fileName>。

安全说明（后端加固）
--------------------
* 只服务模型目录内的普通文件：URL 先解码再 realpath 校验，符号链接指向目录外会被拒绝。
* Bearer Token 只从 Authorization 头读取（不再接受 ?token=，避免凭据进 URL/日志），
  使用 hmac.compare_digest 常量时间比较。
* Range 按 RFC 7233 处理：后缀范围、越界/倒序范围一律 416，杜绝负 Content-Length。
* manifest 的 SHA-256 按 (路径, mtime_ns, size) 缓存，避免几 GB 模型每次请求全量重算。
"""

from __future__ import annotations  # 兼容 Python 3.8/3.9 的 `str | None` 注解

import argparse
import functools
import hashlib
import hmac
import html
import json
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlparse

CHUNK = 1 << 16  # 64KB
MAX_MANIFEST_FILES = 4096  # 防止目录被塞满时 manifest 请求耗尽资源


def kind_of(filename: str) -> str:
    lower = filename.lower()
    if lower.endswith(".gguf"):
        return "llm"
    if lower.endswith(".onnx"):
        # 仅按扩展名无法区分 embedding/tts，默认 embedding；可用 meta.json 覆盖
        return "embedding"
    if lower.endswith((".bin", ".pt", ".safetensors")):
        return "diffusion"
    return "llm"


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


@functools.lru_cache(maxsize=512)
def cached_sha256(path: str, mtime_ns: int, size: int) -> str:
    """按文件指纹缓存哈希：模型不变时，重复请求 manifest 不再全盘扫描几 GB 数据。"""
    return sha256_of(path)


SHA_LINE = re.compile(r"^([0-9a-f]{64})\s+(\d+)\s+(\d+)$")


def sha_for_file(full: str, st: os.stat_result) -> str:
    """返回模型 SHA-256，并把结果连同 (mtime_ns, size) 指纹写进 `.sha256` 边车文件。

    进程内 lru_cache 只能省掉同一进程里的重复计算：服务重启后，几十 GB 的模型
    目录仍要在第一次 manifest 请求时全量重算，App 侧 15s 超时必失败。边车文件
    让哈希跨重启复用；指纹不匹配（模型被替换）时自动重算。
    """
    sidecar = full + ".sha256"
    if os.path.isfile(sidecar):
        try:
            with open(sidecar, encoding="ascii", errors="ignore") as f:
                m = SHA_LINE.match(f.read().strip())
            if m and int(m.group(2)) == st.st_mtime_ns and int(m.group(3)) == st.st_size:
                return m.group(1)
        except (OSError, ValueError):
            pass
    digest = cached_sha256(full, st.st_mtime_ns, st.st_size)
    try:
        tmp = sidecar + ".tmp"
        with open(tmp, "w", encoding="ascii") as f:
            f.write(f"{digest} {st.st_mtime_ns} {st.st_size}\n")
        os.replace(tmp, sidecar)
    except OSError:
        # 只读模型目录也能正常工作，只是每次启动要重算。
        pass
    return digest


def read_meta(root: str) -> dict:
    path = os.path.join(root, "meta.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def is_metadata_file(name: str) -> bool:
    """清单文件 / 侧车元数据不对外提供下载。"""
    return name in ("manifest.json", "meta.json") or name.endswith(
        (".sha256", ".tmp", ".part")
    )


def build_manifest(root: str, base_url: str, name: str) -> dict:
    models = []
    overrides = read_meta(root)
    for entry in sorted(os.listdir(root)):
        full = os.path.join(root, entry)
        if not os.path.isfile(full) or is_metadata_file(entry):
            continue
        if entry.startswith("."):
            continue
        try:
            st = os.stat(full)
        except OSError:
            continue
        m = overrides.get(entry, {})
        if not isinstance(m, dict):
            m = {}
        sha = sha_for_file(full, st)
        url = m.get("url") or (base_url.rstrip("/") + "/models/" + quote(entry))
        models.append(
            {
                "id": entry,
                "name": m.get("name", entry),
                "kind": m.get("kind", kind_of(entry)),
                "fileName": entry,
                "url": url,
                "sizeBytes": st.st_size,
                "sha256": sha,
                "description": m.get("description", f"{entry}（本地自托管）"),
            }
        )
        if len(models) >= MAX_MANIFEST_FILES:
            break
    return {"name": name, "models": models}


class Handler(BaseHTTPRequestHandler):
    server_version = "GGUF-SelfHost/1.1"
    # 空闲连接超时；配合 daemon_threads 避免慢速连接堆积线程。
    timeout = 30

    # ---- 鉴权 ----
    def _authorized(self) -> bool:
        token = getattr(self.server, "token", None)
        if not token:
            return True
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {token}"
        # 常量时间比较，避免逐字节时序侧信道。
        return auth.startswith("Bearer ") and hmac.compare_digest(auth, expected)

    def _deny(self):
        body = b"unauthorized"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Bearer realm="gguf"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _safe_path(self, rel: str) -> str | None:
        """把 URL 路径解析为目录内的真实路径，拒绝穿越与符号链接逃逸。"""
        root = self.server.root  # 已是 realpath
        rel = unquote(rel.split("?", 1)[0]).lstrip("/")
        if rel.startswith("models/"):
            rel = rel[len("models/") :]
        rel = rel.replace("\\", "/")
        if not rel or rel.startswith("."):
            return None
        parts = rel.split("/")
        if any(p in ("", ".", "..") or p.startswith(".") for p in parts):
            return None
        full = os.path.realpath(os.path.join(root, *parts))
        if not (full == root or full.startswith(root + os.sep)):
            return None
        return full

    def do_GET(self):
        self._handle(head=False)

    def do_HEAD(self):
        self._handle(head=True)

    def _handle(self, head: bool):
        if not self._authorized():
            self._deny()
            return
        path = urlparse(self.path).path

        if path.rstrip("/") in ("/manifest.json", "/manifest"):
            data = json.dumps(
                build_manifest(self.server.root, self.server.base_url, self.server.name),
                ensure_ascii=False,
                indent=2,
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            if not head:
                self._write(data)
            return

        if path.rstrip("/") in ("", "/"):
            self._serve_index(head)
            return

        full = self._safe_path(path)
        if (
            full is None
            or not os.path.isfile(full)
            or is_metadata_file(os.path.basename(full))
        ):
            self.send_error(404, "not found")
            return
        self._serve_file(full, head)

    def _write(self, data: bytes) -> bool:
        try:
            self.wfile.write(data)
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    def _serve_index(self, head: bool = False):
        manifest = build_manifest(self.server.root, self.server.base_url, self.server.name)
        lines = ["<h2>GGUF 自托管源</h2><ul>"]
        for m in manifest["models"]:
            # 文件名来自磁盘，直接插入 HTML 会形成存储型 XSS。
            safe_name = html.escape(str(m["fileName"]))
            href = "/models/" + quote(str(m["fileName"]))
            lines.append(
                f'<li><a href="{html.escape(href)}">{safe_name}</a> '
                f'({m["sizeBytes"]/1e9:.2f} GB, {html.escape(str(m["kind"]))})</li>'
            )
        lines.append('</ul><p>manifest: <a href="/manifest.json">/manifest.json</a></p>')
        body = ("<html><body>" + "".join(lines) + "</body></html>").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            self._write(body)

    @staticmethod
    def _parse_range(value: str | None, size: int) -> tuple[int, int] | None:
        """返回 (start, end)；None 表示范围不合法，应回 416。"""
        if value is None:
            return (0, size - 1)
        if "," in value:  # 不支持多段范围
            return None
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
        if not m:
            return None
        g1, g2 = m.group(1), m.group(2)
        if not g1 and not g2:
            return None
        if not g1:  # suffix range: bytes=-N
            n = int(g2)
            if n <= 0:
                return None
            start, end = max(0, size - n), size - 1
        else:
            start = int(g1)
            end = int(g2) if g2 else size - 1
            end = min(end, size - 1)
        if size <= 0 or start >= size or start > end:
            return None
        return (start, end)

    def _serve_file(self, full: str, head: bool = False):
        with open(full, "rb") as f:
            # 用已打开句柄的 fstat 结果，避免 getsize 与 open 之间文件被替换（TOCTOU）。
            size = os.fstat(f.fileno()).st_size
            rng = self.headers.get("Range")
            parsed = self._parse_range(rng, size)
            if parsed is None:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = parsed
            partial = rng is not None
            length = end - start + 1

            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            if head:
                return

            f.seek(start)
            remaining = length
            while remaining > 0:
                buf = f.read(min(CHUNK, remaining))
                if not buf:
                    break
                if not self._write(buf):
                    break
                remaining -= len(buf)

    def log_message(self, fmt, *args):  # 静默常规日志，避免 Token / 路径进日志
        if os.environ.get("GGUF_VERBOSE"):
            super().log_message(fmt, *args)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def advertised_host(bind_host: str, override: str | None) -> str:
    """绑定 0.0.0.0 时，manifest 里的 url 不能再写 0.0.0.0（客户端连不上）。"""
    if override:
        return override
    if bind_host not in ("0.0.0.0", "::", ""):
        return bind_host
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))  # UDP connect 不实际发包，仅取本机出口 IP
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return "127.0.0.1"


def main():
    ap = argparse.ArgumentParser(description="自托管 GGUF 下载源（参考实现）")
    ap.add_argument("--dir", default="./gguf_models", help="模型目录（不存在则创建）")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--name", default="我的自托管源")
    ap.add_argument("--token", default=None, help="可选 Bearer Token 鉴权")
    ap.add_argument(
        "--advertise-host",
        default=None,
        help="写进 manifest 的主机名/IP（默认自动探测；公网部署请显式指定）",
    )
    args = ap.parse_args()

    root = os.path.realpath(os.path.abspath(args.dir))
    os.makedirs(root, exist_ok=True)
    host = advertised_host(args.host, args.advertise_host)
    base_url = f"http://{host}:{args.port}"
    if ":" in host and not host.startswith("["):
        base_url = f"http://[{host}]:{args.port}"

    httpd = Server((args.host, args.port), Handler)
    httpd.root = root
    httpd.base_url = base_url
    httpd.name = args.name
    httpd.token = args.token

    print(f"[gguf-server] 根目录:   {root}")
    print(f"[gguf-server] 监听:     {args.host}:{args.port}")
    print(f"[gguf-server] 对外地址: {base_url}  (manifest: {base_url}/manifest.json)")
    if args.token:
        print("[gguf-server] 鉴权:     已启用 Bearer Token（仅 Authorization 头）")
    else:
        print("[gguf-server] ⚠ 未启用鉴权且监听所有网卡，建议仅在内网使用或加 --token")
    print("[gguf-server] 把模型文件放进上面的目录即可，Ctrl+C 退出。")
    print("[gguf-server] 首次生成 manifest 需计算 SHA-256，结果写入 .sha256 边车文件，")
    print("[gguf-server] 之后重启直接复用；替换模型后会自动重算。")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[gguf-server] 已停止。")
        sys.exit(0)


if __name__ == "__main__":
    main()
