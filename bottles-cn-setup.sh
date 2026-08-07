#!/usr/bin/env bash
#
# bottles-cn-setup.sh — Bottles 通用初始化脚本（面向国内 Windows 软件）
#
# 用途：为新创建的 Bottles 容器安装完整的中文 Windows 软件依赖链
# 适用：微信、QQ、腾讯会议、网易云音乐、B站客户端、MCStudio 等
#
# 原理：
#   1. Bottles bottle 默认带 Wine Mono，.NET/WPF 应用会崩溃
#      标准修法：winetricks remove_mono -> dotnet48
#   2. Wine Mono 伪造注册表 Release=533320，让 .NET 4.8 安装器误判"已安装"
#      所以必须先 remove_mono
#   3. 中文软件常见依赖：.NET 4.8 + VC++ + 字体 + GDI+ + RichEdit + 输入法
#   4. 字体用 fonttools 改内部名（DirectWrite 兼容，解决"口口口"）
#
# 用法:
#   bottles-cn-setup.sh                          交互式菜单
#   bottles-cn-setup.sh --bottle-name MyApp      指定 bottle 名称
#   bottles-cn-setup.sh --check                  只诊断
#   bottles-cn-setup.sh --preset game|office|common|full   应用预设方案
#   bottles-cn-setup.sh --full                   一键完整初始化
#   bottles-cn-setup.sh --common-deps            安装通用中文依赖链
#   bottles-cn-setup.sh --full-deps              安装完整依赖链（游戏/专业软件）
#   bottles-cn-setup.sh --install-runner         下载 Wine-GE
#   bottles-cn-setup.sh --create-bottle          创建 bottle
#   bottles-cn-setup.sh --fix-rendering          修复 WPF 渲染黑屏（可选）
#   bottles-cn-setup.sh --install-fonts          安装中文字体
#   bottles-cn-setup.sh --setup-ime              配置输入法
#   bottles-cn-setup.sh --scale 1.5              设置缩放
#   bottles-cn-setup.sh --install-host-deps      安装脚本宿主依赖
#
set -euo pipefail

# ==================== 配置 ====================
BOTTLES_DATA="${BOTTLES_DATA:-$HOME/.local/share/bottles}"
BOTTLE_NAME="${BOTTLE_NAME:-MCS}"
BOTTLE_ARCH="${BOTTLE_ARCH:-win64}"
BOTTLE_ENV="${BOTTLE_ENV:-application}"
RUNNER_NAME="${RUNNER_NAME:-}"

PREFIX="$BOTTLES_DATA/bottles/$BOTTLE_NAME"
APP_SCALE="${APP_SCALE:-auto}"  # auto 表示根据显示器分辨率自动计算
THEME_MODE="${THEME_MODE:-auto}"  # auto/dark/light
USER_CACHE="${USER_CACHE:-$HOME/.cache}"

# Wine-GE 运行器下载
WINE_GE_REPO="${WINE_GE_REPO:-GloriousEggroll/wine-ge-custom}"
GH_MIRRORS="${GH_MIRRORS:-https://gh-proxy.com https://mirror.ghproxy.com}"

# 安装包下载地址与 sha256
DOTNET40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
DOTNET40_SHA="65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
DOTNET48_URL="https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
DOTNET48_SHA="95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"
VCRUN2022_X86_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
VCRUN2022_X86_SHA="0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64"
VCRUN2022_X64_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VCRUN2022_X64_SHA="cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"

# ==================== 小工具 ====================
info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "缺少工具: $1"; }

# ==================== Wine-GE 运行器 ====================
has_usable_runner() {
    local runners_dir="$BOTTLES_DATA/runners"
    [ -d "$runners_dir" ] || return 1
    local r=""
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        [ -x "$runners_dir/$r/bin/wine" ] && return 0
    done
    return 1
}

download_wine_ge() {
    local runners_dir="$BOTTLES_DATA/runners"
    mkdir -p "$runners_dir"

    local api_url="https://api.github.com/repos/$WINE_GE_REPO/releases/latest"
    info "查询 Wine-GE 最新版本..."
    local release_info tag_name download_url
    release_info="$(curl -sfL "$api_url" 2>/dev/null)" || die "无法查询 Wine-GE 最新版本（网络问题？）"

    tag_name="$(echo "$release_info" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    download_url="$(echo "$release_info" | grep '"browser_download_url".*\.tar\.xz' | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"
    [ -n "$tag_name" ]    || die "无法解析 Wine-GE 版本号"
    [ -n "$download_url" ] || die "无法解析 Wine-GE 下载链接"
    info "Wine-GE 最新版本: $tag_name"

    local existing=""
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        if echo "$r" | grep -qi "$tag_name" && [ -x "$runners_dir/$r/bin/wine" ]; then
            existing="$r"; break
        fi
    done
    if [ -n "$existing" ]; then
        info "版本 $tag_name 已安装: $existing"
        return 0
    fi

    local tmp_tar="/tmp/wine-ge-$tag_name.tar.xz"
    info "下载 Wine-GE（约 200+ MB，可能需要几分钟）..."

    local mirror ok=0
    for mirror in $GH_MIRRORS; do
        local murl="$mirror/$download_url"
        info "尝试镜像: $mirror"
        if curl -fL --progress-bar --connect-timeout 15 -o "$tmp_tar" "$murl" 2>/dev/null && [ -s "$tmp_tar" ]; then
            ok=1; break
        fi
        rm -f "$tmp_tar"
    done
    if [ "$ok" -eq 0 ]; then
        info "镜像下载失败，尝试 GitHub 直连..."
        curl -fL --progress-bar -o "$tmp_tar" "$download_url" || { rm -f "$tmp_tar"; die "Wine-GE 下载失败，请手动下载: $download_url"; }
    fi

    info "解压到 $runners_dir ..."
    tar xf "$tmp_tar" -C "$runners_dir" || { rm -f "$tmp_tar"; die "解压失败"; }
    rm -f "$tmp_tar"

    local found=""
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        if [ -x "$runners_dir/$r/bin/wine" ]; then
            if echo "$r" | grep -qi "$tag_name" || echo "$r" | grep -qi 'GE-Proton\|wine-ge\|lutris-GE'; then
                found="$r"; break
            fi
            [ -z "$found" ] && found="$r"
        fi
    done
    [ -n "$found" ] || die "解压后未找到有效的 wine 可执行文件"
    info "Wine-GE 安装成功: $found"
}

ensure_runner() {
    if has_usable_runner; then
        return 0
    fi
    warn "Bottles runners 目录下没有可用运行器"
    download_wine_ge
}

detect_runner() {
    local runners_dir="$BOTTLES_DATA/runners"
    [ -d "$runners_dir" ] || die "找不到 Bottles runners 目录: $runners_dir"

    if [ -n "$RUNNER_NAME" ] && [ -x "$runners_dir/$RUNNER_NAME/bin/wine" ]; then
        RUNNER_PATH="$runners_dir/$RUNNER_NAME"
        return 0
    fi

    local r=""
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        case "$r" in
            lutris-GE-*|wine-ge-*) RUNNER_NAME="$r"; RUNNER_PATH="$runners_dir/$r"; return 0 ;;
        esac
    done
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        case "$r" in
            soda-*) RUNNER_NAME="$r"; RUNNER_PATH="$runners_dir/$r"; return 0 ;;
        esac
    done
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        if [ -x "$runners_dir/$r/bin/wine" ]; then
            RUNNER_NAME="$r"; RUNNER_PATH="$runners_dir/$r"; return 0
        fi
    done
    die "Bottles runners 目录下没有可用的运行器"
}

