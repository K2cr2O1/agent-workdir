#!/usr/bin/env bash
#
# mcstudio-proton-fix.sh — 修复 MCStudio（或其他 .NET/WPF 应用）在 Steam Proton 下打不开
#
# 经验总结（本脚本就是这些经验的实现）：
#   1. Steam 非 Steam 快捷方式的 Exe 字段必须带引号。Steam 用 /bin/sh -c 拼命令，
#      `Program Files (x86)` 里的括号会被当成子 shell 语法，直接 syntax error 退出(exit 2)。
#      路径重复拼接（Exe 值出现两次）同样会让 Proton 静默失败(exit 1)。
#   2. Proton 前缀默认只带 Wine Mono，不是微软 .NET Framework。WPF 应用会抛
#      `TypeLoadException ... System.Object ... System.Runtime` 崩溃。
#      标准修法是 winetricks dotnet48：remove_mono -> dotnet40 -> win7 -> ndp48。
#   3. Wine Mono 会伪造注册表 `NDP\v4\Full Release=533320`，让 .NET 4.8 安装器误判
#      “已安装”而直接成功退出(exit 0)，但 mscorlib.dll 不变。所以必须先 remove_mono。
#   4. 在 Steam Runtime 容器里跑宿主 winetricks，宿主工具(awk/wget/unzip/cabextract)
#      会因找不到宿主库失败；用包装脚本 + LD_LIBRARY_PATH 指向宿主 lib64 即可。
#   5. 验证看证据：注册表 Version=4.8.03761 / mscorlib >4MB / 窗口名（xprop）/
#      更新器日志，而不是只看退出码。
#   6. 首次启动应用会自更新（MCStudio 1.1.0 -> 1.1.56 补丁约 339MB），需要耐心等。
#   7. Wine 应用缩放：写 HKCU\Software\Wine\X11 Driver\DpiScaling（字符串倍数）
#      和 HKCU\Control Panel\Desktop\LogPixels（96×倍数），默认 1.5 倍。
#   8. 应用依赖一次装齐：.NET Framework 4.8 + VC++ 运行库（vcrun2022 含 2015-2022）
#      + ucrtbase2019；注意 vcrun2019 与 vcrun2022 互斥，不能同时装；
#      脚本自身的宿主工具（curl/wget/cabextract/unzip/python3/winetricks/binutils）
#      缺失时也会尝试自动安装。
#
# 用法:
#   mcstudio-proton-fix.sh               交互式菜单（推荐）
#   mcstudio-proton-fix.sh --menu|-i     同上
#   mcstudio-proton-fix.sh --check       只诊断当前状态
#   mcstudio-proton-fix.sh --shortcut-only   只修快捷方式
#   mcstudio-proton-fix.sh --deps-only|--dotnet-only   只装全部依赖（.NET 4.8 + VC++）
#   mcstudio-proton-fix.sh --install-host-deps   安装脚本自身宿主依赖
#   mcstudio-proton-fix.sh --scale 1.5   设置应用缩放倍数（默认 1.5；可 1 / 1.5 / 2 / 2.5 / 3）
#   mcstudio-proton-fix.sh --stop-steam      完整修复并自动关闭 Steam
#
set -euo pipefail

# ==================== 配置（按需修改） ====================
# sudo 模式下 HOME 会变成 /root，这里解析真实用户的目录
REAL_USER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_USER_HOME" ] || REAL_USER_HOME="$HOME"

APPID="${APPID:-2904845412}"
STEAM_ROOT="${STEAM_ROOT:-$REAL_USER_HOME/.local/share/Steam}"
COMPAT_TOOL="${COMPAT_TOOL:-GE-Proton11-3}"
RUNTIME_DIR="${RUNTIME_DIR:-SteamLinuxRuntime_4}"
WINETRICKS_BIN="${WINETRICKS_BIN:-}"
APP_SCALE="${APP_SCALE:-1.5}"
DEPS_VERBS="${DEPS_VERBS:-dotnet48 vcrun2022 ucrtbase2019}"
USER_CACHE="${USER_CACHE:-$REAL_USER_HOME/.cache}"
WT_WRAP_DIR=""

