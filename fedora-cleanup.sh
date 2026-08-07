#!/usr/bin/env bash
# =============================================================================
# Fedora 包管理器清理脚本
# =============================================================================
# 清理项目：
#   1. snap 完全移除（应用 + snapd + 残留目录）
#   2. apm/amber + spark-store COPR（星火商店生态）
#   3. python2 COPR 仓库禁用
#   4. 旧内核清理（保留当前运行 + 最新 1 个）
#   5. /etc/yum.repos.d/*.bak 备份文件
#   6. google-chrome.repo（若禁用且未安装 chrome）
#   7. dnf.conf 优化（max_parallel_downloads + installonly_limit）
#
# 用法：
#   ./fedora-cleanup.sh          # 交互模式（默认）
#   ./fedora-cleanup.sh --yes    # 跳过所有确认（谨慎）
#   ./fedora-cleanup.sh --check  # 仅检测，不执行任何操作
#
# 兼容：Fedora 40+ (dnf5)
# =============================================================================

set -euo pipefail

# ---------- 颜色与日志 ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
title() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }

# ---------- 全局变量 ----------
ASSUME_YES=0
CHECK_ONLY=0
SAVED_SPACE=0

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --check|--dry-run) CHECK_ONLY=1; ASSUME_YES=1; shift ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

# ---------- 确认函数 ----------
confirm() {
    if [[ $ASSUME_YES -eq 1 ]]; then
        echo -e "  ${YELLOW}[自动确认]${NC} $1"
        return 0
    fi
    local answer
    read -r -p "  $1 [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

dry_run_note() {
    [[ $CHECK_ONLY -eq 1 ]] && echo -e "  ${YELLOW}[仅检测模式，不执行]${NC}"
}

# ---------- 前置检查 ----------
preflight() {
    title "前置检查"

    # --check 模式不需要 sudo（只检测不执行）
    if [[ $CHECK_ONLY -eq 1 ]]; then
        SUDO="sudo"
        log "检测模式：跳过 sudo（如需执行请用普通模式）"
    elif [[ $EUID -ne 0 ]]; then
        if ! sudo -n true 2>/dev/null; then
            info "需要 sudo 权限，请输入密码（缓存 5 分钟）"
            sudo -v || { err "无法获取 sudo 权限"; exit 1; }
        fi
        SUDO="sudo"
    else
        SUDO=""
    fi
    [[ $CHECK_ONLY -eq 0 ]] && log "权限检查通过"

    # 必须是 Fedora
    if ! grep -qE '^ID=fedora' /etc/os-release 2>/dev/null; then
        err "此脚本仅适用于 Fedora，检测到：$(grep '^ID=' /etc/os-release 2>/dev/null || echo '未知')"
        exit 1
    fi
    local fedora_ver
    fedora_ver=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2)
    log "系统：Fedora $fedora_ver"

    # dnf5 检查
    if ! command -v dnf &>/dev/null; then
        err "未找到 dnf 命令，无法继续"
        exit 1
    fi
    log "dnf 可用：$(dnf --version 2>/dev/null | head -1)"
}

# =============================================================================
# 模块 1：snap 完全移除
# =============================================================================
clean_snap() {
    title "1. snap 清理"

    # 检测 snap 是否存在
    if ! command -v snap &>/dev/null && ! rpm -q snapd &>/dev/null; then
        log "snap 未安装，跳过"
        return 0
    fi
    info "检测到 snap：$(rpm -q snapd 2>/dev/null || echo '已安装')"

    # 列出已安装的 snap 应用
    local snap_apps
    snap_apps=$(snap list 2>/dev/null | awk 'NR>1 && $1!="bare" && $1!="core" && $1!="core18" && $1!="core20" && $1!="core22" && $1!="core24" && !/snapd/ {print $1}')
    if [[ -n "$snap_apps" ]]; then
        echo "  已安装的 snap 应用："
        echo "$snap_apps" | sed 's/^/    - /'
    fi

    dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
    confirm "是否完全移除 snap（含所有应用 + snapd + 残留目录）？" || return 0

    # 1.1 卸载 snap 应用
    if [[ -n "$snap_apps" ]]; then
        info "卸载 snap 应用..."
        echo "$snap_apps" | xargs -r $SUDO snap remove 2>&1 | sed 's/^/    /' || true
    fi

    # 1.2 卸载 base snap
    info "卸载 base snap..."
    for s in gnome-*-2404 mesa-2404 gtk-common-themes core24 core20 core18 core bare; do
        $SUDO snap remove "$s" 2>/dev/null && log "  删除 $s" || true
    done

    # 1.3 停止并禁用 snapd 服务
    info "禁用 snapd 服务..."
    $SUDO systemctl disable --now snapd.socket snapd.service 2>/dev/null || true

    # 1.4 dnf 卸载 snapd 相关 RPM（保留 snappy，ffmpeg 依赖它）
    info "dnf 移除 snapd RPM..."
    local snap_rpms
    snap_rpms=$(rpm -qa | grep -iE '^(snapd|snapd-glib|snapd-qt|snapd-selinux|snap-confine|plasma-discover-snap)$' || true)
    if [[ -n "$snap_rpms" ]]; then
        $SUDO dnf remove -y $snap_rpms 2>&1 | tail -5 | sed 's/^/    /'
    fi

    # 1.5 清理残留目录
    info "清理残留目录..."
    $SUDO rm -rf /var/lib/snapd /var/snap /snap /var/cache/snapd 2>/dev/null || true
    rm -rf ~/snap 2>/dev/null || true

    # 验证
    if ! command -v snap &>/dev/null && ! rpm -q snapd &>/dev/null; then
        log "snap 已完全移除"
    else
        warn "snap 移除可能不完整，请检查"
    fi
}