WINE_BIN=""
WINE_SERVER=""
setup_wine_paths() {
    ensure_runner
    detect_runner
    WINE_BIN="$RUNNER_PATH/bin/wine"
    WINE_SERVER="$RUNNER_PATH/bin/wineserver"
    [ -x "$WINE_BIN" ] || die "找不到 wine: $WINE_BIN"
    [ -x "$WINE_SERVER" ] || die "找不到 wineserver: $WINE_SERVER"
    info "使用运行器: $RUNNER_NAME"
    info "Wine: $WINE_BIN"
}

# ==================== 宿主依赖 ====================
detect_pkg_manager() {
    if command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    fi
}

install_host_deps() {
    local mgr missing=() pkgs=() t still=()
    mgr="$(detect_pkg_manager)"
    [ -n "$mgr" ] || die "未识别的包管理器，请手动安装: curl cabextract unzip python3 winetricks binutils"

    for t in curl cabextract unzip python3 winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] && { info "宿主依赖齐全"; return 0; }

    for t in "${missing[@]}"; do
        case "$t:$mgr" in
            strings:*)          pkgs+=(binutils) ;;
            python3:apt|python3:dnf|python3:zypper) pkgs+=(python3) ;;
            python3:pacman)     pkgs+=(python) ;;
            *)                  pkgs+=("$t") ;;
        esac
    done
    local unique_pkgs=()
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && unique_pkgs+=("$pkg")
    done < <(printf '%s\n' "${pkgs[@]}" | sort -u)
    pkgs=("${unique_pkgs[@]}")

    info "安装宿主依赖: ${pkgs[*]}（需要 sudo）"
    case "$mgr" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}" ;;
        dnf)    sudo dnf install -y "${pkgs[@]}" ;;
        pacman) sudo pacman -S --noconfirm --needed "${pkgs[@]}" ;;
        zypper) sudo zypper install -y "${pkgs[@]}" ;;
    esac

    for t in curl cabextract unzip python3 winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || still+=("$t")
    done
    [ ${#still[@]} -eq 0 ] || die "仍有宿主依赖缺失: ${still[*]}"
    info "宿主依赖安装完成"
}

ensure_host_deps() {
    local missing=()
    for t in curl cabextract unzip python3 winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "缺少宿主依赖: ${missing[*]}"
        install_host_deps
    else
        info "宿主依赖齐全"
    fi
}

# ==================== 创建 Bottle ====================
detect_components() {
    local components=""
    components="$(bottles-cli list components 2>/dev/null)" || true
    DETECTED_DXVK="$(echo "$components" | grep -oE 'dxvk-[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    DETECTED_VKD3D="$(echo "$components" | grep -oE 'vkd3d-proton-[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    DETECTED_LFX="$(echo "$components" | grep -oE 'latencyflex-v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    # 不检测/不安装 NVAPI（国内网络无法从 GitHub 下载，且大多数应用不需要）
}

bottle_exists() {
    [ -f "$BOTTLES_DATA/bottles/$1/bottle.yml" ]
}

create_bottle() {
    local name="${1:-$BOTTLE_NAME}"
    local arch="${2:-$BOTTLE_ARCH}"
    local env="${3:-$BOTTLE_ENV}"
    require bottles-cli

    if bottle_exists "$name"; then
        info "Bottle '$name' 已存在"
        return 0
    fi

    setup_wine_paths
    detect_components

    local args=(--bottle-name "$name" --environment "$env" --arch "$arch" --runner "$RUNNER_NAME")
    [ -n "$DETECTED_DXVK" ] && args+=(--dxvk "$DETECTED_DXVK")
    [ -n "$DETECTED_VKD3D" ] && args+=(--vkd3d "$DETECTED_VKD3D")
    # 不传 --nvapi：bottles-cli 会自动从 GitHub 下载，国内网络不通会失败
    [ -n "$DETECTED_LFX" ] && args+=(--latencyflex "$DETECTED_LFX")

    info "创建 bottle: $name（环境: $env, 架构: $arch, 运行器: $RUNNER_NAME）"
    info "  DXVK=${DETECTED_DXVK:-无}  VKD3D=${DETECTED_VKD3D:-无}  LatencyFleX=${DETECTED_LFX:-无}"

    if ! timeout 180 bottles-cli new "${args[@]}" 2>&1; then
        die "创建 bottle 失败（bottles-cli new 返回非零）"
    fi

    for _ in $(seq 1 60); do
        bottle_exists "$name" && break
        sleep 2
    done
    bottle_exists "$name" || die "bottle 创建超时（120s），请检查 Bottles 是否正在运行"

    info "Bottle '$name' 创建成功"

    # 关闭沙盒（避免 /tmp 只读问题）
    local btl_yml="$BOTTLES_DATA/bottles/$name/bottle.yml"
    if grep -q 'sandbox: true' "$btl_yml" 2>/dev/null; then
        info "关闭沙盒（避免 wineserver /tmp 只读问题）"
        sed -i 's/sandbox: true/sandbox: false/' "$btl_yml"
    fi

    # 清理 NVAPI 配置行，防止 Bottles 自动从 GitHub 下载（国内网络不通）
    if grep -q '^NVAPI:' "$btl_yml" 2>/dev/null; then
        info "清理 bottle.yml 里的 NVAPI 配置（防止 Bottles 自动下载）"
        sed -i '/^NVAPI:/d' "$btl_yml"
    fi

    # 默认不限制帧数
    if grep -q 'gamescope_fps:' "$btl_yml" 2>/dev/null; then
        sed -i 's/gamescope_fps:.*/gamescope_fps: 0/' "$btl_yml"
    else
        sed -i '/Parameters:/a\    gamescope_fps: 0' "$btl_yml"
    fi
    info "设置默认不限制帧数"

    # 确保渲染器为 gl（减少闪屏）
    if grep -q 'renderer:' "$btl_yml" 2>/dev/null; then
        sed -i 's/renderer:.*/renderer: gl/' "$btl_yml"
    else
        sed -i '/Parameters:/a\    renderer: gl' "$btl_yml"
    fi

    PREFIX="$BOTTLES_DATA/bottles/$name"
}

# ==================== 运行 wine 命令 ====================
run_wine() {
    [ -n "$WINE_BIN" ] || setup_wine_paths
    WINEPREFIX="$PREFIX" WINE="$WINE_BIN" WINESERVER="$WINE_SERVER" WINELOADER="$WINE_BIN" \
        "$WINE_BIN" "$@"
}

run_winetricks() {
    [ -n "$WINE_BIN" ] || setup_wine_paths
    require winetricks
    info "运行 winetricks: $*"
    WINEPREFIX="$PREFIX" WINE="$WINE_BIN" WINESERVER="$WINE_SERVER" WINELOADER="$WINE_BIN" \
        WINETRICKS_DOWNLOADER=curl WINEDEBUG=fixme-all \
        winetricks "$@"
}

# ==================== 预下载安装包 ====================
download_if_missing() {
    local file="$1" url="$2" sha="$3"
    if [ -s "$file" ] && printf '%s  %s\n' "$sha" "$file" | sha256sum -c --status 2>/dev/null; then
        info "安装包已缓存: $file"; return 0
    fi
    mkdir -p "$(dirname "$file")"
    info "下载 $url"
    curl -kfL --retry 3 -o "$file" "$url" || { rm -f "$file"; warn "预下载失败: $url（交给 winetricks 下载）"; return 0; }
    if ! printf '%s  %s\n' "$sha" "$file" | sha256sum -c --status 2>/dev/null; then
        rm -f "$file"; warn "校验失败: $file（交给 winetricks 重新下载）"
    fi
}

# ==================== 基础依赖：.NET + VC++ ====================
install_dotnet_vc() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX（请先创建 bottle）"
    setup_wine_paths
    ensure_host_deps

    local cache="$USER_CACHE/winetricks"
    download_if_missing "$cache/dotnet40/dotNetFx40_Full_x86_x64.exe" "$DOTNET40_URL" "$DOTNET40_SHA"
    download_if_missing "$cache/dotnet48/ndp48-x86-x64-allos-enu.exe" "$DOTNET48_URL" "$DOTNET48_SHA"
    download_if_missing "$cache/vcrun2022/vc_redist.x86.exe" "$VCRUN2022_X86_URL" "$VCRUN2022_X86_SHA"
    download_if_missing "$cache/vcrun2022/vc_redist.x64.exe" "$VCRUN2022_X64_URL" "$VCRUN2022_X64_SHA"

    info "步骤 1/3: 移除 Wine Mono（必须先做，否则 .NET 4.8 安装器会误判已安装）"
    run_winetricks -q remove_mono || warn "remove_mono 未完全成功（可能本来就没装）"

    info "步骤 2/3: 安装 .NET Framework 4.8 + VC++ 运行库（约 10-25 分钟）"
    run_winetricks -q dotnet48 vcrun2022

    info "步骤 3/3: 安装完成"
}

# ==================== 通用中文依赖链 ====================
# 问题：国内 Windows 软件（微信/QQ/腾讯会议/网易云等）需要额外依赖
# 方案：安装完整的 Windows 组件链
install_common_deps() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX（请先创建 bottle）"
    setup_wine_paths
    ensure_host_deps

    info "安装通用中文依赖链（微信/QQ/腾讯会议/网易云等常用）"
    info "（约 15-30 分钟，取决于网络）"

    # 基础运行时和字体
    info "步骤 1/4: 安装基础字体和图形组件"
    run_winetricks -q corefonts cjkfonts gdiplus || warn "字体组件安装失败"

    # UI 控件
    info "步骤 2/4: 安装 UI 控件（聊天框/文本编辑）"
    run_winetricks -q riched20 riched30 msls31 comctl32 || warn "UI 控件安装失败"

    # DirectX 组件
    info "步骤 3/4: 安装 DirectX 组件"
    run_winetricks -q d3dcompiler_43 d3dcompiler_47 d3dx9 d3dx10 || warn "DirectX 组件安装失败"

    # XML 组件
    info "步骤 4/4: 安装 XML 组件"
    run_winetricks -q msxml3 msxml4 msxml6 || warn "XML 组件安装失败"

    info "通用中文依赖链安装完成"
    echo "  ✓ 基础字体（corefonts/cjkfonts）"
    echo "  ✓ 图形渲染（gdiplus）"
    echo "  ✓ UI 控件（riched20/30/comctl32/msls31）"
    echo "  ✓ Unicode 支持（msls31）"
    echo "  ✓ DirectX（d3dcompiler/d3dx9-10）"
    echo "  ✓ XML 解析（msxml3/4/6）"
}