PREFIX="$STEAM_ROOT/steamapps/compatdata/$APPID/pfx"
EXE_REL="drive_c/Program Files (x86)/Netease/MCStudio/MCStudio.exe"
EXE="$PREFIX/$EXE_REL"
EXE_QUOTED="\"$EXE\""

# winetricks 官方下载地址与 sha256（dotnet48 的流程依赖这两个包）
DOTNET40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
DOTNET40_SHA="65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
DOTNET48_URL="https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
DOTNET48_SHA="95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"
VCRUN2019_X86_URL="https://aka.ms/vs/16/release/vc_redist.x86.exe"
VCRUN2019_X86_SHA="49545cb0f6499c4a65e1e8d5033441eeeb4edfae465a68489a70832c6a4f6399"
VCRUN2019_X64_URL="https://aka.ms/vs/16/release/vc_redist.x64.exe"
VCRUN2019_X64_SHA="5d9999036f2b3a930f83b7fe3e2186b12e79ae7c007d538f52e3582e986a37c3"
VCRUN2022_X86_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
VCRUN2022_X86_SHA="0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64"
VCRUN2022_X64_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VCRUN2022_X64_SHA="cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"
UCRTBASE2019_X86_URL="https://download.visualstudio.microsoft.com/download/pr/85d47aa9-69ae-4162-8300-e6b7e4bf3cf3/14563755AC24A874241935EF2C22C5FCE973ACB001F99E524145113B2DC638C1/VC_redist.x86.exe"
UCRTBASE2019_X86_SHA="14563755ac24a874241935ef2c22c5fce973acb001f99e524145113b2dc638c1"
UCRTBASE2019_X64_URL="https://download.visualstudio.microsoft.com/download/pr/85d47aa9-69ae-4162-8300-e6b7e4bf3cf3/52B196BBE9016488C735E7B41805B651261FFA5D7AA86EB6A1D0095BE83687B2/VC_redist.x64.exe"
UCRTBASE2019_X64_SHA="52b196bbe9016488c735e7b41805b651261ffa5d7aa86eb6a1d0095be83687b2"

PROTON="$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL/proton"
RUNTIME_ENTRY="$STEAM_ROOT/steamapps/common/$RUNTIME_DIR/_v2-entry-point"
WINE_BIN="$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL/files/bin/wine"
WINE_SERVER="$STEAM_ROOT/compatibilitytools.d/$COMPAT_TOOL/files/bin/wineserver"

# sudo 下自动降权：wine 拒绝操作“不是自己拥有”的 prefix
if [ "$(id -u)" -eq 0 ] && [ "${MCSTUDIO_FIX_AS_USER:-}" = "1" ]; then
    die "已尝试切换用户但仍以 root 运行（sudo -u 失败），请检查 sudo 配置"
fi
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    echo "[INFO] 检测到 sudo 运行，切换到用户 $SUDO_USER 执行（避免 wine 所有权问题）..."
    exec sudo -u "$SUDO_USER" env MCSTUDIO_FIX_AS_USER=1 \
        DISPLAY="${DISPLAY:-}" \
        XAUTHORITY="${XAUTHORITY:-$REAL_USER_HOME/.Xauthority}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u "$SUDO_USER")}" \
        APPID="$APPID" STEAM_ROOT="$STEAM_ROOT" COMPAT_TOOL="$COMPAT_TOOL" \
        RUNTIME_DIR="$RUNTIME_DIR" APP_SCALE="$APP_SCALE" DEPS_VERBS="$DEPS_VERBS" \
        USER_CACHE="$USER_CACHE" WINETRICKS_BIN="$WINETRICKS_BIN" \
        "$0" "$@"
fi
if [ "$(id -u)" -eq 0 ]; then
    die "检测到 root 直接运行。请用 sudo 以普通用户执行：sudo $0"
fi

# ==================== 小工具 ====================
info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "缺少工具: $1"
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    elif command -v zypper >/dev/null 2>&1; then
        echo zypper
    fi
}

