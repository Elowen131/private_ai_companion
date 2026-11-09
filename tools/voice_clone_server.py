#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
私人 AI 陪伴 · 自托管声音克隆 / 视频抽音轨服务（参考实现，仅用 Python 标准库）。

它在你自己的机器 / 内网跑，干两件事：

1) 视频抽音轨（对应 App 端 `VideoAudioExtractor` / `SelfHostedVideoExtractor`）
   App 上传一段视频，本服务用系统 `ffmpeg` 把视频解封装、只留音轨、
   重采样成 16k 单声道 WAV 回传。这样端上**不必内置 ffmpeg**，APK 依旧精简、
   离线优先——重活留给用户自有设施。

2) 转发到 CosyVoice 做 zero-shot 推理
   `POST /inference_zero_shot` 与 App 端的 `HttpVoiceCloneClient`（自建 / CosyVoice 兼容）
   协议一致：tts_text / prompt_text / speed + 一段样本（音频或视频）。
   若样本是视频，本服务先抽音轨再转发，于是「用一段视频也能克隆出他/她的声音」。

依赖
----
* 仅标准库。但本机需要：
  - `ffmpeg`（抽音轨用，绝大多数系统自带或一键安装）；
  - 可选的 CosyVoice / CosyVoice2 服务（由环境变量 COSYVOICE_URL 指向）。
    不配 COSYVOICE_URL 时，/extract_audio 仍可用，/inference_zero_shot 会明确报错。

用法
----
    pip 不需要。直接：
    python tools/voice_clone_server.py --host 0.0.0.0 --port 50000

    # 指向你自己的 CosyVoice：
    COSYVOICE_URL=http://127.0.0.1:9880 python tools/voice_clone_server.py

App 侧
------
设置 → 声音克隆 → 自建（CosyVoice 兼容），地址填 http://<本机IP>:50000。
之后在「角色声音」里上传视频，会先被抽音轨再克隆。

安全说明
------
* 仅在你信任的内网 / 本机使用：它会把样本交给本机 ffmpeg 与 CosyVoice，不做鉴权。
* 不对外暴露，避免把声音样本泄露到公网。
"""

import json
import os
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def _read_body(handler) -> bytes:
    length = int(handler.headers.get("Content-Length", "0"))
    return handler.rfile.read(length) if length > 0 else b""


def _extract_audio(video_bytes: bytes, ar: int = 16000, ac: int = 1) -> bytes:
    """用系统 ffmpeg 把视频/音频字节转成 16k 单声道 WAV 字节。"""
    if not _has_ffmpeg():
        raise RuntimeError(
            "本机没有 ffmpeg：视频抽音轨需要它。请先安装 ffmpeg（apt/brew/官网）。"
        )
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "src.bin")
        with open(src, "wb") as f:
            f.write(video_bytes)
        out = os.path.join(td, "out.wav")
        # -vn 丢掉画面；-ac 1 单声道；-ar 16000 采样率；一次性转码为 WAV。
        proc = subprocess.run(
            [
                "ffmpeg", "-y", "-i", src, "-vn",
                "-ac", str(ac), "-ar", str(ar), out,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0 or not os.path.exists(out):
            err = proc.stderr.decode("utf-8", "ignore")
            raise RuntimeError("ffmpeg 抽音轨失败：\n" + err[-800:])
        with open(out, "rb") as f:
            return f.read()


def _build_multipart(fields: dict, file_field: str, file_name: str,
                     file_bytes: bytes, ctype: str = "audio/wav") -> tuple:
    """手工拼一个 multipart/form-data 体（标准库无 requests 时的兜底）。"""
    boundary = "----privai_companion_boundary"
    parts = []
    for k, v in fields.items():
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
        parts.append(f"{v}\r\n".encode())
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="{file_field}"; '
        f'filename="{file_name}"\r\n'.encode()
    )
    parts.append(f"Content-Type: {ctype}\r\n\r\n".encode())
    parts.append(file_bytes)
    parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    return body, f"multipart/form-data; boundary={boundary}"


def _proxy_to_cosyvoice(audio_bytes: bytes, query: dict) -> bytes:
    """把样本（已抽好的音轨）连同文本参数转发给 CosyVoice。"""
    url = os.environ.get("COSYVOICE_URL")
    if not url:
        raise RuntimeError(
            "没有配置 COSYVOICE_URL：视频/音频克隆需要指向一个 CosyVoice 服务。"
        )
    fields = {
        "tts_text": query.get("tts_text", ""),
        "prompt_text": query.get("prompt_text", ""),
        "speed": query.get("speed", "1.0"),
    }
    # 把速度限制到 CosyVoice 的合法区间，避免把野值甩过去。
    try:
        sp = float(fields["speed"])
        fields["speed"] = str(max(0.5, min(2.0, sp)))
    except ValueError:
        fields["speed"] = "1.0"
    body, ctype = _build_multipart(
        fields, "prompt_wav", "prompt.wav", audio_bytes
    )
    req = urllib.request.Request(
        url.rstrip("/") + "/inference_zero_shot", data=body,
        headers={"Content-Type": ctype}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"CosyVoice 返回 {e.code}：{e.read().decode('utf-8', 'ignore')[:400]}")
    except Exception as e:  # noqa: BLE001 - 把远端错转成人话回给 App
        raise RuntimeError(f"连不上 CosyVoice：{e}")


class _Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str = "application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj) -> bytes:
        return json.dumps(obj, ensure_ascii=False).encode("utf-8")

    def do_GET(self):
        if self.path.split("?")[0] in ("/", "/health"):
            self._send(200, self._json({"ok": True, "ffmpeg": _has_ffmpeg()}))
            return
        self._send(404, self._json({"error": "not found"}))

    def do_POST(self):
        try:
            path = self.path.split("?")[0]
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            text = lambda k: (q.get(k, [""])[0])
            body = _read_body(self)

            if path == "/extract_audio":
                if not body:
                    self._send(400, self._json({"error": "empty body"}))
                    return
                audio = _extract_audio(body)
                self._send(200, audio, "audio/wav")
                return

            if path == "/inference_zero_shot":
                if not body:
                    self._send(400, self._json({"error": "empty prompt"}))
                    return
                # 样本可能是视频（先抽音轨）或已是音频（直接转 WAV 保险）。
                audio = _extract_audio(body)
                out = _proxy_to_cosyvoice(
                    audio,
                    {
                        "tts_text": text("tts_text"),
                        "prompt_text": text("prompt_text"),
                        "speed": text("speed"),
                    },
                )
                self._send(200, out, "audio/wav")
                return

            self._send(404, self._json({"error": "unknown endpoint"}))
        except RuntimeError as e:
            self._send(422, self._json({"error": str(e)}))
        except Exception as e:  # noqa: BLE001
            self._send(500, self._json({"error": f"server error: {e}"}))

    def log_message(self, *args):  # 安静一点
        pass


def main():
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=50000)
    args = ap.parse_args()
    print(f"[voice_clone_server] http://{args.host}:{args.port}  "
          f"ffmpeg={'yes' if _has_ffmpeg() else 'NO'}")
    print(f"[voice_clone_server] COSYVOICE_URL={os.environ.get('COSYVOICE_URL', '(未配置)')}")
    ThreadingHTTPServer((args.host, args.port), _Handler).serve_forever()


if __name__ == "__main__":
    main()