# ==================== 完整依赖链（游戏/专业软件） ====================
# 问题：游戏和专业软件需要更完整的 Windows 组件
# 方案：安装所有常用运行时、DirectX、字体、多媒体组件
install_full_deps() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX（请先创建 bottle）"
    setup_wine_paths
    ensure_host_deps

    info "安装完整依赖链（游戏/专业软件推荐）"
    warn "这将安装大量组件，耗时约 30-60 分钟"

    # 基础运行时
    info "步骤 1/6: 安装 .NET Framework 系列"
    run_winetricks -q dotnet35 dotnet40 dotnet45 dotnet46 dotnet47 dotnet48 || warn ".NET 部分组件安装失败"

    info "步骤 2/6: 安装 VC++ 运行库全系列"
    run_winetricks -q vcrun2005 vcrun2008 vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2019 vcrun2022 || warn "VC++ 部分版本安装失败"

    info "步骤 3/6: 安装 DirectX 完整组件"
    run_winetricks -q directx9 d3dx9 d3dx10 d3dcompiler_43 d3dcompiler_47 || warn "DirectX 部分组件安装失败"

    info "步骤 4/6: 安装字体和图形组件"
    run_winetricks -q allfonts gdiplus cjkfonts || warn "字体组件部分安装失败"

    info "步骤 5/6: 安装多媒体和网络组件"
    run_winetricks -q wmp9 quicktime7 ie8 || warn "多媒体/网络组件部分安装失败"

    info "步骤 6/6: 安装其他常用组件"
    run_winetricks -q comctl32 msxml3 msxml4 msxml6 riched20 riched30 msls31 corefonts || warn "其他组件部分安装失败"

    info "完整依赖链安装完成"
    echo "  ✓ .NET Framework 3.5/4.0/4.5/4.6/4.7/4.8"
    echo "  ✓ VC++ 2005-2022 全系列"
    echo "  ✓ DirectX 9/10/11 完整组件"
    echo "  ✓ 完整字体（含 CJK）"
    echo "  ✓ 多媒体（WMP/QuickTime）"
    echo "  ✓ 网络（IE8）"
    echo "  ✓ 其他（comctl32/msxml/riched 等）"
}

# ==================== 验证 ====================
verify_dotnet() {
    local reg="$PREFIX/system.reg"
    local mscorlib="$PREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll"
    local ok=1

    if grep -a -q '"Version"="4\.8\.' "$reg" 2>/dev/null; then
        info "注册表: .NET 4.8 已注册"
    else
        warn "注册表里没有 .NET 4.8 Version"; ok=0
    fi

    if [ -f "$mscorlib" ] && [ "$(stat -c%s "$mscorlib")" -gt 4000000 ]; then
        info "mscorlib.dll: $(stat -c%s "$mscorlib") 字节（微软原版）"
    else
        local sz=0; [ -f "$mscorlib" ] && sz=$(stat -c%s "$mscorlib")
        warn "mscorlib.dll: ${sz} 字节（应 >4MB 才是微软原版，当前可能是 Wine Mono）"; ok=0
    fi

    [ "$ok" -eq 1 ] || die ".NET 4.8 验证未通过"
}

verify_deps() {
    verify_dotnet
    if grep -a -q 'Microsoft Visual C++' "$PREFIX/system.reg" 2>/dev/null; then
        info "VC++ 运行库已注册"
    else
        warn "未检测到 VC++ 运行库注册"
    fi
}