install_host_deps() {
    # 脚本自身需要的宿主工具（winetricks 在容器里还要靠它们工作）
    local mgr missing=() pkgs=() t still=()
    mgr="$(detect_pkg_manager)"
    [ -n "$mgr" ] || die "未识别的包管理器，请手动安装: curl wget cabextract unzip python3 winetricks binutils"

    for t in curl wget cabextract unzip python3 winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        info "宿主依赖齐全"
        return 0
    fi

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
    if ! sudo -n true 2>/dev/null; then
        die "需要 sudo 权限，请先手动执行: sudo $mgr install ${pkgs[*]}"
    fi
    case "$mgr" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}" ;;
        dnf)    sudo dnf install -y "${pkgs[@]}" ;;
        pacman) sudo pacman -S --noconfirm --needed "${pkgs[@]}" ;;
        zypper) sudo zypper install -y "${pkgs[@]}" ;;
    esac

    for t in curl wget cabextract unzip python3 winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || still+=("$t")
    done
    [ ${#still[@]} -eq 0 ] || die "仍有宿主依赖缺失: ${still[*]}"
    info "宿主依赖安装完成"
}

ensure_host_deps() {
    local missing=()
    for t in curl wget cabextract unzip python3 winetricks strings; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "缺少宿主依赖: ${missing[*]}，尝试自动安装..."
        install_host_deps
    else
        info "宿主依赖齐全"
    fi
}

steam_running() {
    pgrep -x steam >/dev/null 2>&1
}

steam_shutdown() {
    # sudo 模式下不能以 root 启动 Steam，退回真实用户执行
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" env DISPLAY="${DISPLAY:-:0}" steam -shutdown >/dev/null 2>&1 || true
    else
        steam -shutdown >/dev/null 2>&1 || true
    fi
}

ensure_steam_stopped() {
    if steam_running; then
        die "Steam 正在运行。请先关闭（steam -shutdown），或加 --stop-steam 让脚本自动关闭。"
    fi
}

find_shortcuts_vdf() {
    find "$STEAM_ROOT/userdata" -name shortcuts.vdf 2>/dev/null | head -1
}

run_wine() {
    # 在 Steam Runtime 容器里执行 wine 命令（reg add / reg query 等）
    [ -x "$RUNTIME_ENTRY" ] || die "找不到 Steam Runtime: $RUNTIME_ENTRY"
    [ -x "$WINE_BIN" ] || die "找不到 wine: $WINE_BIN"
    export STEAM_COMPAT_DATA_PATH="$STEAM_ROOT/steamapps/compatdata/$APPID"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
    "$RUNTIME_ENTRY" --verb=run -- env \
        WINEPREFIX="$PREFIX" \
        WINE="$WINE_BIN" \
        WINESERVER="$WINE_SERVER" \
        WINELOADER="$WINE_BIN" \
        "$WINE_BIN" "$@"
}

# ==================== 3. 应用缩放 ====================
set_app_scale() {
    local scale="$APP_SCALE" logpixels
    if ! awk -v s="$scale" 'BEGIN{exit !(s ~ /^[0-9]+([.][0-9]+)?$/ && s+0>0)}' 2>/dev/null; then
        warn "无效缩放倍数: $scale（应为正数，如 1 / 1.5 / 2 / 2.5 / 3）"
        return 1
    fi
    logpixels="$(awk -v s="$scale" 'BEGIN{printf "%d", 96*s+0.5}')"
    info "设置应用缩放 ${scale}x（LogPixels=${logpixels}）"
    run_wine reg add 'HKCU\Software\Wine\X11 Driver' /v DpiScaling /t REG_SZ /d "$scale" /f
    run_wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$logpixels" /f
    info "缩放设置已写入（下次启动 MCStudio 生效）"
}

# ==================== 1. 修 Steam 快捷方式 ====================
patch_shortcuts() {
    local vdf
    vdf="$(find_shortcuts_vdf)"
    [ -n "$vdf" ] || die "找不到 shortcuts.vdf（$STEAM_ROOT/userdata/*/config/）"
    require python3

    info "修补快捷方式: $vdf"
    python3 - "$vdf" "$EXE" <<'PYEOF'
import pathlib, sys, time

vdf = pathlib.Path(sys.argv[1])
exe = sys.argv[2].encode("utf-8")          # 规范路径（不带引号）
exe_q = b'"' + exe + b'"'

data = vdf.read_bytes()
exe_marker = b"Exe\x00"
lo_marker = b"LaunchOptions\x00"
appid_marker = b"\x02appid\x00"
changed = False

# 1) 找到 MCStudio 条目的 Exe 值（按 Netease/MCStudio.exe 识别，兼容任意容器 ID）
pos = -1
start = 0
while True:
    i = data.find(exe_marker, start)
    if i < 0:
        break
    vstart = i + len(exe_marker)
    vend = data.find(b"\x00", vstart)
    val = data[vstart:vend]
    if b"Netease" in val and b"MCStudio.exe" in val:
        pos = i
        break
    start = i + 1

if pos < 0:
    print("TARGET_EXE_NOT_FOUND")
    raise SystemExit(0)

vstart = pos + len(exe_marker)
vend = data.find(b"\x00", vstart)
old = data[vstart:vend]
if old != exe_q:
    data = data[:vstart] + exe_q + data[vend:]
    changed = True
    print(f"EXE_FIXED: {old!r} -> {exe_q!r}")
else:
    print("EXE_OK")

# 2) 同步修正 StartDir（容器 ID 变了，目录也要跟着变）
exe_dir = exe.rsplit(b"/", 1)[0] + b"/"
j = data.find(exe_q)
next_entry = data.find(appid_marker, j)
sd = data.find(b"StartDir\x00", j)
if sd != -1 and (next_entry == -1 or sd < next_entry):
    sdstart = sd + len(b"StartDir\x00")
    sdend = data.find(b"\x00", sdstart)
    sdval = data[sdstart:sdend]
    if b"Netease" in sdval and sdval != exe_dir:
        data = data[:sdstart] + exe_dir + data[sdend:]
        changed = True
        print(f"STARTDIR_FIXED: {sdval!r} -> {exe_dir!r}")

# 3) 清空同一条目的 LaunchOptions（残留 %command% / PROTON_ENABLE_WAYLAND=1 会变成多余参数）
lo = data.find(lo_marker, j)
if lo != -1 and (next_entry == -1 or lo < next_entry):
    lvstart = lo + len(lo_marker)
    lvend = data.find(b"\x00", lvstart)
    loval = data[lvstart:lvend]
    if loval:
        data = data[:lvstart] + data[lvend:]
        changed = True
        print(f"LAUNCH_OPTIONS_CLEARED: {loval!r}")
    else:
        print("LAUNCH_OPTIONS_OK")
else:
    print("NO_LAUNCH_OPTIONS")

if changed:
    bak = str(vdf) + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    vdf.rename(bak)              # 先整体备份
    vdf.write_bytes(data)
    print(f"BACKUP: {bak}")
else:
    print("NO_CHANGE")
PYEOF

    # 校验：Exe 必须带引号，且文件里不再有重复路径
    if strings "$vdf" | grep -q 'MCStudio.exe.*MCStudio.exe'; then
        die "快捷方式仍是重复路径，请检查后重试"
    fi
    if strings "$vdf" | grep -Fq "$EXE_QUOTED"; then
        info "快捷方式 Exe 已修正（带引号）"
    else
        warn "未在 shortcuts.vdf 中找到带引号的 Exe，请人工检查"
    fi
}

# ==================== 2. 安装全部依赖 ====================
download_if_missing() {
    local file="$1" url="$2" sha="$3"
    if [ -s "$file" ] && printf '%s  %s\n' "$sha" "$file" | sha256sum -c --status 2>/dev/null; then
        info "安装包已缓存: $file"
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    info "下载 $url"
    # -k: 本机 CA 证书链可能不完整（Microsoft 下载站），sha256 校验兜底
    curl -kfL --retry 3 -o "$file" "$url" || {
        rm -f "$file"
        warn "预下载失败: $url（稍后交给 winetricks 下载）"
        return 0
    }
    if ! printf '%s  %s\n' "$sha" "$file" | sha256sum -c --status 2>/dev/null; then
        rm -f "$file"
        warn "预下载校验失败: $file（稍后交给 winetricks 重新下载）"
    fi
}

make_host_tool_wrappers() {
    # 在 Steam Runtime 容器里，宿主工具找不到宿主库；生成包装脚本注入 LD_LIBRARY_PATH
    local wrap_dir host_bin host_libs tool ca_bundle extra
    wrap_dir="$(mktemp -d /tmp/mcstudio-wt.XXXXXX)"
    host_bin="/run/host/usr/bin"
    [ -x "$host_bin/awk" ] || host_bin="/usr/bin"

    host_libs=""
    for d in /run/host/usr/lib64 /run/host/usr/lib /run/host/usr/lib/x86_64-linux-gnu \
             /run/host/lib /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu; do
        [ -d "$d" ] && host_libs="$host_libs:$d"
    done
    host_libs="${host_libs#:}"

    # 找宿主 CA 证书，避免容器内 curl 报 error 77（trust anchors）
    ca_bundle=""
    for f in /run/host/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
             /run/host/etc/ssl/certs/ca-certificates.crt \
             /run/host/etc/pki/tls/certs/ca-bundle.crt \
             /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
             /etc/ssl/certs/ca-certificates.crt; do
        if [ -f "$f" ]; then
            ca_bundle="$f"
            break
        fi
    done

    for tool in awk wget unzip cabextract curl grep; do
        extra=""
        if [ "$tool" = "curl" ] && [ -n "$ca_bundle" ]; then
            extra="export CURL_CA_BUNDLE=\"$ca_bundle\"; "
        fi
        printf '#!/bin/sh\nexport LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n%sexec "%s/%s" "$@"\n' \
            "$host_libs" "$extra" "$host_bin" "$tool" > "$wrap_dir/$tool"
        chmod +x "$wrap_dir/$tool"
    done
    printf '%s' "$wrap_dir"
}

install_deps() {
    [ -x "$PROTON" ]     || die "找不到 Proton: $PROTON"
    [ -x "$RUNTIME_ENTRY" ] || die "找不到 Steam Runtime: $RUNTIME_ENTRY"
    ensure_host_deps

    local cache="$USER_CACHE/winetricks"
    download_if_missing "$cache/dotnet40/dotNetFx40_Full_x86_x64.exe" "$DOTNET40_URL" "$DOTNET40_SHA"
    download_if_missing "$cache/dotnet48/ndp48-x86-x64-allos-enu.exe" "$DOTNET48_URL" "$DOTNET48_SHA"
    download_if_missing "$cache/vcrun2022/vc_redist.x86.exe" "$VCRUN2022_X86_URL" "$VCRUN2022_X86_SHA"
    download_if_missing "$cache/vcrun2022/vc_redist.x64.exe" "$VCRUN2022_X64_URL" "$VCRUN2022_X64_SHA"
    download_if_missing "$cache/ucrtbase2019/vc_redist.x86.exe" "$UCRTBASE2019_X86_URL" "$UCRTBASE2019_X86_SHA"
    download_if_missing "$cache/ucrtbase2019/vc_redist.x64.exe" "$UCRTBASE2019_X64_URL" "$UCRTBASE2019_X64_SHA"

    if [ -z "$WINETRICKS_BIN" ]; then
        if [ -x /run/host/usr/bin/winetricks ]; then
            WINETRICKS_BIN=/run/host/usr/bin/winetricks
        else
            WINETRICKS_BIN=/usr/bin/winetricks
        fi
    fi
    [ -x "$WINETRICKS_BIN" ] || die "找不到 winetricks（可设置 WINETRICKS_BIN）"

    WT_WRAP_DIR="$(make_host_tool_wrappers)"
    trap '[ -n "${WT_WRAP_DIR:-}" ] && rm -rf "$WT_WRAP_DIR"' EXIT

    info "开始安装全部依赖到 $PREFIX: $DEPS_VERBS（约 10-25 分钟，会自动卸载 Wine Mono）"
    export STEAM_COMPAT_DATA_PATH="$STEAM_ROOT/steamapps/compatdata/$APPID"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
    "$RUNTIME_ENTRY" --verb=run -- env \
        PATH="$WT_WRAP_DIR:/run/host/usr/bin:/usr/bin:/bin" \
        WINEPREFIX="$PREFIX" \
        WINE="$WINE_BIN" \
        WINESERVER="$WINE_SERVER" \
        WINELOADER="$WINE_BIN" \
        WINEARCH=win64 \
        WINETRICKS_DOWNLOADER=curl \
        HOME="$REAL_USER_HOME" \
        XDG_CACHE_HOME="$USER_CACHE" \
        WINEDEBUG=fixme-all \
        "$WINETRICKS_BIN" -q $DEPS_VERBS

    trap - EXIT
    [ -n "${WT_WRAP_DIR:-}" ] && rm -rf "$WT_WRAP_DIR"
    WT_WRAP_DIR=""
    info "依赖安装完成: $DEPS_VERBS"
}

verify_dotnet() {
    local reg="$PREFIX/system.reg"
    local mscorlib="$PREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll"
    local ok=1

    if grep -a -q '"Version"="4\.8\.' "$reg" 2>/dev/null; then
        info "注册表: .NET 4.8 已注册"
    else
        warn "注册表里没有 .NET 4.8 Version"
        ok=0
    fi

    if [ -f "$mscorlib" ] && [ "$(stat -c%s "$mscorlib")" -gt 4000000 ]; then
        info "mscorlib.dll: $(stat -c%s "$mscorlib") 字节（微软原版）"
    else
        warn "mscorlib.dll 缺失或仍是 Wine Mono 版本（应 >4MB）"
        ok=0
    fi

    [ "$ok" -eq 1 ] || die ".NET 4.8 验证未通过"
}

verify_deps() {
    verify_dotnet
    if grep -a -q 'Microsoft Visual C++' "$PREFIX/system.reg" 2>/dev/null; then
        info "VC++ 运行库已注册"
    else
        warn "未检测到 VC++ 运行库注册（vcrun2019/vcrun2022 未生效）"
    fi
}

# ==================== 3. 诊断模式 ====================
cmd_check() {
    local vdf
    vdf="$(find_shortcuts_vdf)"

    echo "===== 环境 ====="
    steam_running && echo "Steam: 运行中" || echo "Steam: 已停止"
    [ -x "$PROTON" ] && echo "Proton: $COMPAT_TOOL OK" || echo "Proton: 缺失/未配置"
    [ -x "$RUNTIME_ENTRY" ] && echo "Runtime: $RUNTIME_DIR OK" || echo "Runtime: 缺失/未配置"

    echo
    echo "===== 快捷方式 ====="
    if [ -n "$vdf" ]; then
        echo "文件: $vdf"
        strings "$vdf" | grep -E 'MCStudio\.exe|LaunchOptions' | head -5
    else
        echo "未找到 shortcuts.vdf"
    fi

    echo
    echo "===== .NET Framework ====="
    if grep -a -q '"Version"="4\.8\.' "$PREFIX/system.reg" 2>/dev/null; then
        echo ".NET: 4.8 已安装"
    elif grep -a -q 'winemono\|wine_mono' "$PREFIX/system.reg" 2>/dev/null; then
        echo ".NET: 未安装（当前是 Wine Mono，WPF 应用会崩）"
    else
        echo ".NET: 未安装（也没有 Wine Mono）"
    fi
    ls -la "$PREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll" 2>/dev/null || echo "mscorlib.dll: 不存在"

    echo
    echo "===== 目标程序 ====="
    [ -f "$EXE" ] && echo "MCStudio.exe: 存在" || echo "MCStudio.exe: 不存在 -> $EXE"

    echo
    echo "===== 应用缩放 ====="
    scale_val="$(grep -a '"DpiScaling"=' "$PREFIX/user.reg" 2>/dev/null | head -1 || true)"
    logpix_val="$(grep -a '"LogPixels"=' "$PREFIX/user.reg" 2>/dev/null | head -1 || true)"
    if [ -n "$scale_val" ]; then
        echo "DpiScaling: $scale_val"
    else
        echo "DpiScaling: 未设置（默认 1x）"
    fi
    if [ -n "$logpix_val" ]; then
        echo "LogPixels: $logpix_val"
    else
        echo "LogPixels: 未设置（默认 96）"
    fi
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ==================== 交互式菜单 ====================
pause() {
    # 只有终端交互时才等待回车；管道/脚本调用时直接继续
    if [ -t 0 ]; then
        read -r -p "按回车返回菜单..."
    fi
}

interactive_require_steam_stopped() {
    if ! steam_running; then
        return 0
    fi
    local ans
    read -r -p "Steam 正在运行，修快捷方式前需要关闭它。自动关闭？[y/N]: " ans || ans="n"
    case "$ans" in
        y|Y|yes|YES|是)
            info "关闭 Steam..."
            steam_shutdown
            for _ in $(seq 1 30); do
                steam_running || break
                sleep 2
            done
            ;;
    esac
    if steam_running; then
        warn "Steam 仍在运行，已取消该操作（可稍后手动关闭 Steam 再试）"
        return 1
    fi
    return 0
}

cmd_menu() {
    local choice
    while true; do
        echo
        echo "===== MCStudio Proton 修复工具 ====="
        if steam_running; then
            echo "Steam: 运行中"
        else
            echo "Steam: 已停止"
        fi
        echo
        echo "  1) 诊断当前状态"
        echo "  2) 只修 Steam 快捷方式（需关闭 Steam）"
        echo "  3) 安装全部依赖（.NET 4.8 + VC++ 运行库）"
        echo "  4) 设置应用缩放（当前 ${APP_SCALE}x）"
        echo "  5) 完整修复（快捷方式 + 全部依赖 + 缩放 + 验证）"
        echo "  6) 退出"
        echo
        read -r -p "请选择 [1-6]: " choice || choice="exit"

        case "$choice" in
            1)
                ( cmd_check ) || warn "诊断失败"
                pause
                ;;
            2)
                if interactive_require_steam_stopped; then
                    ( patch_shortcuts ) || warn "快捷方式修复失败"
                    pause
                fi
                ;;
            3)
                ( install_deps && verify_deps ) || warn "依赖安装失败，请查看上方日志"
                pause
                ;;
            4)
                local newscale oldscale="$APP_SCALE"
                read -r -p "输入缩放倍数 [默认 ${APP_SCALE}，如 1 / 1.5 / 2 / 2.5 / 3]: " newscale || newscale=""
                [ -n "$newscale" ] && APP_SCALE="$newscale"
                if set_app_scale; then
                    pause
                else
                    APP_SCALE="$oldscale"
                fi
                ;;
            5)
                if interactive_require_steam_stopped; then
                    if ( patch_shortcuts && install_deps && set_app_scale && verify_deps ); then
                        info "修复完成，现在可以从 Steam 启动 MCStudio 了。"
                    else
                        warn "完整修复未完成，请查看上方日志"
                    fi
                    pause
                fi
                ;;
            6|q|Q|exit)
                echo "再见。"
                return 0
                ;;
            *)
                echo "无效选择: $choice（请输入 1-6）"
                sleep 1
                ;;
        esac
    done
}

# ==================== 主流程 ====================
case "${1:-}" in
    --check)        cmd_check ;;
    --menu|-i)      cmd_menu ;;
    --scale)
        [ $# -ge 2 ] || die "用法: --scale <倍数>（如 1 / 1.5 / 2）"
        APP_SCALE="$2"
        set_app_scale || exit 1
        ;;
    --install-host-deps)
        install_host_deps
        ;;
    --shortcut-only) ensure_steam_stopped; patch_shortcuts ;;
    --deps-only|--dotnet-only)
        install_deps
        verify_deps
        ;;
    --stop-steam)
        if steam_running; then
            info "关闭 Steam..."
            steam_shutdown
            for _ in $(seq 1 30); do
                steam_running || break
                sleep 2
            done
            steam_running && die "Steam 未能退出，请手动关闭后重试"
        fi
        ensure_steam_stopped
        patch_shortcuts
        install_deps
        set_app_scale
        verify_deps
        ;;
    -h|--help)      usage ;;
    "")             cmd_menu ;;
    *)
        die "未知参数: $1（用 --help 查看用法）"
        ;;
esac