# =============================================================================
# 模块 2：apm/amber + spark-store 清理
# =============================================================================
clean_apm_amber() {
    title "2. apm/amber + spark-store 清理"

    local has_apm=0 has_spark=0
    rpm -q amber-package-manager &>/dev/null && has_apm=1
    rpm -q spark-store &>/dev/null && has_spark=1
    [[ -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:xmp360:spark-store.repo ]] && has_spark=1

    if [[ $has_apm -eq 0 && $has_spark -eq 0 ]]; then
        log "未检测到 amber/spark-store，跳过"
        return 0
    fi

    info "检测到："
    [[ $has_apm -eq 1 ]] && echo "    - amber-package-manager（apm 命令）"
    [[ $has_spark -eq 1 ]] && echo "    - spark-store COPR 仓库"

    # 列出 apm 已安装的应用
    if [[ $has_apm -eq 1 ]] && command -v apm &>/dev/null; then
        local apm_apps
        apm_apps=$(apm list 2>/dev/null | grep '\[installed' | grep -vE 'amber-pm-(bookworm|deepin|trixie)|^apm/' || true)
        if [[ -n "$apm_apps" ]]; then
            echo "  apm 已安装的应用："
            echo "$apm_apps" | awk '{print "    - " $1}' | sed 's|/.*||'
        fi
    fi

    dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
    confirm "是否移除 amber/spark-store 生态（含所有 apm 应用 + COPR 仓库）？" || return 0

    # 2.1 用 apm remove 卸载应用
    if [[ $has_apm -eq 1 ]] && command -v apm &>/dev/null; then
        info "卸载 apm 应用..."
        local apps_to_remove
        apps_to_remove=$(apm list 2>/dev/null | grep '\[installed' | awk -F/ '{print $1}' | grep -vE '^apm$|^amber-pm-' || true)
        if [[ -n "$apps_to_remove" ]]; then
            $SUDO apm remove $apps_to_remove 2>&1 | tail -10 | sed 's/^/    /' || true
        fi
    fi

    # 2.2 停用 apm systemd 服务
    info "禁用 apm systemd 服务..."
    $SUDO systemctl disable --now apm-daily-update.timer apm-daily-update.service gxde-apm-fixer.service 2>/dev/null || true

    # 2.3 dnf 卸载 RPM
    info "dnf 移除 amber-package-manager + spark-store..."
    local apm_rpms=""
    rpm -q amber-package-manager &>/dev/null && apm_rpms="$apm_rpms amber-package-manager"
    rpm -q spark-store &>/dev/null && apm_rpms="$apm_rpms spark-store"
    if [[ -n "$apm_rpms" ]]; then
        $SUDO dnf remove -y $apm_rpms 2>&1 | tail -5 | sed 's/^/    /'
    fi

    # 2.4 删除 spark-store COPR 仓库文件
    info "删除 spark-store COPR 仓库..."
    $SUDO rm -f '/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:xmp360:spark-store.repo' 2>/dev/null && log "  COPR 仓库已删除"

    # 2.5 清理残留目录
    info "清理残留..."
    $SUDO rm -rf /usr/local/share/applications/apm 2>/dev/null || true
    # /var/lib/apm /opt/durapps 等由 %postun 自动清理，此处兜底
    $SUDO rm -rf /var/lib/apm /opt/durapps 2>/dev/null || true

    # 验证
    local clean=1
    rpm -q amber-package-manager &>/dev/null && clean=0
    rpm -q spark-store &>/dev/null && clean=0
    [[ -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:xmp360:spark-store.repo ]] && clean=0
    [[ $clean -eq 1 ]] && log "amber/spark-store 已完全移除" || warn "amber/spark-store 移除可能不完整"
}