# ==================== 应用缩放 ====================
detect_display_dpi() {
    # 尝试获取显示器 DPI
    local dpi=""
    if command -v xdpyinfo >/dev/null 2>&1; then
        dpi="$(xdpyinfo 2>/dev/null | grep -A 3 'dimensions:' | grep 'resolution:' | awk '{print $2}' | cut -d'x' -f1)"
    fi
    if [ -z "$dpi" ] || [ "$dpi" -eq 0 ] 2>/dev/null; then
        dpi=96  # 默认 DPI
    fi
    echo "$dpi"
}

detect_display_resolution() {
    # 获取主显示器分辨率
    local res=""
    if command -v xrandr >/dev/null 2>&1; then
        res="$(xrandr 2>/dev/null | grep ' connected primary' | awk '{print $4}' | cut -d'+' -f1 | head -1)"
    fi
    if [ -z "$res" ]; then
        res="1920x1080"  # 默认分辨率
    fi
    echo "$res"
}

calc_auto_scale() {
    local res="$1"
    local width="${res%x*}"
    local scale=1.0

    # 根据分辨率宽度计算缩放比例
    if [ "$width" -ge 3840 ]; then
        scale=2.0  # 4K
    elif [ "$width" -ge 2560 ]; then
        scale=1.5  # 2K
    elif [ "$width" -ge 1920 ]; then
        scale=1.25  # 1080p
    elif [ "$width" -ge 1600 ]; then
        scale=1.15
    else
        scale=1.0  # 1080p 以下
    fi
    echo "$scale"
}

set_app_scale() {
    local scale="$APP_SCALE" logpixels
    setup_wine_paths

    # 如果是 auto，自动计算
    if [ "$scale" = "auto" ]; then
        local res
        res="$(detect_display_resolution)"
        scale="$(calc_auto_scale "$res")"
        info "自动检测分辨率: $res，计算缩放: ${scale}x"
    fi

    if ! awk -v s="$scale" 'BEGIN{exit !(s ~ /^[0-9]+([.][0-9]+)?$/ && s+0>0)}' 2>/dev/null; then
        warn "无效缩放倍数: $scale"; return 1
    fi
    logpixels="$(awk -v s="$scale" 'BEGIN{printf "%d", 96*s+0.5}')"
    info "设置应用缩放 ${scale}x（LogPixels=${logpixels}）"
    run_wine reg add 'HKCU\Software\Wine\X11 Driver' /v DpiScaling /t REG_SZ /d "$scale" /f
    run_wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$logpixels" /f
    info "缩放设置已写入（下次启动生效）"
}

# ==================== 暗色/浅色模式 ====================
set_theme_mode() {
    local mode="${1:-$THEME_MODE}"
    setup_wine_paths

    local light_value=1
    case "$mode" in
        dark|暗色|深色)
            light_value=0
            info "设置暗色模式"
            ;;
        light|浅色|亮色)
            light_value=1
            info "设置浅色模式"
            ;;
        auto|自动)
            # 检测系统主题
            if command -v gsettings >/dev/null 2>&1; then
                local gtk_theme
                gtk_theme="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")"
                if echo "$gtk_theme" | grep -qi 'dark'; then
                    light_value=0
                    info "检测到系统暗色主题: $gtk_theme，设置暗色模式"
                else
                    light_value=1
                    info "检测到系统浅色主题: $gtk_theme，设置浅色模式"
                fi
            else
                light_value=1
                info "无法检测系统主题，默认浅色模式"
            fi
            ;;
        *)
            warn "未知主题模式: $mode（可选: dark/light/auto）"
            return 1
            ;;
    esac

    # 设置 Windows 应用主题
    # AppsUseLightTheme: 0=暗色, 1=浅色
    # SystemUsesLightTheme: 0=暗色, 1=浅色
    run_wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d "$light_value" /f
    run_wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v SystemUsesLightTheme /t REG_DWORD /d "$light_value" /f

    info "主题模式已设置（$mode）"
}

# ==================== 窗口边缘闪屏修复 ====================
fix_window_flicker() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"
    setup_wine_paths

    info "修复窗口边缘闪屏问题"

    # 禁用窗口装饰动画
    run_wine reg add 'HKCU\Control Panel\Desktop' /v UserPreferencesMask /t REG_BINARY /d 9012038010000000 /f
    run_wine reg add 'HKCU\Control Panel\Desktop' /v MenuShowDelay /t REG_SZ /d "0" /f

    # 禁用窗口动画
    run_wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' /v VisualFXSetting /t REG_DWORD /d 2 /f

    # 设置窗口管理器相关参数
    run_wine reg add 'HKCU\Software\Wine\X11 Driver' /v UseSystemCursor /t REG_SZ /d "N" /f
    run_wine reg add 'HKCU\Software\Wine\X11 Driver' /v GrabFullscreen /t REG_SZ /d "N" /f

    # 禁用桌面合成（某些情况下有效）
    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"
    if [ -f "$bottle_yml" ]; then
        # 确保 renderer 设置为 gl（OpenGL）
        if grep -q 'renderer:' "$bottle_yml" 2>/dev/null; then
            sed -i 's/renderer:.*/renderer: gl/' "$bottle_yml"
        else
            sed -i '/Parameters:/a\    renderer: gl' "$bottle_yml"
        fi
        info "设置渲染器为 OpenGL（减少闪屏）"
    fi

    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 1

    info "窗口闪屏修复已应用（可能需要重启应用）"
}

# ==================== 帧数控制 ====================
set_fps_limit() {
    local fps="${1:-0}"  # 0 表示不限制
    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"

    [ -f "$bottle_yml" ] || die "找不到 bottle.yml: $bottle_yml"

    if [ "$fps" -eq 0 ]; then
        info "取消帧数限制"
    else
        info "设置帧数限制: ${fps} FPS"
    fi

    # 修改 bottle.yml 中的帧数限制
    if grep -q 'gamescope_fps:' "$bottle_yml" 2>/dev/null; then
        sed -i "s/gamescope_fps:.*/gamescope_fps: $fps/" "$bottle_yml"
    else
        sed -i '/Parameters:/a\    gamescope_fps: '"$fps" "$bottle_yml"
    fi

    # 同时设置 gamescope 相关参数
    if [ "$fps" -eq 0 ]; then
        # 禁用 gamescope（不限制帧数时不需要）
        if grep -q 'gamescope:' "$bottle_yml" 2>/dev/null; then
            sed -i 's/gamescope:.*/gamescope: false/' "$bottle_yml"
        fi
    fi

    info "帧数设置已写入（$fps FPS）"
}

