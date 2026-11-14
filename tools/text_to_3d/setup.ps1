<#
.SYNOPSIS
    路线 C 本地文生 3D 环境一键搭建（Windows / PowerShell）。
.DESCRIPTION
    - 在 tools/text_to_3d/.venv 建独立 venv（用本脚本所在目录，无需 cd 到项目根）
    - 安装 torch：若 wheels/ 下有匹配本机 Python 版本的本地 wheel 直接用（离线、秒装）；
      否则从 PyTorch CPU 源拉取（避免默认装 2.6GB 的 CUDA 版）
    - 安装 diffusers / transformers / accelerate / trimesh（高超时 + 重试，抗弱网）
    - 可选 -DownloadWeights：预拉取 Shap-E 权重（hf-mirror，可断点续传）
.NOTES
    运行：  powershell -ExecutionPolicy Bypass -File tools/text_to_3d/setup.ps1
    或直接在该文件上右键“用 PowerShell 运行”。
#>
param(
    [switch]$DownloadWeights
)

$ErrorActionPreference = "Stop"
$Root  = $PSScriptRoot                                   # = tools/text_to_3d
$Venv  = Join-Path $Root ".venv"
$Py    = Join-Path $Venv "Scripts/python.exe"
$Pip   = Join-Path $Venv "Scripts/pip.exe"
$Prefetch = Join-Path $Root "prefetch.py"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }

# 安装依赖：默认 PyPI 失败（弱网/超时）时自动回退到清华镜像，提升国内成功率。
function Install-Pkgs($pkgs) {
    $sources = @("", "https://pypi.tuna.tsinghua.edu.cn/simple")
    foreach ($src in $sources) {
        $a = @("--default-timeout","600","--retries","20")
        $label = "默认 PyPI"
        if ($src) { $a += @("-i",$src); $label = $src }
        Write-Host "    - 通过 $label 安装..." -ForegroundColor Gray
        & $Pip @a
        if ($LASTEXITCODE -eq 0) { return }
        Write-Warn "该源安装失败，尝试下一个源..."
    }
}

# ---------------------------------------------------------------------------
# 自检：本脚本必须与 server.py 同目录（即 tools/text_to_3d/）
$serverPy = Join-Path $Root "server.py"
Write-Host "脚本位置 : $Root" -ForegroundColor White
Write-Host "目标 venv : $Venv" -ForegroundColor White
if (-not (Test-Path $serverPy)) {
    Write-Warn "同目录未找到 server.py —— 你很可能运行了错误位置的副本。"
    Write-Warn "请回到项目根目录（含 tools/ 的那一层）再运行，或直接右键本文件『用 PowerShell 运行』。"
    exit 1
}

Write-Step "1) 创建虚拟环境"
if (Test-Path $Py) {
    Write-Ok "venv 已存在：$Venv"
}
else {
    # 用系统 python 建 venv；若系统没有 python，这里会直接报错并给出提示。
    & python -m venv $Venv
    if (-not (Test-Path $Py)) {
        Write-Warn "未找到系统 python。请先安装 Python 3.12（https://www.python.org）并勾选 'Add to PATH'。"
        exit 1
    }
    Write-Ok "venv 已创建"
}

# 取 venv 内 Python 的版本号（如 312 / 313），用于匹配本地 wheel。
$pyver = & $Py -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')"
Write-Ok "venv Python 版本标签 cp$pyver"

# ---------------------------------------------------------------------------
Write-Step "2) 安装 torch"
$localWheel = Get-ChildItem -Path (Join-Path $Root "wheels") -Filter "torch-*-cp${pyver}-*.whl" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($localWheel) {
    Write-Ok "发现匹配本地 wheel：$($localWheel.Name)，离线安装"
    & $Pip install --default-timeout 600 --retries 20 $localWheel.FullName
}
else {
    Write-Warn "wheels/ 下没有 cp${pyver} 的本地 torch wheel，改从 PyTorch CPU 源拉取（约 190MB，弱网下较慢）。"
    & $Pip install --default-timeout 600 --retries 20 torch --index-url https://download.pytorch.org/whl/cpu
}

# ---------------------------------------------------------------------------
Write-Step "3) 安装其余依赖（diffusers / transformers / accelerate / trimesh）"
Install-Pkgs @("diffusers","transformers","accelerate","trimesh")
if ($LASTEXITCODE -ne 0) {
    Write-Warn "依赖安装失败（多为网络超时）。可重试本脚本，或手动："
    Write-Warn "  $Pip install --default-timeout 600 --retries 20 diffusers transformers accelerate trimesh"
    exit $LASTEXITCODE
}
Write-Ok "依赖安装完成"

# ---------------------------------------------------------------------------
if ($DownloadWeights) {
    Write-Step "4) 预拉取 Shap-E 权重（openai/shap-e，fp16，来自 hf-mirror，可断点续传）"
    $env:HF_ENDPOINT = "https://hf-mirror.com"
    $env:NO_PROXY    = "127.0.0.1,localhost,::1"
    & $Py $Prefetch
    Write-Ok "权重已缓存"
}

# ---------------------------------------------------------------------------
Write-Step "完成 ✅ 下一步"
Write-Host "  启动服务：" -ForegroundColor White
Write-Host "    $Py $serverPy" -ForegroundColor Gray
Write-Host "  手机接线（二选一）：" -ForegroundColor White
Write-Host "    a) USB + adb：  adb reverse tcp:8765 tcp:8765   （服务保持默认 127.0.0.1）" -ForegroundColor Gray
Write-Host "    b) 同 Wi-Fi：   用 --host 0.0.0.0 启动，App 内填  http://<电脑局域网IP>:8765" -ForegroundColor Gray
Write-Host "  详细文档见 tools/text_to_3d/README.md" -ForegroundColor Gray