# =============================================================================
# 模块 3：python2 COPR 禁用
# =============================================================================
clean_python2_copr() {
    title "3. python2 COPR 仓库禁用"

    local repo_file='/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:sergiomb:python2.repo'
    if [[ ! -f "$repo_file" ]]; then
        log "未检测到 python2 COPR，跳过"
        return 0
    fi
    info "检测到 python2 COPR 仓库"

    # 检查是否装了 python2.7
    local py2_installed=""
    rpm -q python2.7 &>/dev/null && py2_installed="python2.7"

    dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
    if confirm "是否禁用并删除 python2 COPR 仓库？${py2_installed:+（注意：系统装有 $py2_installed，将变为冻结状态不再更新）}"; then
        $SUDO rm -f "$repo_file" && log "python2 COPR 仓库已删除"
        $SUDO dnf clean all 2>&1 | tail -1 | sed 's/^/    /'

        # 询问是否卸载 python2.7
        if [[ -n "$py2_installed" ]]; then
            if confirm "  是否一并卸载孤立的 $py2_installed？（无任何包依赖它）"; then
                $SUDO dnf remove -y "$py2_installed" 2>&1 | tail -3 | sed 's/^/    /'
                log "$py2_installed 已卸载"
            else
                info "$py2_installed 已保留（冻结状态）"
            fi
        fi
    fi
}

# =============================================================================
# 模块 4：旧内核清理
# =============================================================================
clean_old_kernels() {
    title "4. 旧内核清理"

    local current_kernel
    current_kernel=$(uname -r)
    info "当前运行内核：$current_kernel"

    # 列出所有已安装的 kernel-core 版本（每个内核版本的标志）
    local all_kernels
    all_kernels=$(rpm -qa --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null | sort -V || true)

    if [[ -z "$all_kernels" ]]; then
        warn "未找到 kernel-core 包"
        return 0
    fi

    local kernel_count
    kernel_count=$(echo "$all_kernels" | wc -l)
    info "已安装内核数量：$kernel_count"
    echo "$all_kernels" | sed 's/^/    - /'

    if [[ $kernel_count -le 2 ]]; then
        log "内核数量 ≤ 2，无需清理"
        return 0
    fi

    # 识别要删除的内核：排除当前运行的，排除最新的 1 个
    local newest_kernel
    newest_kernel=$(echo "$all_kernels" | tail -1)

    local to_remove=()
    while IFS= read -r k; do
        if [[ "$k" != "$current_kernel" && "$k" != "$newest_kernel" ]]; then
            to_remove+=("$k")
        fi
    done <<< "$all_kernels"

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        log "无可清理的旧内核（保留当前 + 最新）"
        return 0
    fi

    echo "  将删除的旧内核："
    printf '    - %s\n' "${to_remove[@]}"
    echo "  保留：当前运行（$current_kernel）+ 最新（$newest_kernel）"

    dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
    confirm "是否删除上述 ${#to_remove[@]} 个旧内核？" || return 0

    # 删除每个旧内核的 kernel-core（会连带删除同版本的 kernel/kernel-modules 等）
    for k in "${to_remove[@]}"; do
        info "删除内核 $k ..."
        $SUDO dnf remove -y "kernel-core-$k" 2>&1 | tail -2 | sed 's/^/    /' || warn "  删除 $k 失败"
    done

    # 清理可能残留的 kernel-devel（不依赖 kernel-core，需单独删）
    for k in "${to_remove[@]}"; do
        if rpm -q "kernel-devel-$k" &>/dev/null; then
            info "清理残留 kernel-devel-$k"
            $SUDO dnf remove -y "kernel-devel-$k" 2>&1 | tail -1 | sed 's/^/    /' || true
        fi
    done

    log "旧内核清理完成"
    info "当前引导项："
    $SUDO kernel-install list 2>/dev/null | awk 'NR>1 {print "    - " $1}' || true
}