# ==================== 修复渲染黑屏（可选） ====================
# 问题：WPF 应用在 DXVK 下 D3D9 渲染黑屏
# 原因：DXVK 对 WPF 的 D3D9 UI 合成支持不佳
# 方案：d3d9=builtin（WPF 走 wined3d/OpenGL）
# 注意：这会让 D3D9 游戏走 wined3d 而非 DXVK，性能略降
# 适用：MCStudio 等 WPF 应用，不适用纯游戏
fix_rendering() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"
    setup_wine_paths

    local user_reg="$PREFIX/user.reg"
    [ -f "$user_reg" ] || die "找不到 user.reg: $user_reg"

    info "修复渲染黑屏（WPF + DXVK 兼容性）"
    warn "注意：这会让 D3D9 走 wined3d/OpenGL，纯游戏不建议使用"

    info "步骤 1/3: 设置 d3d9=builtin（WPF 走 wined3d/OpenGL）"
    run_wine reg add "HKCU\Software\Wine\DllOverrides" /v d3d9 /t REG_SZ /d builtin /f 2>&1 | grep -v 'fixme\|err:fsync' || true

    info "步骤 2/3: 恢复 WPF 硬件加速"
    run_wine reg delete "HKCU\SOFTWARE\Microsoft\Avalon.Graphics" /v DisableHWAcceleration /f 2>&1 | grep -v 'fixme\|err:fsync' || true

    info "步骤 3/3: 清理 wineserver"
    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 2

    local d3d9_val hw_val
    d3d9_val="$(grep '"d3d9"' "$user_reg" 2>/dev/null | head -1 || true)"
    hw_val="$(grep 'DisableHWAcceleration' "$user_reg" 2>/dev/null | head -1 || true)"

    echo
    echo "===== 验证结果 ====="
    if echo "$d3d9_val" | grep -q 'builtin'; then
        info "✓ d3d9 DLL 覆盖: $d3d9_val"
    else
        warn "✗ d3d9 覆盖未生效: ${d3d9_val:-未找到}"
    fi

    if [ -z "$hw_val" ]; then
        info "✓ WPF 硬件加速: 已恢复（无 DisableHWAcceleration）"
    else
        warn "✗ WPF 硬件加速仍被禁用: $hw_val"
    fi

    echo
    info "渲染修复完成。重启应用测试。"
    echo "  WPF UI (D3D9)  → wined3d/OpenGL（兼容好，不黑屏）"
    echo "  游戏 D3D10/11  → DXVK/Vulkan（硬件加速）"
    echo "  游戏 D3D9      → wined3d/OpenGL（有加速，稍慢于 DXVK）"
}

# ==================== 安装中文字体 ====================
install_fonts() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"

    local fonts_dir="$PREFIX/drive_c/windows/Fonts"
    mkdir -p "$fonts_dir" 2>/dev/null || true

    info "安装中文字体到 Wine 前缀"

    # 源字体路径（兼容不同发行版）
    local noto_sans="/usr/share/fonts/google-noto-sans-cjk-fonts"
    local noto_serif="/usr/share/fonts/google-noto-serif-cjk-fonts"
    local wqy="/usr/share/fonts/wqy-microhei-fonts/wqy-microhei.ttc"
    local ukai="/usr/share/fonts/cjkuni-ukai-fonts/ukai.ttc"

    # 步骤 1：复制原始文件名
    info "步骤 1/5: 复制中文字体（保留原始文件名）"
    local copied=0
    [ -f "$noto_sans/NotoSansCJK-Regular.ttc" ] && cp "$noto_sans/NotoSansCJK-Regular.ttc" "$fonts_dir/" && copied=$((copied+1)) && echo "  ✓ NotoSansCJK-Regular.ttc"
    [ -f "$noto_sans/NotoSansCJK-Bold.ttc" ] && cp "$noto_sans/NotoSansCJK-Bold.ttc" "$fonts_dir/" && echo "  ✓ NotoSansCJK-Bold.ttc"
    [ -f "$noto_serif/NotoSerifCJK-Regular.ttc" ] && cp "$noto_serif/NotoSerifCJK-Regular.ttc" "$fonts_dir/" && copied=$((copied+1)) && echo "  ✓ NotoSerifCJK-Regular.ttc"
    [ -f "$wqy" ] && cp "$wqy" "$fonts_dir/" && echo "  ✓ wqy-microhei.ttc"
    [ -f "$ukai" ] && cp "$ukai" "$fonts_dir/" && echo "  ✓ ukai.ttc"

    [ "$copied" -eq 0 ] && warn "未找到系统中文字体，请先安装: dnf install google-noto-sans-cjk-fonts google-noto-serif-cjk-fonts wqy-microhei-fonts cjkuni-ukai-fonts"

    # 步骤 2：fontconfig 别名
    info "步骤 2/5: 设置 fontconfig 别名"
    mkdir -p ~/.config/fontconfig
    cat > ~/.config/fontconfig/fonts.conf << 'FONTEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="pattern"><test name="family"><string>Microsoft YaHei</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Sans CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>Microsoft YaHei UI</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Sans CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>微软雅黑</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Sans CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>SimSun</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>NSimSun</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>宋体</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>SimHei</string></test><edit name="family" mode="assign" binding="strong"><string>WenQuanYi Micro Hei</string></edit></match>
  <match target="pattern"><test name="family"><string>黑体</string></test><edit name="family" mode="assign" binding="strong"><string>WenQuanYi Micro Hei</string></edit></match>
  <match target="pattern"><test name="family"><string>KaiTi</string></test><edit name="family" mode="assign" binding="strong"><string>AR PL UKai CN</string></edit></match>
  <match target="pattern"><test name="family"><string>楷体</string></test><edit name="family" mode="assign" binding="strong"><string>AR PL UKai CN</string></edit></match>
  <match target="pattern"><test name="family"><string>FangSong</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>仿宋</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
</fontconfig>
FONTEOF
    echo "  ✓ fontconfig 别名 → ~/.config/fontconfig/fonts.conf"
    fc-cache -f 2>/dev/null || true

    # 步骤 3：Wine 注册表字体别名
    info "步骤 3/5: 设置 Wine 注册表字体别名（HKCU + HKLM）"
    local subs=(
        "Microsoft YaHei:Noto Sans CJK SC"
        "Microsoft YaHei UI:Noto Sans CJK SC"
        "SimSun:Noto Serif CJK SC"
        "SimHei:WenQuanYi Micro Hei"
        "NSimSun:Noto Serif CJK SC"
        "KaiTi:AR PL UKai CN"
        "FangSong:Noto Serif CJK SC"
        "Microsoft JhengHei:Noto Sans CJK TC"
    )
    for sub in "${subs[@]}"; do
        local key="${sub%%:*}" val="${sub##*:}"
        run_wine reg add "HKCU\\Software\\Wine\\Font Substitutes" /v "$key" /t REG_SZ /d "$val" /f 2>&1 | grep -v 'fixme\|err:' || true
        run_wine reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes" /v "$key" /t REG_SZ /d "$val" /f 2>&1 | grep -v 'fixme\|err:' || true
    done

    # 步骤 4：HKLM 注册字体（C 盘路径）
    info "步骤 4/5: 在 HKLM 注册字体（C 盘路径）"
    local font_regs=(
        "Noto Sans CJK SC (TrueType):NotoSansCJK-Regular.ttc"
        "Noto Sans CJK SC Bold (TrueType):NotoSansCJK-Bold.ttc"
        "Noto Serif CJK SC (TrueType):NotoSerifCJK-Regular.ttc"
        "WenQuanYi Micro Hei (TrueType):wqy-microhei.ttc"
        "AR PL UKai CN (TrueType):ukai.ttc"
    )
    for fr in "${font_regs[@]}"; do
        local fname="${fr%%:*}" ffile="${fr##*:}"
        run_wine reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" /v "$fname" /t REG_SZ /d "C:\\windows\\Fonts\\$ffile" /f 2>&1 | grep -v 'fixme\|err:' || true
    done

    # 步骤 5：fonttools 改名字体（DirectWrite 兼容，解决"口口口"）
    info "步骤 5/5: 用 fonttools 创建改名字体（DirectWrite 兼容）"
    if command -v uv >/dev/null 2>&1; then
        local wqy_src="/usr/share/fonts/wqy-microhei-fonts/wqy-microhei.ttc"
        local noto_serif_src="/usr/share/fonts/google-noto-serif-cjk-fonts/NotoSerifCJK-Regular.ttc"
        local wqy_zenhei_src="/usr/share/fonts/wqy-zenhei-fonts/wqy-zenhei.ttc"

        [ -f "$wqy_src" ] || wqy_src=$(fc-list | grep -i 'wqy-microhei.ttc' | head -1 | cut -d: -f1)
        [ -f "$noto_serif_src" ] || noto_serif_src=$(fc-list | grep -i 'NotoSerifCJK-Regular.ttc' | head -1 | cut -d: -f1)
        [ -f "$wqy_zenhei_src" ] || wqy_zenhei_src=$(fc-list | grep -i 'wqy-zenhei.ttc' | head -1 | cut -d: -f1)

        uv run --with fonttools python3 << PYEOF 2>/dev/null || warn "fonttools 创建改名字体失败"
