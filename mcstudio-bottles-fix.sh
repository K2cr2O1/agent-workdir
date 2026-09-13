#!/usr/bin/env bash
#
# mcstudio-bottles-fix.sh — 修复 MCStudio（或其他 .NET/WPF 应用）在 Bottles 下打不开
# 兼容 Arch Linux / CachyOS，保留 Wine-GE
#
# 原理（同 Proton 版，去掉 Steam Runtime / shortcuts.vdf 部分）：
#   1. Bottles bottle 默认带 Wine Mono，WPF 应用会抛
#      TypeLoadException ... System.Object ... System.Runtime 崩溃。
#      标准修法：winetricks remove_mono -> dotnet48。
#   2. Wine Mono 会伪造注册表 Release=533320，让 .NET 4.8 安装器误判
#      "已安装"而直接退出，但 mscorlib.dll 不变。所以必须先 remove_mono。
#   3. 额外装 vcrun2022 + ucrtbase2019 保证 VC++ 运行库齐全。
#   4. 验证看证据：注册表 Version=4.8.x / mscorlib >4MB，而不是只看退出码。
#   5. 应用缩放：写 HKCU\Software\Wine\X11 Driver\DpiScaling 和 LogPixels。
#
# 用法:
#   mcstudio-bottles-fix.sh               交互式菜单（推荐）
#   mcstudio-bottles-fix.sh --menu|-i     同上
#   mcstudio-bottles-fix.sh --check       只诊断当前状态
#   mcstudio-bottles-fix.sh --install-runner   下载/更新 Wine-GE 运行器
#   mcstudio-bottles-fix.sh --create-bottle    创建新 Bottle（参考 MCS 配置）
#   mcstudio-bottles-fix.sh --deps-only   只装全部依赖（.NET 4.8 + VC++）
#   mcstudio-bottles-fix.sh --fix-rendering    修复渲染黑屏（d3d9=builtin）
#   mcstudio-bottles-fix.sh --setup-ime        配置输入法（fcitx5/ibus）
#   mcstudio-bottles-fix.sh --install-nvapi    安装 DXVK-NVAPI（AMD/Intel 兼容）
#   mcstudio-bottles-fix.sh --scale 1.5   设置应用缩放倍数
#   mcstudio-bottles-fix.sh --install-host-deps  安装脚本自身宿主依赖
set -euo pipefail
# ==================== 配置（按需修改） ====================
BOTTLES_DATA="${BOTTLES_DATA:-$HOME/.local/share/bottles}"
BOTTLE_NAME="${BOTTLE_NAME:-MCS}"
BOTTLE_ARCH="${BOTTLE_ARCH:-win64}"
BOTTLE_ENV="${BOTTLE_ENV:-gaming}"
RUNNER_NAME="${RUNNER_NAME:-}"  # 留空则自动检测（优先 wine-ge，其次 soda）
PREFIX="$BOTTLES_DATA/bottles/$BOTTLE_NAME"
APP_SCALE="${APP_SCALE:-1.5}"
DEPS_VERBS="${DEPS_VERBS:-dotnet48 vcrun2022 ucrtbase2019}"
USER_CACHE="${USER_CACHE:-$HOME/.cache}"
# Wine-GE 运行器自动下载配置
WINE_GE_REPO="${WINE_GE_REPO:-GloriousEggroll/wine-ge-custom}"
GH_MIRRORS="${GH_MIRRORS:-shturl.cc/CLAWn70JA5 https://mirror.ghproxy.com}"
# winetricks 官方下载地址与 sha256
DOTNET40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
DOTNET40_SHA="65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
DOTNET48_URL="https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
DOTNET48_SHA="95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"
VCRUN2022_X86_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
VCRUN2022_X86_SHA="0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64"
VCRUN2022_X64_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VCRUN2022_X64_SHA="cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"
UCRTBASE2019_X86_URL="https://download.visualstudio.microsoft.com/download/pr/85d47aa9-69ae-4162-8300-e6b7e4bf3cf3/14563755AC24A874241935EF2C22C5FCE973ACB001F99E524145113B2DC638C1/VC_redist.x86.exe"
UCRTBASE2019_X86_SHA="14563755ac24a874241935ef2c22c5fce973acb001f99e524145113b2dc638c1"
UCRTBASE2019_X64_URL="https://download.visualstudio.microsoft.com/download/pr/85d47aa9-69ae-4162-8300-e6b7e4bf3cf3/52B196BBE9016488C735E7B41805B651261FFA5D7AA86EB6A1D0095BE83687B2/VC_redist.x64.exe"
UCRTBASE2019_X64_SHA="52b196bbe9016488c735e7b41805b651261ffa5d7aa86eb6a1d0095be83687b2"
# ==================== 小工具 ====================
info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "缺少工具: $1"; }
# ==================== 自动下载 Wine-GE 运行器 ====================
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
    # 检查是否已安装该版本
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
    # 尝试镜像加速，失败则 GitHub 直连
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
    # 检测解压后的目录名
    local found=""
    for r in "$runners_dir"/*/; do
        r="${r%/}"; r="${r##*/}"
        if [ -x "$runners_dir/$r/bin/wine" ]; then
            # 优先匹配刚下载的版本
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
# ==================== 检测 Bottles 运行器 ====================
detect_runner() {
    local runners_dir="$BOTTLES_DATA/runners"
    [ -d "$runners_dir" ] || die "找不到 Bottles runners 目录: $runners_dir"
    # 如果指定了运行器，直接用
    if [ -n "$RUNNER_NAME" ] && [ -x "$runners_dir/$RUNNER_NAME/bin/wine" ]; then
        RUNNER_PATH="$runners_dir/$RUNNER_NAME"
        return 0
    fi
    # 优先 wine-ge，其次 soda，最后任意可用的
    local r=""
    for r in "$runners_dir"/*/; do
        r="${r%/}"
        r="${r##*/}"
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
    # 任意可用的
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
# ==================== 宿主依赖（兼容 Arch/pacman） ====================
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
    # 检查 python3 或 python（Arch 只有 python）
    local PYTHON_CMD="python3"
    command -v python3 >/dev/null 2>&1 || { PYTHON_CMD="python"; command -v python >/dev/null 2>&1 || missing+=("python3"); }
    for t in curl cabextract unzip winetricks strings; do
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
    pkgs=($(printf '%s\n' "${pkgs[@]}" | sort -u))
    info "安装宿主依赖: ${pkgs[*]}（需要 sudo）"
    case "$mgr" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}" ;;
        dnf)    sudo dnf install -y "${pkgs[@]}" ;;
        pacman) sudo pacman -S --noconfirm --needed "${pkgs[@]}" ;;
        zypper) sudo zypper install -y "${pkgs[@]}" ;;
    esac
    # 验证——python3 或 python 任一即可
    for t in curl cabextract unzip winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || still+=("$t")
    done
    command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || still+=("python3")
    [ ${#still[@]} -eq 0 ] || die "仍有宿主依赖缺失: ${still[*]}"
    info "宿主依赖安装完成"
}
ensure_host_deps() {
    local missing=()
    # python3 或 python 任一即可（Arch 只有 python）
    command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || missing+=("python3")
    for t in curl cabextract unzip winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ ${#missing[@]} -gt 0 ] && { warn "缺少宿主依赖: ${missing[*]}"; install_host_deps; } || info "宿主依赖齐全"
}
# ==================== 创建 Bottle ====================
detect_components() {
    local components=""
    components="$(bottles-cli list components 2>/dev/null)" || true
    DETECTED_DXVK="$(echo "$components" | grep -oE 'dxvk-[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    DETECTED_VKD3D="$(echo "$components" | grep -oE 'vkd3d-proton-[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    DETECTED_NVAPI="$(echo "$components" | grep -oE 'dxvk-nvapi-[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    DETECTED_LFX="$(echo "$components" | grep -oE 'latencyflex-v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
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
    setup_wine_paths  # 确保 runner 已检测/下载
    detect_components
    local args=(--bottle-name "$name" --environment "$env" --arch "$arch" --runner "$RUNNER_NAME")
    [ -n "$DETECTED_DXVK" ] && args+=(--dxvk "$DETECTED_DXVK")
    [ -n "$DETECTED_VKD3D" ] && args+=(--vkd3d "$DETECTED_VKD3D")
    # 不传 --nvapi：bottles-cli 会自动从 GitHub 下载，国内网络不通会反复重试失败
    # NVAPI 由 install_nvapi 函数后续安装（有镜像加速）
    [ -n "$DETECTED_LFX" ] && args+=(--latencyflex "$DETECTED_LFX")
    info "创建 bottle: $name（环境: $env, 架构: $arch, 运行器: $RUNNER_NAME）"
    info "  DXVK=${DETECTED_DXVK:-无}  VKD3D=${DETECTED_VKD3D:-无}  NVAPI=${DETECTED_NVAPI:-无}  LatencyFleX=${DETECTED_LFX:-无}"
    # bottles-cli 可能需要 Bottles 后台服务运行，超时设宽松一点
    if ! timeout 180 bottles-cli new "${args[@]}" 2>&1; then
        die "创建 bottle 失败（bottles-cli new 返回非零）"
    fi
    # 等待 bottle.yml 生成（bottles-cli 是异步的）
    local i=""
    for i in $(seq 1 60); do
        bottle_exists "$name" && break
        sleep 2
    done
    bottle_exists "$name" || die "bottle 创建超时（120s），请检查 Bottles 是否正在运行"
    info "Bottle '$name' 创建成功"
    # 关闭沙盒（参考 MCS 配置，避免 /tmp 只读问题）
    local btl_yml="$BOTTLES_DATA/bottles/$name/bottle.yml"
    if grep -q 'sandbox: true' "$btl_yml" 2>/dev/null; then
        info "关闭沙盒（避免 wineserver /tmp 只读问题）"
        sed -i 's/sandbox: true/sandbox: false/' "$btl_yml"
    fi
    # 清理 NVAPI 配置行，防止 Bottles 自动从 GitHub 下载（国内网络不通）
    # NVAPI 由 install_nvapi 函数后续安装（有镜像加速）
    if grep -q '^NVAPI:' "$btl_yml" 2>/dev/null; then
        info "清理 bottle.yml 里的 NVAPI 配置（防止 Bottles 自动下载）"
        sed -i '/^NVAPI:/d' "$btl_yml"
    fi
    # 更新全局 PREFIX 指向新创建的 bottle
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
# ==================== 安装依赖 ====================
install_deps() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX（请先在 Bottles 里创建 bottle: $BOTTLE_NAME）"
    setup_wine_paths
    ensure_host_deps
    local cache="$USER_CACHE/winetricks"
    download_if_missing "$cache/dotnet40/dotNetFx40_Full_x86_x64.exe" "$DOTNET40_URL" "$DOTNET40_SHA"
    download_if_missing "$cache/dotnet48/ndp48-x86-x64-allos-enu.exe" "$DOTNET48_URL" "$DOTNET48_SHA"
    download_if_missing "$cache/vcrun2022/vc_redist.x86.exe" "$VCRUN2022_X86_URL" "$VCRUN2022_X86_SHA"
    download_if_missing "$cache/vcrun2022/vc_redist.x64.exe" "$VCRUN2022_X64_URL" "$VCRUN2022_X64_SHA"
    download_if_missing "$cache/ucrtbase2019/vc_redist.x86.exe" "$UCRTBASE2019_X86_URL" "$UCRTBASE2019_X86_SHA"
    download_if_missing "$cache/ucrtbase2019/vc_redist.x64.exe" "$UCRTBASE2019_X64_URL" "$UCRTBASE2019_X64_SHA"
    info "开始安装依赖到 $PREFIX: $DEPS_VERBS（约 10-25 分钟）"
    info "步骤 1/3: 移除 Wine Mono（必须先做，否则 .NET 4.8 安装器会误判已安装）"
    run_winetricks -q remove_mono || warn "remove_mono 未完全成功（可能本来就没装）"
    info "步骤 2/3: 安装 .NET Framework 4.8 + VC++ 运行库"
    run_winetricks -q $DEPS_VERBS
    info "步骤 3/3: 安装完成"
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
set_app_scale() {
    local scale="$APP_SCALE" logpixels
    setup_wine_paths
    if ! awk -v s="$scale" 'BEGIN{exit !(s ~ /^[0-9]+([.][0-9]+)?$/ && s+0>0)}' 2>/dev/null; then
        warn "无效缩放倍数: $scale"; return 1
    fi
    logpixels="$(awk -v s="$scale" 'BEGIN{printf "%d", 96*s+0.5}')"
    info "设置应用缩放 ${scale}x（LogPixels=${logpixels}）"
    run_wine reg add 'HKCU\Software\Wine\X11 Driver' /v DpiScaling /t REG_SZ /d "$scale" /f
    run_wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$logpixels" /f
    info "缩放设置已写入（下次启动生效）"
}
# ==================== 修复渲染黑屏 ====================
# 问题：WPF 应用（如 MCStudio）在 DXVK 下 D3D9 渲染黑屏
# 原因：DXVK 对 WPF 的 D3D9 UI 合成支持不佳
# 方案：d3d9=builtin（WPF 走 wined3d/OpenGL），保留 DXVK 的 D3D10/11 加速游戏
fix_rendering() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"
    setup_wine_paths
    local user_reg="$PREFIX/user.reg"
    [ -f "$user_reg" ] || die "找不到 user.reg: $user_reg"
    info "修复渲染黑屏（WPF + DXVK 兼容性）"
    # 1. 设置 d3d9=builtin（WPF 的 D3D9 走 wined3d，不黑屏）
    info "步骤 1/3: 设置 d3d9=builtin（WPF 走 wined3d/OpenGL）"
    run_wine reg add "HKCU\Software\Wine\DllOverrides" /v d3d9 /t REG_SZ /d builtin /f 2>&1 | grep -v 'fixme\|err:fsync' || true
    # 2. 确保 WPF 硬件加速未被禁用
    info "步骤 2/3: 恢复 WPF 硬件加速"
    run_wine reg delete "HKCU\SOFTWARE\Microsoft\Avalon.Graphics" /v DisableHWAcceleration /f 2>&1 | grep -v 'fixme\|err:fsync' || true
    # 3. 清理 wineserver 让注册表写入磁盘
    info "步骤 3/3: 清理 wineserver"
    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 2
    # 验证
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
    info "渲染修复完成。重启 MCStudio 测试。"
    echo "  WPF UI (D3D9)  → wined3d/OpenGL（兼容好，不黑屏）"
    echo "  游戏 D3D10/11  → DXVK/Vulkan（硬件加速）"
    echo "  游戏 D3D9      → wined3d/OpenGL（有加速，稍慢于 DXVK）"
}
# ==================== 配置输入法 ====================
# 问题：Wine 应用无法输入中文（fcitx5/ibus 不工作）
# 方案：在 bottle.yml 设置 IM 环境变量
setup_input_method() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"
    info "配置输入法环境变量"
    # 检测系统输入法
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
    # 更新 bottle.yml 的 Environment_Variables
    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"
    [ -f "$bottle_yml" ] || die "找不到 bottle.yml: $bottle_yml"
    # 检测可用的 Python 命令（Arch 只有 python）
    local PYTHON_CMD="python3"
    command -v python3 >/dev/null 2>&1 || PYTHON_CMD="python"
    info "写入环境变量到 bottle.yml"
    # 用 Python 安全编辑 YAML
    $PYTHON_CMD - "$bottle_yml" "$im_module" << 'PYEOF' || die "更新 bottle.yml 失败"
import sys, re
path, im = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()
# 替换 Environment_Variables 段
new_env = f"""Environment_Variables:
    GTK_IM_MODULE: {im}
    QT_IM_MODULE: {im}
    XMODIFIERS: '@im={im}'"""
# 匹配 Environment_Variables: {} 或多行格式
content = re.sub(
    r'Environment_Variables:\s*\{?\s*\}?\s*\n(\s+[\w]+:\s*[^\n]+\n)*',
    new_env + '\n',
    content,
    count=1
)
# 如果没匹配到（可能是多行带缩进的格式），尝试另一种匹配
if 'GTK_IM_MODULE' not in content:
    content = re.sub(
        r'Environment_Variables:\s*\n(\s+\S+:\s*\S+\s*\n)*',
        new_env + '\n',
        content,
        count=1
    )
# 如果还是没有，直接替换 {} 格式
if 'GTK_IM_MODULE' not in content:
    content = content.replace('Environment_Variables: {}', new_env)
with open(path, 'w') as f:
    f.write(content)
print(f"✓ 已设置 GTK_IM_MODULE={im}, QT_IM_MODULE={im}, XMODIFIERS=@im={im}")
PYEOF
    # 清理 wineserver
    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 1
    # 验证
    echo
    echo "===== 验证结果 ====="
    if grep -q 'GTK_IM_MODULE' "$bottle_yml" 2>/dev/null; then
        info "✓ 输入法环境变量已写入 bottle.yml"
        grep -E 'GTK_IM_MODULE|QT_IM_MODULE|XMODIFIERS' "$bottle_yml" | sed 's/^/  /'
    else
        warn "✗ 环境变量未写入"
    fi
    echo
    info "输入法配置完成。重启 Bottles + MCStudio 后可输入中文。"
}
# ==================== 安装 DXVK-NVAPI ====================
# 问题：AMD/Intel 显卡报 "no nvapi found"
# 方案：安装 DXVK-NVAPI，让非 NVIDIA 显卡模拟 NVAPI 接口
install_nvapi() {
    [ -d "$PREFIX" ] || die "Bottle 前缀不存在: $PREFIX"
    setup_wine_paths
    local sys32="$PREFIX/drive_c/windows/system32"
    local syswow64="$PREFIX/drive_c/windows/syswow64"
    local nvapi_version="v0.9.0"
    local nvapi_url="https://github.com/jp7677/dxvk-nvapi/releases/download/${nvapi_version}/dxvk-nvapi-${nvapi_version}.tar.gz"
    info "安装 DXVK-NVAPI ${nvapi_version}（AMD/Intel 兼容）"
    # 步骤 0：确保 bottle.yml 启用 dxvk_nvapi + dxvk（DXVK-NVAPI 依赖 DXVK 运行）
    # 无论 DLL 是否已安装都执行，保证配置正确
    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"
    if [ -f "$bottle_yml" ]; then
        local bottle_yml_changed=0
        if grep -q 'dxvk_nvapi: false' "$bottle_yml"; then
            sed -i 's/dxvk_nvapi: false/dxvk_nvapi: true/' "$bottle_yml"
            bottle_yml_changed=1
        fi
        if grep -q 'dxvk: false' "$bottle_yml"; then
            sed -i 's/dxvk: false/dxvk: true/' "$bottle_yml"
            info "  ✓ 已启用 DXVK（之前为 false，NVAPI 无法加载）"
            bottle_yml_changed=1
        fi
        [ "$bottle_yml_changed" -eq 1 ] && info "bottle.yml 已更新（dxvk + dxvk_nvapi 已启用）"
    fi
    # 检查是否已安装
    if [ -f "$sys32/nvapi64.dll" ]; then
        info "DXVK-NVAPI 已安装，跳过"
        return 0
    fi
    # 下载
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/nvapi-XXXXXX")" || die "无法创建临时目录"
    info "下载 DXVK-NVAPI..."
    local mirror=""
    for m in "shturl.cc/CLAWn70JA5/" "https://mirror.ghproxy.com/" ""; do
        mirror="$m"
        if curl -L --fail --connect-timeout 15 -o "$tmpdir/dxvk-nvapi.tar.gz" "${m}${nvapi_url}" 2>/dev/null; then
            info "下载成功（${m:+镜像 $m}）"
            break
        fi
        mirror=""
    done
    [ -f "$tmpdir/dxvk-nvapi.tar.gz" ] || die "下载失败"
    # 解压
    tar xzf "$tmpdir/dxvk-nvapi.tar.gz" -C "$tmpdir" 2>/dev/null || die "解压失败"
    local extracted_dir="$tmpdir"
    [ -d "$tmpdir/dxvk-nvapi-${nvapi_version}" ] && extracted_dir="$tmpdir/dxvk-nvapi-${nvapi_version}"
    # 复制 DLL
    info "步骤 1/3: 复制 NVAPI DLL"
    cp "$extracted_dir/x64/nvapi64.dll" "$sys32/" && echo "  ✓ nvapi64.dll → system32"
    cp "$extracted_dir/x64/nvofapi64.dll" "$sys32/" 2>/dev/null && echo "  ✓ nvofapi64.dll → system32"
    cp "$extracted_dir/x32/nvapi.dll" "$syswow64/" && echo "  ✓ nvapi.dll → syswow64"
    # 设置 DLL 覆盖
    info "步骤 2/3: 设置 DLL 覆盖"
    run_wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v nvapi64 /t REG_SZ /d builtin /f 2>&1 | grep -v 'fixme\|err:' || true
    run_wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v nvapi /t REG_SZ /d builtin /f 2>&1 | grep -v 'fixme\|err:' || true
    # 清理
    "$WINE_SERVER" -k 2>/dev/null || true
    sleep 1
    rm -rf "$tmpdir" 2>/dev/null || true
    # 验证
    echo
    echo "===== 验证结果 ====="
    [ -f "$sys32/nvapi64.dll" ] && info "✓ nvapi64.dll 已安装" || warn "✗ nvapi64.dll 缺失"
    [ -f "$syswow64/nvapi.dll" ] && info "✓ nvapi.dll 已安装" || warn "✗ nvapi.dll 缺失"
    grep -q '"nvapi64"="builtin"' "$PREFIX/user.reg" 2>/dev/null && info "✓ DLL 覆盖已设置" || warn "✗ DLL 覆盖未设置"
    grep -q 'dxvk_nvapi: true' "$bottle_yml" 2>/dev/null && info "✓ bottle.yml dxvk_nvapi 已启用" || warn "✗ bottle.yml 未启用"
    grep -q 'dxvk: true' "$bottle_yml" 2>/dev/null && info "✓ bottle.yml dxvk 已启用（NVAPI 依赖）" || warn "✗ bottle.yml dxvk 未启用"
    echo
    info "DXVK-NVAPI 安装完成。'no nvapi found' 警告应消失。"
}
# ==================== 诊断 ====================
cmd_check() {
    echo "===== Bottles 环境 ====="
    echo "Bottle: $BOTTLE_NAME"
    [ -d "$PREFIX" ] && echo "前缀: $PREFIX OK" || { echo "前缀: 不存在 -> $PREFIX"; return; }
    setup_wine_paths 2>/dev/null && echo "运行器: $RUNNER_NAME OK" || echo "运行器: 未检测到"
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
    echo "===== 输入法 ====="
    local bottle_yml="${BOTTLES_DATA}/bottles/${BOTTLE_NAME}/bottle.yml"
    if grep -q 'GTK_IM_MODULE' "$bottle_yml" 2>/dev/null; then
        grep -E 'GTK_IM_MODULE|QT_IM_MODULE|XMODIFIERS' "$bottle_yml" | sed 's/^/  /'
    else
        echo "输入法环境变量: 未设置"
    fi
    echo
    echo "===== NVAPI（AMD/Intel 兼容）====="
    [ -f "$PREFIX/drive_c/windows/system32/nvapi64.dll" ] && echo "nvapi64.dll: 已安装" || echo "nvapi64.dll: 未安装"
    grep -q '"nvapi64"="builtin"' "$PREFIX/user.reg" 2>/dev/null && echo "DLL 覆盖: 已设置" || echo "DLL 覆盖: 未设置"
    grep -q 'dxvk_nvapi: true' "$bottle_yml" 2>/dev/null && echo "bottle.yml: dxvk_nvapi 已启用" || echo "bottle.yml: dxvk_nvapi 未启用"
    grep -q 'dxvk: true' "$bottle_yml" 2>/dev/null && echo "bottle.yml: dxvk 已启用（NVAPI 无法工作）" || echo "bottle.yml: dxvk 未启用"
    echo
    echo "===== 已安装的 Bottles 依赖 ====="
    grep -a 'Installed_Dependencies' "$BOTTLES_DATA/bottles/$BOTTLE_NAME/bottle.yml" 2>/dev/null || echo "（无 bottle.yml）"
}
# ==================== 交互式菜单（移除字体选项，序号顺推） ====================
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
pause() { [ -t 0 ] && read -r -p "按回车返回菜单..." || true; }
cmd_menu() {
    local choice=""
    while true; do
        echo
        echo "===== MCStudio Bottles 修复工具 ====="
        echo "  Bottle: $BOTTLE_NAME"
        echo
        echo "  1) 诊断当前状态"
        echo "  2) 创建新 Bottle（参考 MCS 配置）"
        echo "  3) 安装/更新 Wine-GE 运行器"
        echo "  4) 安装全部依赖（.NET 4.8 + VC++ 运行库）"
        echo "  5) 修复渲染黑屏（WPF + DXVK 兼容性）"
        echo "  6) 配置输入法（fcitx5/ibus 中文输入）"
        echo "  7) 安装 DXVK-NVAPI（AMD/Intel 显卡兼容）"
        echo "  8) 设置应用缩放（当前 ${APP_SCALE}x）"
        echo "  9) 完整修复（创建Bottle + 运行器 + 依赖 + 渲染 + 输入法 + NVAPI + 缩放）"
        echo " 10) 退出"
        echo
        read -r -p "请选择 [1-10]: " choice || choice="exit"
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
            4) ( install_deps && verify_deps ) || warn "依赖安装失败"; pause ;;
            5) ( fix_rendering ) || warn "渲染修复失败"; pause ;;
            6) ( setup_input_method ) || warn "输入法配置失败"; pause ;;
            7) ( install_nvapi ) || warn "NVAPI 安装失败"; pause ;;
            8) local newscale oldscale="$APP_SCALE"
                read -r -p "输入缩放倍数 [默认 ${APP_SCALE}]: " newscale || newscale=""
                [ -n "$newscale" ] && APP_SCALE="$newscale"
                set_app_scale && pause || APP_SCALE="$oldscale" ;;
            9) if ( download_wine_ge && create_bottle && install_deps && fix_rendering && setup_input_method && install_nvapi && set_app_scale && verify_deps ); then
                    info "修复完成，现在可以从 Bottles 启动 MCStudio 了。"
               else
                    warn "完整修复未完成"
               fi
               pause ;;
            10|q|Q|exit) echo "再见。"; return 0 ;;
            *) echo "无效选择: $choice"; sleep 1 ;;
        esac
    done
}
# ==================== 主流程 ====================
[ -d "$BOTTLES_DATA" ] || die "找不到 Bottles 数据目录: $BOTTLES_DATA"
case "${1:-}" in
    --check)        cmd_check ;;
    --menu|-i)      cmd_menu ;;
    --scale)
        [ $# -ge 2 ] || die "用法: --scale <倍数>"
        APP_SCALE="$2"; set_app_scale || exit 1 ;;
    --install-host-deps) install_host_deps ;;
    --install-runner) download_wine_ge ;;
    --create-bottle) create_bottle ;;
    --fix-rendering) fix_rendering ;;
    --setup-ime) setup_input_method ;;
    --install-nvapi) install_nvapi ;;
    --deps-only|--dotnet-only)
        bottle_exists "$BOTTLE_NAME" || create_bottle "$BOTTLE_NAME" "$BOTTLE_ARCH" "$BOTTLE_ENV"
        install_deps; verify_deps ;;
    -h|--help)      usage ;;
    "")             cmd_menu ;;
    *)              die "未知参数: $1（用 --help 查看用法）" ;;
esac