# =============================================================================
# 模块 5：.bak 备份文件清理
# =============================================================================
clean_bak_files() {
    title "5. .bak 备份文件清理"

    local bak_files
    bak_files=$(ls /etc/yum.repos.d/*.bak 2>/dev/null || true)

    if [[ -z "$bak_files" ]]; then
        log "未检测到 .bak 文件，跳过"
        return 0
    fi

    info "检测到 .bak 文件："
    echo "$bak_files" | sed 's/^/    - /'

    dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
    confirm "是否删除这些 .bak 文件？" || return 0

    $SUDO rm -f /etc/yum.repos.d/*.bak
    log ".bak 文件已删除"
}

# =============================================================================
# 模块 6：google-chrome.repo 清理
# =============================================================================
clean_google_chrome_repo() {
    title "6. google-chrome.repo 清理"

    local repo_file='/etc/yum.repos.d/google-chrome.repo'
    if [[ ! -f "$repo_file" ]]; then
        log "未检测到 google-chrome.repo，跳过"
        return 0
    fi

    # 检查是否启用 + 是否安装了 chrome
    local is_enabled=0
    grep -qE '^\s*enabled\s*=\s*1' "$repo_file" 2>/dev/null && is_enabled=1
    local chrome_installed=0
    rpm -q google-chrome-stable &>/dev/null && chrome_installed=1

    info "检测到 google-chrome.repo（$([[ $is_enabled -eq 1 ]] && echo '已启用' || echo '已禁用')）"
    if [[ $chrome_installed -eq 1 ]]; then
        warn "系统已安装 google-chrome-stable，建议保留仓库以获取更新"
        confirm "仍要删除？" || return 0
    else
        dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
        confirm "google-chrome-stable 未安装，是否删除此仓库文件？" || return 0
    fi

    $SUDO rm -f "$repo_file" && log "google-chrome.repo 已删除"
}

# =============================================================================
# 模块 7：dnf.conf 优化
# =============================================================================
optimize_dnf_conf() {
    title "7. dnf.conf 优化"

    local conf='/etc/dnf/dnf.conf'
    local changed=0

    # 检查各项是否已存在
    local has_parallel=0 has_limit=0
    grep -qE '^\s*max_parallel_downloads\s*=' "$conf" 2>/dev/null && has_parallel=1
    grep -qE '^\s*installonly_limit\s*=' "$conf" 2>/dev/null && has_limit=1

    if [[ $has_parallel -eq 1 && $has_limit -eq 1 ]]; then
        log "dnf.conf 已包含优化项，跳过"
        return 0
    fi

    info "将添加以下配置项："
    [[ $has_parallel -eq 0 ]] && echo "    max_parallel_downloads=10    # 并行下载，提升速度"
    [[ $has_limit -eq 0 ]] && echo "    installonly_limit=3          # 保留 3 个内核版本"

    dry_run_note && { [[ $CHECK_ONLY -eq 1 ]] && return 0; }
    confirm "是否写入 dnf.conf 优化项？" || return 0

    # 备份
    $SUDO cp "$conf" "${conf}.bak.$(date +%s)"

    # 确保 [main] 存在
    if ! grep -qE '^\[main\]' "$conf" 2>/dev/null; then
        echo '[main]' | $SUDO tee -a "$conf" >/dev/null
    fi

    # 追加缺失的配置项
    [[ $has_parallel -eq 0 ]] && echo 'max_parallel_downloads=10' | $SUDO tee -a "$conf" >/dev/null && changed=1
    [[ $has_limit -eq 0 ]] && echo 'installonly_limit=3' | $SUDO tee -a "$conf" >/dev/null && changed=1

    [[ $changed -eq 1 ]] && log "dnf.conf 已优化" || log "无变更"
}

# =============================================================================
# 总结
# =============================================================================
summary() {
    title "清理总结"
    info "包管理器现状："
    echo "    - dnf5 + rpm    (Fedora 官方)"
    command -v flatpak &>/dev/null && echo "    - flatpak        (Flathub)"
    command -v uv &>/dev/null && echo "    - uv             (Python, Fedora 官方 RPM)"
    command -v pip &>/dev/null && echo "    - pip            (Python 备用)"

    echo
    info "建议后续操作："
    echo "    - 重新登录或新开终端，让 PATH 环境变量刷新"
    echo "    - 如需释放更多空间：sudo dnf clean all"
    echo "    - 检查残留 COPR：ls /etc/yum.repos.d/_copr*"
    echo
    log "清理完成！"
}

# =============================================================================
# 主函数
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          Fedora 包管理器清理脚本                          ║"
    echo "║          适用于 Fedora 40+ (dnf5)                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    [[ $CHECK_ONLY -eq 1 ]] && warn "运行于【仅检测模式】，不会执行任何修改"

    preflight

    clean_snap
    clean_apm_amber
    clean_python2_copr
    clean_old_kernels
    clean_bak_files
    clean_google_chrome_repo
    optimize_dnf_conf

    summary
}

main "$@"