from fontTools.ttLib import TTCollection
import os

dst_dir = "$fonts_dir"
fonts = [
    ("$wqy_src", "Microsoft YaHei", "msyh.ttc"),
    ("$wqy_src", "Microsoft YaHei UI", "msyhl.ttc"),
    ("$noto_serif_src", "SimSun", "simsun.ttc"),
    ("$wqy_src", "SimHei", "simhei.ttf"),
    ("$wqy_zenhei_src", "KaiTi", "simkai.ttf"),
]

for src, name, out in fonts:
    if not os.path.isfile(src):
        print(f"  跳过: {out}（源文件不存在: {src}）")
        continue
    out_path = os.path.join(dst_dir, out)
    ttc = TTCollection(src)
    for font in ttc.fonts:
        nt = font['name']
        for nameID in [1, 4, 6]:
            nt.setName(name, nameID, 3, 1, 0x409)
            nt.setName(name, nameID, 3, 1, 0x804)
        nt.setName("Regular", 2, 3, 1, 0x409)
    ttc.save(out_path)
    print(f"  ✓ {out} ({os.path.getsize(out_path)//1024} KB) - 内部名: {name}")
PYEOF

        local renamed_fonts=(
            "Microsoft YaHei (TrueType):msyh.ttc"
            "Microsoft YaHei UI (TrueType):msyhl.ttc"
            "SimSun (TrueType):simsun.ttc"
            "SimHei (TrueType):simhei.ttf"
            "KaiTi (TrueType):simkai.ttf"
        )
        for rf in "${renamed_fonts[@]}"; do
            local rfname="${rf%%:*}" rffile="${rf##*:}"
            [ -f "$fonts_dir/$rffile" ] && run_wine reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" /v "$rfname" /t REG_SZ /d "C:\\windows\\Fonts\\$rffile" /f 2>&1 | grep -v 'fixme\|err:' || true
        done
        echo "  ✓ 改名字体已注册到 HKLM Fonts"
    else
        warn "uv 未安装，跳过改名字体创建（DirectWrite 可能仍显示口口口）"
        warn "安装 uv: sudo dnf install uv"
    fi

    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 1

    echo
    echo "===== 验证结果 ====="
    local cnt=0
    for f in NotoSansCJK-Regular.ttc NotoSansCJK-Bold.ttc NotoSerifCJK-Regular.ttc wqy-microhei.ttc ukai.ttc; do
        [ -f "$fonts_dir/$f" ] && cnt=$((cnt+1))
    done
    info "中文字体文件: $cnt/5 已安装"
    if [ -f ~/.config/fontconfig/fonts.conf ]; then
        info "✓ fontconfig 别名已设置"
    else
        warn "✗ fontconfig 别名缺失"
    fi
    if grep -q 'Font Substitutes' "$PREFIX/user.reg" 2>/dev/null; then
        info "✓ Wine 注册表别名已设置"
    else
        warn "✗ Wine 注册表别名缺失"
    fi

    local renamed_cnt=0
    for f in msyh.ttc msyhl.ttc simsun.ttc simhei.ttf simkai.ttf; do
        [ -f "$fonts_dir/$f" ] && renamed_cnt=$((renamed_cnt+1))
    done
    if [ "$renamed_cnt" -gt 0 ]; then
        info "✓ 改名字体（DirectWrite 兼容）: $renamed_cnt/5 已创建"
        if grep -qa 'msyh.ttc' "$PREFIX/system.reg" 2>/dev/null; then
            info "✓ 改名字体已注册到 HKLM Fonts"
        else
            warn "✗ 改名字体未注册到 HKLM"
        fi
    else
        warn "✗ 改名字体未创建（需要 uv + fonttools）"
    fi

    echo
    echo "  fc-match 验证:"
    echo "    Microsoft YaHei → $(fc-match 'Microsoft YaHei' 2>/dev/null | sed 's/:.*//')"
    echo "    SimSun          → $(fc-match 'SimSun' 2>/dev/null | sed 's/:.*//')"
    echo "    SimHei          → $(fc-match 'SimHei' 2>/dev/null | sed 's/:.*//')"
    echo
    info "字体安装完成。重启应用后中文应正常显示。"
}

# ==================== 配置输入法 ====================
setup_input_method() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"

    info "配置输入法环境变量"

    local im_module="fcitx"
    if pgrep -x fcitx5 >/dev/null 2>&1; then
        im_module="fcitx"
        info "检测到 fcitx5"
    elif pgrep -x fcitx >/dev/null 2>&1; then
        im_module="fcitx"
        info "检测到 fcitx"
    elif pgrep -x ibus >/dev/null 2>&1; then
        im_module="ibus"
        info "检测到 ibus"
    else
        warn "未检测到运行中的输入法（fcitx5/ibus），将默认使用 fcitx"
    fi

    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"
    [ -f "$bottle_yml" ] || die "找不到 bottle.yml: $bottle_yml"

    info "写入环境变量到 bottle.yml"
    python3 - "$bottle_yml" "$im_module" << 'PYEOF' || die "更新 bottle.yml 失败"
import sys, re

path, im = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()

new_env = f"""Environment_Variables:
    GTK_IM_MODULE: {im}
    QT_IM_MODULE: {im}
    XMODIFIERS: '@im={im}'"""

content = re.sub(
    r'Environment_Variables:\s*\{?\s*\}?\s*\n(\s+[\w]+:\s*[^\n]+\n)*',
    new_env + '\n',
    content,
    count=1
)

if 'GTK_IM_MODULE' not in content:
    content = re.sub(
        r'Environment_Variables:\s*\n(\s+\S+:\s*\S+\s*\n)*',
        new_env + '\n',
        content,
        count=1
    )

if 'GTK_IM_MODULE' not in content:
    content = content.replace('Environment_Variables: {}', new_env)

with open(path, 'w') as f:
    f.write(content)
print(f"✓ 已设置 GTK_IM_MODULE={im}, QT_IM_MODULE={im}, XMODIFIERS=@im={im}")
PYEOF

    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 1

    echo
    echo "===== 验证结果 ====="
    if grep -q 'GTK_IM_MODULE' "$bottle_yml" 2>/dev/null; then
        info "✓ 输入法环境变量已写入 bottle.yml"
        grep -E 'GTK_IM_MODULE|QT_IM_MODULE|XMODIFIERS' "$bottle_yml" | sed 's/^/  /'
    else
        warn "✗ 环境变量未写入"
    fi
    echo
    info "输入法配置完成。重启 Bottles + 应用后可输入中文。"
}

# ==================== 诊断 ====================
cmd_check() {
    echo "===== Bottles 环境 ====="
    echo "Bottle: $BOTTLE_NAME"
    if [ -d "$PREFIX" ]; then
        echo "前缀: $PREFIX OK"
    else
        echo "前缀: 不存在 -> $PREFIX"
        return
    fi
    if setup_wine_paths 2>/dev/null; then
        echo "运行器: $RUNNER_NAME OK"
    else
        echo "运行器: 未检测到"
    fi

    echo
    echo "===== .NET Framework ====="
    if grep -a -q '"Version"="4\.8\.' "$PREFIX/system.reg" 2>/dev/null; then
        echo ".NET: 4.8 已安装（微软原版）"
    elif grep -a -q 'winemono\|wine_mono' "$PREFIX/system.reg" 2>/dev/null; then
        echo ".NET: 未安装（当前是 Wine Mono，WPF 应用会崩）"
    else
        echo ".NET: 未安装"
    fi
    local mscorlib="$PREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll"
    if [ -f "$mscorlib" ]; then
        local sz; sz=$(stat -c%s "$mscorlib")
        if [ "$sz" -gt 4000000 ]; then
            echo "mscorlib.dll: ${sz} 字节（微软原版 OK）"
        else
            echo "mscorlib.dll: ${sz} 字节（Wine Mono 版，需修复）"
        fi
    else
        echo "mscorlib.dll: 不存在"
    fi

    echo
    echo "===== VC++ 运行库 ====="
    if grep -a -q 'Microsoft Visual C++' "$PREFIX/system.reg" 2>/dev/null; then
        echo "VC++: 已注册"
    else
        echo "VC++: 未安装"
    fi

    echo
    echo "===== 应用缩放 ====="
    local scale_val logpix_val
    scale_val="$(grep -a '"DpiScaling"=' "$PREFIX/user.reg" 2>/dev/null | head -1 || true)"
    logpix_val="$(grep -a '"LogPixels"=' "$PREFIX/user.reg" 2>/dev/null | head -1 || true)"
    [ -n "$scale_val" ] && echo "$scale_val" || echo "DpiScaling: 未设置（默认 1x）"
    [ -n "$logpix_val" ] && echo "$logpix_val" || echo "LogPixels: 未设置（默认 96）"

    echo
    echo "===== 渲染配置 ====="
    local d3d9_val hw_val dxvk_val
    d3d9_val="$(grep -a '"d3d9"' "$PREFIX/user.reg" 2>/dev/null | head -1 || true)"
    hw_val="$(grep -a 'DisableHWAcceleration' "$PREFIX/user.reg" 2>/dev/null | head -1 || true)"
    dxvk_val="$(grep -a 'dxvk:' "$BOTTLES_DATA/bottles/$BOTTLE_NAME/bottle.yml" 2>/dev/null | head -1 || true)"
    if [ -n "$d3d9_val" ]; then
        echo "D3D9 覆盖: $d3d9_val"
        echo "$d3d9_val" | grep -q 'builtin' && echo "  → WPF 走 wined3d（黑屏已修复）" || echo "  → D3D9 走 DXVK（WPF 可能黑屏）"
    else
        echo "D3D9 覆盖: 未设置（默认走 DXVK）"
    fi
    [ -n "$hw_val" ] && echo "WPF 硬件加速: 已禁用 ($hw_val)" || echo "WPF 硬件加速: 已启用"
    [ -n "$dxvk_val" ] && echo "DXVK: $dxvk_val" || echo "DXVK: 状态未知"

    echo
    echo "===== 中文字体 ====="
    local fonts_dir="$PREFIX/drive_c/windows/Fonts"
    local font_cnt=0
    for f in NotoSansCJK-Regular.ttc NotoSansCJK-Bold.ttc NotoSerifCJK-Regular.ttc wqy-microhei.ttc ukai.ttc; do
        [ -f "$fonts_dir/$f" ] && font_cnt=$((font_cnt+1))
    done
    echo "中文字体文件: $font_cnt/5"
    [ -f ~/.config/fontconfig/fonts.conf ] && echo "fontconfig 别名: 已设置" || echo "fontconfig 别名: 未设置"
    grep -q 'Font Substitutes' "$PREFIX/user.reg" 2>/dev/null && echo "Wine 注册表别名: 已设置" || echo "Wine 注册表别名: 未设置"
    command -v fc-match >/dev/null 2>&1 && echo "  Microsoft YaHei → $(fc-match 'Microsoft YaHei' 2>/dev/null | sed 's/:.*//')" || true

    echo
    echo "===== 输入法 ====="
    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"
    if grep -q 'GTK_IM_MODULE' "$bottle_yml" 2>/dev/null; then
        grep -E 'GTK_IM_MODULE|QT_IM_MODULE|XMODIFIERS' "$bottle_yml" | sed 's/^/  /'
    else
        echo "输入法环境变量: 未设置"
    fi

    echo
    echo "===== 已安装的 Bottles 依赖 ====="
    grep -a 'Installed_Dependencies' "$BOTTLES_DATA/bottles/$BOTTLE_NAME/bottle.yml" 2>/dev/null || echo "（无 bottle.yml）"
}

# ==================== 预设方案 ====================
# 问题：不同使用场景需要不同的依赖组合
# 方案：提供预设方案（游戏/办公/通用），一键安装对应依赖
apply_preset() {
    local preset="${1:-common}"
    info "应用预设方案: $preset"

    case "$preset" in
        game|游戏)
            info "游戏预设：安装完整依赖链 + 渲染修复 + 不限制帧数"
            install_full_deps
            fix_rendering || warn "渲染修复失败（可选）"
            set_fps_limit 0  # 游戏不限制帧数
            ;;
        office|办公)
            info "办公预设：安装通用中文依赖链 + 暗色模式 + 修复闪屏"
            install_common_deps
            set_theme_mode
            fix_window_flicker
            ;;
        common|通用)
            info "通用预设：安装基础依赖 + 通用中文依赖链 + 暗色模式 + 修复闪屏"
            install_dotnet_vc
            install_common_deps
            set_theme_mode
            fix_window_flicker
            ;;
        full|完整)
            info "完整预设：安装所有可能需要的依赖 + 暗色模式 + 修复闪屏 + 不限制帧数"
            install_full_deps
            set_theme_mode
            fix_window_flicker
            set_fps_limit 0
            ;;
        *)
            die "未知预设: $preset（可选: game/office/common/full）"
            ;;
    esac

    install_fonts
    setup_input_method
    set_app_scale
    info "预设 $preset 应用完成"
}

# ==================== 交互式菜单 ====================
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

pause() { [ -t 0 ] && read -r -p "按回车返回菜单..." || true; }

cmd_menu() {
    local choice=""
    while true; do
        echo
        echo "===== Bottles 通用初始化工具 ====="
        echo "  Bottle: $BOTTLE_NAME"
        echo
        echo "  1) 诊断当前状态"
        echo "  2) 创建新 Bottle"
        echo "  3) 安装/更新 Wine-GE 运行器"
        echo "  4) 安装基础依赖（.NET 4.8 + VC++）"
        echo "  5) 安装通用中文依赖链（微信/QQ/腾讯会议等）"
        echo "  6) 安装完整依赖链（游戏/专业软件，耗时较长）"
        echo "  7) 安装中文字体（微软雅黑/宋体/黑体/楷体）"
        echo "  8) 配置输入法（fcitx5/ibus 中文输入）"
        echo "  9) 修复 WPF 渲染黑屏（可选，纯游戏不建议）"
        echo " 10) 修复窗口边缘闪屏"
        echo " 11) 设置应用缩放（当前 ${APP_SCALE}）"
        echo " 12) 设置暗色/浅色模式（当前 ${THEME_MODE}）"
        echo " 13) 设置帧数限制（当前 0=不限制）"
        echo " 14) 应用预设方案（game/office/common/full）"
        echo " 15) 完整初始化（创建Bottle + 运行器 + 通用依赖 + 字体 + 输入法 + 缩放 + 主题）"
        echo " 16) 退出"
        echo
        read -r -p "请选择 [1-16]: " choice || choice="exit"
        case "$choice" in
            1) ( cmd_check ) || warn "诊断失败"; pause ;;
            2) local bname="" barch="" benv=""
               read -r -p "Bottle 名称 [默认 $BOTTLE_NAME]: " bname || bname=""
               [ -n "$bname" ] && BOTTLE_NAME="$bname"
               read -r -p "架构 win32/win64 [默认 $BOTTLE_ARCH]: " barch || barch=""
               [ -n "$barch" ] && BOTTLE_ARCH="$barch"
               read -r -p "环境 gaming/application/custom [默认 $BOTTLE_ENV]: " benv || benv=""
               [ -n "$benv" ] && BOTTLE_ENV="$benv"
               ( create_bottle "$BOTTLE_NAME" "$BOTTLE_ARCH" "$BOTTLE_ENV" ) || warn "创建失败"; pause ;;
            3) ( download_wine_ge ) || warn "运行器安装失败"; pause ;;
            4) ( install_dotnet_vc && verify_deps ) || warn "依赖安装失败"; pause ;;
            5) ( install_common_deps ) || warn "中文依赖链安装失败"; pause ;;
            6) ( install_full_deps ) || warn "完整依赖链安装失败"; pause ;;
            7) ( install_fonts ) || warn "字体安装失败"; pause ;;
            8) ( setup_input_method ) || warn "输入法配置失败"; pause ;;
            9) ( fix_rendering ) || warn "渲染修复失败"; pause ;;
            10) ( fix_window_flicker ) || warn "闪屏修复失败"; pause ;;
            11) local newscale oldscale="$APP_SCALE"
                echo "  输入缩放倍数（数字）或 auto（自动检测分辨率）"
                read -r -p "输入缩放倍数 [默认 ${APP_SCALE}]: " newscale || newscale=""
                [ -n "$newscale" ] && APP_SCALE="$newscale"
                set_app_scale && pause || APP_SCALE="$oldscale" ;;
            12) local newtheme oldtheme="$THEME_MODE"
                echo "  可选: dark(暗色) / light(浅色) / auto(跟随系统)"
                read -r -p "输入主题模式 [默认 ${THEME_MODE}]: " newtheme || newtheme=""
                [ -n "$newtheme" ] && THEME_MODE="$newtheme"
                set_theme_mode && pause || THEME_MODE="$oldtheme" ;;
            13) local newfps
                echo "  输入帧数限制（0=不限制，60/120/144 等）"
                read -r -p "输入帧数限制 [默认 0]: " newfps || newfps=""
                [ -z "$newfps" ] && newfps=0
                ( set_fps_limit "$newfps" ) || warn "帧数设置失败"; pause ;;
            14) local preset_choice=""
                echo "  可选预设: game(游戏) / office(办公) / common(通用) / full(完整)"
                read -r -p "输入预设名称 [默认 common]: " preset_choice || preset_choice=""
                [ -z "$preset_choice" ] && preset_choice="common"
                ( apply_preset "$preset_choice" ) || warn "预设应用失败"; pause ;;
            15) if ( download_wine_ge && create_bottle && install_dotnet_vc && install_common_deps && install_fonts && setup_input_method && set_app_scale && set_theme_mode && fix_window_flicker && set_fps_limit 0 && verify_deps ); then
                    info "完整初始化完成，现在可以从 Bottles 启动应用了。"
               else
                    warn "完整初始化未完成"
               fi
               pause ;;
            16|q|Q|exit) echo "再见。"; return 0 ;;
            *) echo "无效选择: $choice"; sleep 1 ;;
        esac
    done
}

# ==================== 主流程 ====================
[ -d "$BOTTLES_DATA" ] || die "找不到 Bottles 数据目录: $BOTTLES_DATA"

case "${1:-}" in
    --check)        cmd_check ;;
    --menu|-i)      cmd_menu ;;
    --bottle-name)
        [ $# -ge 2 ] || die "用法: --bottle-name <名称>"
        BOTTLE_NAME="$2"; cmd_menu ;;
    --preset)
        [ $# -ge 2 ] || die "用法: --preset <game|office|common|full>"
        apply_preset "$2" ;;
    --full)
        BOTTLE_NAME="${2:-$BOTTLE_NAME}"
        download_wine_ge && create_bottle && install_dotnet_vc && install_common_deps && install_fonts && setup_input_method && set_app_scale && set_theme_mode && fix_window_flicker && set_fps_limit 0 && verify_deps ;;
    --full-deps)
        [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX（请先创建 bottle）"
        install_full_deps ;;
    --common-deps)
        [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX（请先创建 bottle）"
        install_common_deps ;;
    --scale)
        [ $# -ge 2 ] || die "用法: --scale <倍数|auto>"
        APP_SCALE="$2"; set_app_scale || exit 1 ;;
    --theme)
        [ $# -ge 2 ] || die "用法: --theme <dark|light|auto>"
        set_theme_mode "$2" ;;
    --fps)
        [ $# -ge 2 ] || die "用法: --fps <帧数，0=不限制>"
        set_fps_limit "$2" ;;
    --fix-flicker) fix_window_flicker ;;
    --install-host-deps) install_host_deps ;;
    --install-runner) download_wine_ge ;;
    --create-bottle) create_bottle ;;
    --fix-rendering) fix_rendering ;;
    --install-fonts) install_fonts ;;
    --setup-ime) setup_input_method ;;
    --deps-only|--dotnet-only)
        bottle_exists "$BOTTLE_NAME" || create_bottle "$BOTTLE_NAME" "$BOTTLE_ARCH" "$BOTTLE_ENV"
        install_dotnet_vc; verify_deps ;;
    -h|--help)      usage ;;
    "")             cmd_menu ;;
    *)              die "未知参数: $1（用 --help 查看用法）" ;;
esac
