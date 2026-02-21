#!/usr/bin/env bash
#
# OpenClaw macOS 一键安装脚本
# 基于 sam_manual/mac_manual.md 编写
#
# 用法:
#   bash install-openclaw.sh [选项]
#
# 选项:
#   --skip-onboard     仅安装 CLI，不运行引导向导
#   --use-pnpm         使用 pnpm 安装（默认使用 npm）
#   --install-node     自动安装 Node.js（通过 Homebrew）
#   --channel <ch>     安装渠道: stable(默认) / beta / dev
#   --verbose          打印更详细的日志到终端
#   --help             显示帮助信息
#
# 日志文件:
#   安装日志自动保存到脚本同目录下的 openclaw-install-<时间戳>.log
#

set -euo pipefail

# ─────────────────────────────────────────────
# 颜色定义
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# ─────────────────────────────────────────────
# 全局变量
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${SCRIPT_DIR}/openclaw-install-${TIMESTAMP}.log"
REQUIRED_NODE_MAJOR=22
SKIP_ONBOARD=false
USE_PNPM=false
AUTO_INSTALL_NODE=false
CHANNEL="stable"
VERBOSE=false

# 安装结果追踪
INSTALL_SUCCESS=false
STEPS_COMPLETED=0
STEPS_TOTAL=0

# ─────────────────────────────────────────────
# 日志函数
# ─────────────────────────────────────────────
_log_raw() {
    echo "$1" >> "$LOG_FILE"
}

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"
    _log_raw "$msg"
    echo -e "${BLUE}ℹ${NC}  $*"
}

log_success() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"
    _log_raw "$msg"
    echo -e "${GREEN}✔${NC}  $*"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"
    _log_raw "$msg"
    echo -e "${YELLOW}⚠${NC}  $*"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    _log_raw "$msg"
    echo -e "${RED}✖${NC}  $*" >&2
}

log_step() {
    STEPS_COMPLETED=$((STEPS_COMPLETED + 1))
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [STEP ${STEPS_COMPLETED}/${STEPS_TOTAL}] $*"
    _log_raw "$msg"
    echo ""
    echo -e "${BOLD}${CYAN}[$STEPS_COMPLETED/$STEPS_TOTAL]${NC} ${BOLD}$*${NC}"
}

log_debug() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    _log_raw "$msg"
    if [[ "$VERBOSE" == true ]]; then
        echo -e "  ${CYAN}→${NC} $*"
    fi
}

# ─────────────────────────────────────────────
# Spinner / 进度动画
# ─────────────────────────────────────────────
# 在后台显示旋转动画 + 已用时间，直到目标进程结束
# 用法: start_spinner "描述文字"  →  返回 spinner PID（存入 SPINNER_PID）
#       stop_spinner               →  停止动画并清行
SPINNER_PID=""
_spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

start_spinner() {
    local msg="${1:-请稍候...}"
    # 确保之前的 spinner 已停止
    stop_spinner 2>/dev/null || true
    (
        local i=0
        local start_ts=$SECONDS
        local len=${#_spinner_chars}
        while true; do
            local elapsed=$(( SECONDS - start_ts ))
            local ch="${_spinner_chars:$((i % len)):1}"
            # \r 回到行首, \033[K 清除到行尾
            printf "\r  ${CYAN}%s${NC}  %s ${YELLOW}(%ds)${NC}\033[K" "$ch" "$msg" "$elapsed"
            sleep 0.12
            i=$((i + 1))
        done
    ) &
    SPINNER_PID=$!
    # 禁止 spinner 子进程的 job-control 消息
    disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        # 清除 spinner 行
        printf "\r\033[K"
    fi
}

# 运行耗时命令，自动显示 spinner 动画
# 用法: run_with_spinner "描述文字" 命令 [参数...]
# 输出保存到 RUN_OUTPUT 变量，返回命令退出码
RUN_OUTPUT=""
run_with_spinner() {
    local description="$1"
    shift
    log_debug "执行命令: $*"

    local tmpfile
    tmpfile=$(mktemp /tmp/openclaw-cmd-XXXXXX)

    start_spinner "$description"

    local exit_code=0
    "$@" > "$tmpfile" 2>&1 || exit_code=$?

    stop_spinner

    RUN_OUTPUT=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [[ -n "$RUN_OUTPUT" ]]; then
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [CMD]   [$description] 输出:"
        _log_raw "$RUN_OUTPUT"
    fi
    if [[ $exit_code -ne 0 ]]; then
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [CMD]   [$description] 退出码: $exit_code"
    fi
    if [[ "$VERBOSE" == true && -n "$RUN_OUTPUT" ]]; then
        echo "$RUN_OUTPUT" | while IFS= read -r line; do
            echo -e "     ${line}"
        done
    fi

    return $exit_code
}

# 执行命令并记录输出到日志（快速命令，不显示 spinner）
run_cmd() {
    local description="$1"
    shift
    log_debug "执行命令: $*"
    local output
    local exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    if [[ -n "$output" ]]; then
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [CMD]   [$description] 输出:"
        _log_raw "$output"
    fi
    if [[ $exit_code -ne 0 ]]; then
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [CMD]   [$description] 退出码: $exit_code"
    fi
    if [[ "$VERBOSE" == true && -n "$output" ]]; then
        echo "$output" | while IFS= read -r line; do
            echo -e "     ${line}"
        done
    fi
    echo "$output"
    return $exit_code
}

# ─────────────────────────────────────────────
# 帮助信息
# ─────────────────────────────────────────────
show_help() {
    cat << 'HELP'
╔══════════════════════════════════════════════════╗
║      OpenClaw macOS 一键安装脚本                 ║
╚══════════════════════════════════════════════════╝

用法:
  bash install-openclaw.sh [选项]

选项:
  --skip-onboard     仅安装 CLI，不运行引导向导
  --use-pnpm         使用 pnpm 安装（默认使用 npm）
  --install-node     如果 Node.js 不满足要求，自动通过 Homebrew 安装
  --channel <ch>     安装渠道: stable(默认) / beta / dev
  --verbose          打印详细日志到终端
  --help             显示此帮助信息

示例:
  # 默认安装（npm + 引导向导）
  bash install-openclaw.sh

  # 使用 pnpm 安装，跳过引导
  bash install-openclaw.sh --use-pnpm --skip-onboard

  # 自动安装 Node.js 并进入引导向导
  bash install-openclaw.sh --install-node

  # 安装 beta 渠道
  bash install-openclaw.sh --channel beta

日志:
  安装日志自动保存到脚本同目录下，文件名格式:
  openclaw-install-<YYYYMMDD_HHMMSS>.log

HELP
    exit 0
}

# ─────────────────────────────────────────────
# 参数解析
# ─────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-onboard)
                SKIP_ONBOARD=true
                shift
                ;;
            --use-pnpm)
                USE_PNPM=true
                shift
                ;;
            --install-node)
                AUTO_INSTALL_NODE=true
                shift
                ;;
            --channel)
                if [[ -n "${2:-}" ]]; then
                    CHANNEL="$2"
                    shift 2
                else
                    log_error "--channel 需要参数 (stable/beta/dev)"
                    exit 1
                fi
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                log_error "未知选项: $1（使用 --help 查看帮助）"
                exit 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────
# 系统信息收集（写入日志）
# ─────────────────────────────────────────────
collect_system_info() {
    _log_raw "═══════════════════════════════════════════════"
    _log_raw "  OpenClaw macOS 安装日志"
    _log_raw "  开始时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    _log_raw "═══════════════════════════════════════════════"
    _log_raw ""
    _log_raw "[系统信息]"
    _log_raw "  主机名:      $(hostname)"
    _log_raw "  用户:        $(whoami)"
    _log_raw "  macOS 版本:  $(sw_vers -productVersion 2>/dev/null || echo '未知')"
    _log_raw "  构建版本:    $(sw_vers -buildVersion 2>/dev/null || echo '未知')"
    _log_raw "  架构:        $(uname -m)"
    _log_raw "  内核:        $(uname -r)"
    _log_raw "  Shell:       $SHELL ($(bash --version | head -1))"
    _log_raw "  磁盘可用:    $(df -h / | tail -1 | awk '{print $4}')"
    _log_raw ""
    _log_raw "[安装选项]"
    _log_raw "  包管理器:    $(if $USE_PNPM; then echo 'pnpm'; else echo 'npm'; fi)"
    _log_raw "  安装渠道:    $CHANNEL"
    _log_raw "  跳过引导:    $SKIP_ONBOARD"
    _log_raw "  自动安装Node: $AUTO_INSTALL_NODE"
    _log_raw "  详细模式:    $VERBOSE"
    _log_raw ""

    # 记录已安装工具的版本
    _log_raw "[已安装工具]"
    for tool in node npm pnpm brew git xcode-select; do
        if command -v "$tool" &>/dev/null; then
            local ver
            case "$tool" in
                xcode-select) ver=$(xcode-select --version 2>/dev/null || echo "已安装") ;;
                *) ver=$($tool --version 2>/dev/null || echo "版本未知") ;;
            esac
            _log_raw "  $tool: $ver"
        else
            _log_raw "  $tool: 未安装"
        fi
    done
    _log_raw ""

    # 记录 PATH
    _log_raw "[PATH 环境变量]"
    echo "$PATH" | tr ':' '\n' | while IFS= read -r p; do
        _log_raw "  $p"
    done
    _log_raw ""

    # 记录相关环境变量
    _log_raw "[相关环境变量]"
    for var in NODE_OPTIONS NVM_DIR SHARP_IGNORE_GLOBAL_LIBVIPS npm_config_prefix; do
        _log_raw "  $var=${!var:-<未设置>}"
    done
    _log_raw ""
}

# ─────────────────────────────────────────────
# 环境检测
# ─────────────────────────────────────────────

check_macos() {
    log_step "检测操作系统"

    local os_name
    os_name="$(uname -s)"
    if [[ "$os_name" != "Darwin" ]]; then
        log_error "此脚本仅支持 macOS，当前系统: $os_name"
        log_error "请参考 OpenClaw 文档获取其他系统的安装方式: https://docs.openclaw.ai"
        return 1
    fi

    local macos_ver
    macos_ver="$(sw_vers -productVersion)"
    local arch
    arch="$(uname -m)"

    log_success "macOS $macos_ver ($arch)"
    log_debug "完整内核: $(uname -a)"

    # 检查最低 macOS 版本（建议 13+，Ventura）
    local major_ver
    major_ver=$(echo "$macos_ver" | cut -d. -f1)
    if [[ "$major_ver" -lt 13 ]]; then
        log_warn "macOS 版本较低 ($macos_ver)，建议升级到 macOS 13 (Ventura) 或更高版本"
        log_warn "某些功能（语音唤醒等）可能不可用"
    fi
}

check_xcode_clt() {
    log_step "检测 Xcode Command Line Tools"

    if xcode-select -p &>/dev/null; then
        local clt_path
        clt_path="$(xcode-select -p)"
        log_success "已安装: $clt_path"
        log_debug "版本: $(xcode-select --version 2>/dev/null || echo '未知')"
    else
        log_warn "Xcode Command Line Tools 未安装"
        log_info "正在安装 Xcode Command Line Tools（可能需要几分钟）..."
        log_info "如果弹出安装对话框，请点击「安装」并等待完成"

        xcode-select --install 2>/dev/null || true

        # 等待用户完成安装
        echo ""
        echo -e "${YELLOW}请在弹出的对话框中点击「安装」，完成后按 Enter 继续...${NC}"
        read -r

        if xcode-select -p &>/dev/null; then
            log_success "Xcode Command Line Tools 安装完成"
        else
            log_error "Xcode Command Line Tools 安装失败"
            log_error "请手动运行: xcode-select --install"
            return 1
        fi
    fi
}

check_homebrew() {
    log_step "检测 Homebrew"

    if command -v brew &>/dev/null; then
        local brew_ver
        brew_ver="$(brew --version | head -1)"
        log_success "已安装: $brew_ver"
        log_debug "Homebrew 路径: $(which brew)"
    else
        log_warn "Homebrew 未安装"
        if [[ "$AUTO_INSTALL_NODE" == true ]]; then
            log_info "需要 Homebrew 来安装 Node.js，正在安装..."
            install_homebrew
        else
            log_warn "如果需要自动安装 Node.js，请先安装 Homebrew:"
            log_warn "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            log_warn "或使用 --install-node 选项自动安装"
        fi
    fi
}

install_homebrew() {
    log_info "正在安装 Homebrew（可能需要几分钟）..."
    _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [INSTALL] 开始安装 Homebrew"

    # Homebrew 安装脚本需要特殊处理（它自带交互），用 spinner 包裹 curl+bash
    local brew_script
    brew_script=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    if run_with_spinner "安装 Homebrew" /bin/bash -c "$brew_script"; then
        # Apple Silicon 上 Homebrew 安装到 /opt/homebrew
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        log_success "Homebrew 安装完成"
    else
        log_error "Homebrew 安装失败，请查看日志: $LOG_FILE"
        return 1
    fi
}

check_node() {
    log_step "检测 Node.js (要求 ≥${REQUIRED_NODE_MAJOR})"

    if command -v node &>/dev/null; then
        local node_ver
        node_ver="$(node --version)"
        local node_major
        node_major=$(echo "$node_ver" | sed 's/^v//' | cut -d. -f1)

        log_debug "Node.js 版本: $node_ver (主版本: $node_major)"
        log_debug "Node.js 路径: $(which node)"

        if [[ "$node_major" -ge "$REQUIRED_NODE_MAJOR" ]]; then
            log_success "Node.js $node_ver ✓"
            return 0
        else
            log_error "Node.js 版本过低: ${node_ver}（需要 ≥${REQUIRED_NODE_MAJOR}）"
            if [[ "$AUTO_INSTALL_NODE" == true ]]; then
                install_node
                return $?
            else
                log_error "请升级 Node.js 到 v${REQUIRED_NODE_MAJOR} 或更高版本"
                log_info "方法1: 使用 --install-node 选项自动安装"
                log_info "方法2: brew install node@${REQUIRED_NODE_MAJOR}"
                log_info "方法3: 使用 nvm - nvm install ${REQUIRED_NODE_MAJOR}"
                log_info "方法4: 访问 https://nodejs.org 下载安装"
                return 1
            fi
        fi
    else
        log_error "Node.js 未安装"
        if [[ "$AUTO_INSTALL_NODE" == true ]]; then
            install_node
            return $?
        else
            log_error "OpenClaw 需要 Node.js ≥${REQUIRED_NODE_MAJOR}"
            log_info "方法1: 使用 --install-node 选项自动安装"
            log_info "方法2: brew install node@${REQUIRED_NODE_MAJOR}"
            log_info "方法3: 使用 nvm - nvm install ${REQUIRED_NODE_MAJOR}"
            log_info "方法4: 访问 https://nodejs.org 下载安装"
            return 1
        fi
    fi
}

install_node() {
    log_info "正在通过 Homebrew 安装 Node.js ${REQUIRED_NODE_MAJOR}..."
    _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [INSTALL] 开始安装 Node.js"

    if ! command -v brew &>/dev/null; then
        log_error "Homebrew 不可用，无法自动安装 Node.js"
        return 1
    fi

    if run_with_spinner "brew install node@${REQUIRED_NODE_MAJOR}（下载 + 编译中）" brew install "node@${REQUIRED_NODE_MAJOR}"; then
        # node@22 是 keg-only，需要链接
        brew link --overwrite "node@${REQUIRED_NODE_MAJOR}" >> "$LOG_FILE" 2>&1 || true

        # 刷新 PATH
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        export PATH="/opt/homebrew/opt/node@${REQUIRED_NODE_MAJOR}/bin:$PATH"

        if command -v node &>/dev/null; then
            local new_ver
            new_ver="$(node --version)"
            log_success "Node.js 安装完成: $new_ver"

            # 提示用户添加到 shell 配置
            log_info "建议将以下内容添加到 ~/.zshrc 以便后续使用:"
            log_info "  export PATH=\"/opt/homebrew/opt/node@${REQUIRED_NODE_MAJOR}/bin:\$PATH\""
        else
            log_error "Node.js 安装后无法找到 node 命令"
            return 1
        fi
    else
        log_error "Node.js 安装失败，请查看日志: $LOG_FILE"
        return 1
    fi
}

check_npm_or_pnpm() {
    log_step "检测包管理器"

    if [[ "$USE_PNPM" == true ]]; then
        if command -v pnpm &>/dev/null; then
            local pnpm_ver
            pnpm_ver="$(pnpm --version)"
            log_success "pnpm $pnpm_ver"
            log_debug "pnpm 路径: $(which pnpm)"
        else
            log_warn "pnpm 未安装，正在安装..."
            if npm install -g pnpm >> "$LOG_FILE" 2>&1; then
                log_success "pnpm 安装完成: $(pnpm --version)"
            else
                log_error "pnpm 安装失败，回退到 npm"
                USE_PNPM=false
            fi
        fi
    fi

    # 无论是否使用 pnpm，都检查 npm
    if command -v npm &>/dev/null; then
        local npm_ver
        npm_ver="$(npm --version)"
        log_success "npm $npm_ver"
        log_debug "npm 路径: $(which npm)"
        log_debug "npm 全局前缀: $(npm prefix -g 2>/dev/null || echo '未知')"
    else
        log_error "npm 未找到（这不应该发生，因为 Node.js 已安装）"
        if [[ "$USE_PNPM" != true ]]; then
            return 1
        fi
    fi
}

check_network() {
    log_step "检测网络连接"

    # 测试 npm registry 连通性
    log_debug "测试 registry.npmjs.org 连通性..."
    if curl -fsSL --connect-timeout 10 --max-time 15 "https://registry.npmjs.org/openclaw" > /dev/null 2>&1; then
        log_success "npm 仓库连接正常"
    else
        log_warn "无法连接到 npm 仓库 (registry.npmjs.org)"
        log_warn "请检查网络连接或代理设置"

        # 检查是否设置了代理
        local npm_proxy
        npm_proxy="$(npm config get proxy 2>/dev/null || true)"
        if [[ -n "$npm_proxy" && "$npm_proxy" != "null" ]]; then
            log_debug "npm 代理: $npm_proxy"
        fi

        local https_proxy_val="${https_proxy:-${HTTPS_PROXY:-}}"
        if [[ -n "$https_proxy_val" ]]; then
            log_debug "HTTPS_PROXY: $https_proxy_val"
        fi
    fi

    # 测试 openclaw.ai 连通性
    log_debug "测试 openclaw.ai 连通性..."
    if curl -fsSL --connect-timeout 10 --max-time 15 "https://openclaw.ai" > /dev/null 2>&1; then
        log_success "openclaw.ai 连接正常"
    else
        log_warn "无法连接到 openclaw.ai（不影响 npm 安装）"
    fi
}

check_disk_space() {
    log_step "检测磁盘空间"

    local available_kb
    available_kb=$(df -k / | tail -1 | awk '{print $4}')
    local available_gb
    available_gb=$((available_kb / 1024 / 1024))
    local available_mb
    available_mb=$((available_kb / 1024))

    log_debug "可用空间: ${available_mb} MB (${available_gb} GB)"

    # OpenClaw 安装大约需要 500MB
    if [[ "$available_mb" -lt 500 ]]; then
        log_error "磁盘空间不足: 仅剩 ${available_mb} MB（建议至少 500 MB）"
        return 1
    elif [[ "$available_mb" -lt 1024 ]]; then
        log_warn "磁盘空间较低: ${available_mb} MB（建议至少 1 GB）"
    else
        log_success "可用空间: ${available_gb} GB"
    fi
}

check_existing_install() {
    log_step "检测已有安装"

    if command -v openclaw &>/dev/null; then
        local current_ver
        current_ver="$(openclaw --version 2>/dev/null || echo '未知')"
        local current_path
        current_path="$(which openclaw)"
        log_warn "检测到已安装的 OpenClaw: $current_ver"
        log_debug "安装路径: $current_path"
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  已有安装: version=$current_ver path=$current_path"

        echo ""
        echo -e "${YELLOW}检测到已安装的 OpenClaw ($current_ver)${NC}"
        echo -e "继续安装将升级到最新版本。"
        echo ""
        read -rp "是否继续？(Y/n) " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            log_info "用户取消安装"
            exit 0
        fi
        log_info "用户确认继续安装（升级）"
    else
        log_success "未检测到已有安装，将进行全新安装"
    fi
}

# ─────────────────────────────────────────────
# 安装 OpenClaw
# ─────────────────────────────────────────────
install_openclaw() {
    log_step "安装 OpenClaw CLI"

    local pkg="openclaw"
    case "$CHANNEL" in
        stable) pkg="openclaw@latest" ;;
        beta)   pkg="openclaw@beta" ;;
        dev)    pkg="openclaw@latest" ;; # dev 渠道安装 latest 然后通过 update --channel dev
        *)
            log_error "未知渠道: $CHANNEL"
            return 1
            ;;
    esac

    log_info "安装包: $pkg"
    _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [INSTALL] 安装 $pkg (管理器: $(if $USE_PNPM; then echo 'pnpm'; else echo 'npm'; fi))"

    local install_cmd
    local install_output
    local install_exit=0

    if [[ "$USE_PNPM" == true ]]; then
        log_info "使用 pnpm 安装..."

        # pnpm 需要两次安装以处理 approve-builds
        log_debug "第一次安装..."
        run_with_spinner "pnpm add -g ${pkg}（首次安装，可能需要几分钟）" pnpm add -g "$pkg" || install_exit=$?
        install_output="$RUN_OUTPUT"

        if [[ $install_exit -ne 0 ]]; then
            log_warn "首次安装返回非零，尝试 approve-builds..."
        fi

        # approve-builds
        log_debug "运行 pnpm approve-builds..."
        run_with_spinner "pnpm approve-builds" pnpm approve-builds -g || true

        # 第二次安装（执行 postinstall）
        log_debug "第二次安装..."
        run_with_spinner "pnpm add -g ${pkg}（第二次安装）" pnpm add -g "$pkg" || install_exit=$?
        install_output="$RUN_OUTPUT"
    else
        log_info "使用 npm 安装..."
        log_info "首次安装通常需要 1~3 分钟，请耐心等待..."

        # 处理 sharp 安装问题
        export SHARP_IGNORE_GLOBAL_LIBVIPS=1
        log_debug "已设置 SHARP_IGNORE_GLOBAL_LIBVIPS=1 (防止 libvips 冲突)"

        run_with_spinner "npm install -g ${pkg}（下载 + 编译原生模块中）" npm install -g "$pkg" || install_exit=$?
        install_output="$RUN_OUTPUT"
    fi

    if [[ $install_exit -ne 0 ]]; then
        log_error "OpenClaw 安装失败（退出码: ${install_exit}）"
        log_error "详细信息请查看日志: $LOG_FILE"

        # 常见问题提示
        if echo "$install_output" | grep -qi "permission denied\|EACCES"; then
            log_error "权限不足。请尝试:"
            log_error "  修复 npm 权限: npm config set prefix ~/.npm-global"
            log_error "  并添加到 PATH: export PATH=~/.npm-global/bin:\$PATH"
        fi
        if echo "$install_output" | grep -qi "sharp"; then
            log_error "sharp 模块安装失败。请尝试:"
            log_error "  SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install -g openclaw@latest"
        fi
        if echo "$install_output" | grep -qi "node-gyp"; then
            log_error "node-gyp 编译失败。请确保已安装 Xcode Command Line Tools:"
            log_error "  xcode-select --install"
        fi
        return 1
    fi

    log_success "OpenClaw CLI 安装完成"
}

# ─────────────────────────────────────────────
# 验证安装
# ─────────────────────────────────────────────
verify_install() {
    log_step "验证安装"

    # 检查 openclaw 命令
    if command -v openclaw &>/dev/null; then
        local ver
        ver="$(openclaw --version 2>/dev/null || echo '版本获取失败')"
        local path
        path="$(which openclaw)"
        log_success "openclaw 命令可用: $ver"
        log_debug "安装路径: $path"
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [VERIFY] openclaw version=$ver path=$path"
    else
        log_error "openclaw 命令不在 PATH 中"

        # 尝试定位
        local npm_prefix
        npm_prefix="$(npm prefix -g 2>/dev/null || echo '')"
        if [[ -n "$npm_prefix" ]]; then
            log_error "请检查 PATH 是否包含: ${npm_prefix}/bin"
            log_error "可以运行: export PATH=\"${npm_prefix}/bin:\$PATH\""
            log_error "并添加到 ~/.zshrc 使其永久生效"
        fi
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [VERIFY] FAILED - openclaw 不在 PATH 中"
        return 1
    fi

    # 跳过 doctor：刚装完 CLI，gateway 尚未配置，doctor 的网络检查会等到超时，
    # 白白浪费时间。引导向导 (onboard) 会完成后续配置。
    log_info "跳过 openclaw doctor（安装后可随时手动运行: openclaw doctor）"
    _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [VERIFY] 跳过 doctor（安装阶段无需运行）"

    INSTALL_SUCCESS=true
}

# ─────────────────────────────────────────────
# 运行引导向导
# ─────────────────────────────────────────────
run_onboard() {
    log_step "运行引导向导"

    if [[ "$SKIP_ONBOARD" == true ]]; then
        log_info "已跳过引导向导（--skip-onboard）"
        log_info "稍后可手动运行: openclaw onboard --install-daemon"
        return 0
    fi

    log_info "启动引导向导..."
    log_info "引导向导将帮助你配置 AI 提供商、消息渠道和后台服务"
    log_info "（按照终端提示操作即可）"
    echo ""

    _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [ONBOARD] 启动引导向导"

    # 引导向导是交互式的，直接在前台运行
    if openclaw onboard --install-daemon 2>&1 | tee -a "$LOG_FILE"; then
        log_success "引导向导完成"
    else
        local exit_code=$?
        log_warn "引导向导退出（退出码: ${exit_code}）"
        log_info "你可以稍后重新运行: openclaw onboard --install-daemon"
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [ONBOARD] 退出码: $exit_code"
    fi
}

# ─────────────────────────────────────────────
# 最终报告
# ─────────────────────────────────────────────
print_summary() {
    echo ""
    _log_raw ""
    _log_raw "═══════════════════════════════════════════════"
    _log_raw "  安装结束: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    _log_raw "  结果: $(if $INSTALL_SUCCESS; then echo '成功'; else echo '失败'; fi)"
    _log_raw "═══════════════════════════════════════════════"

    if [[ "$INSTALL_SUCCESS" == true ]]; then
        echo -e "${GREEN}${BOLD}"
        echo "╔══════════════════════════════════════════════════╗"
        echo "║        ✔ OpenClaw 安装成功！                     ║"
        echo "╚══════════════════════════════════════════════════╝"
        echo -e "${NC}"

        echo -e "${BOLD}快速开始:${NC}"
        echo ""
        echo -e "  ${CYAN}# 检查状态${NC}"
        echo "  openclaw status"
        echo ""
        echo -e "  ${CYAN}# 启动 Gateway（前台）${NC}"
        echo "  openclaw gateway --port 18789 --verbose"
        echo ""
        echo -e "  ${CYAN}# 与助手对话${NC}"
        echo "  openclaw agent --message \"你好\" --thinking high"
        echo ""
        echo -e "  ${CYAN}# 打开 Dashboard${NC}"
        echo "  openclaw dashboard"
        echo ""
        echo -e "  ${CYAN}# 运行诊断${NC}"
        echo "  openclaw doctor"
        echo ""

        if [[ "$SKIP_ONBOARD" == true ]]; then
            echo -e "${YELLOW}提示: 你跳过了引导向导，请运行以下命令完成配置:${NC}"
            echo "  openclaw onboard --install-daemon"
            echo ""
        fi
    else
        echo -e "${RED}${BOLD}"
        echo "╔══════════════════════════════════════════════════╗"
        echo "║        ✖ OpenClaw 安装未完成                     ║"
        echo "╚══════════════════════════════════════════════════╝"
        echo -e "${NC}"

        echo -e "${BOLD}排查建议:${NC}"
        echo ""
        echo "  1. 查看详细日志:"
        echo -e "     ${CYAN}$LOG_FILE${NC}"
        echo ""
        echo "  2. 检查系统要求:"
        echo "     - Node.js ≥22: node --version"
        echo "     - Xcode CLT:   xcode-select -p"
        echo ""
        echo "  3. 手动安装尝试:"
        echo "     npm install -g openclaw@latest"
        echo ""
        echo "  4. 获取帮助:"
        echo "     - 文档: https://docs.openclaw.ai"
        echo "     - GitHub: https://github.com/openclaw/openclaw"
        echo "     - Discord: https://discord.gg/clawd"
        echo ""
    fi

    echo -e "${BOLD}安装日志:${NC} ${CYAN}$LOG_FILE${NC}"
    echo ""
}

# ─────────────────────────────────────────────
# 异常处理
# ─────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    # 确保 spinner 停止（防止异常退出时动画残留）
    stop_spinner 2>/dev/null || true
    if [[ $exit_code -ne 0 && "$INSTALL_SUCCESS" != true ]]; then
        _log_raw "[$(date '+%Y-%m-%d %H:%M:%S')] [FATAL] 脚本异常退出 (退出码: $exit_code)"
        echo ""
        log_error "安装过程中发生错误（退出码: ${exit_code}）"
        log_error "请查看日志: $LOG_FILE"
    fi
}

trap cleanup EXIT

# ─────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────
main() {
    parse_args "$@"

    # 初始化日志文件
    touch "$LOG_FILE"
    collect_system_info

    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║        OpenClaw macOS 安装程序                   ║"
    echo "║        https://openclaw.ai                      ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  日志文件: ${CYAN}$LOG_FILE${NC}"
    echo ""

    # 计算步骤数
    STEPS_TOTAL=9
    if [[ "$SKIP_ONBOARD" == true ]]; then
        STEPS_TOTAL=8
    fi

    # 环境检测阶段
    check_macos
    check_xcode_clt
    check_homebrew
    check_node
    check_npm_or_pnpm
    check_network
    check_disk_space
    check_existing_install

    # 安装阶段
    install_openclaw
    verify_install

    # 引导向导
    if [[ "$SKIP_ONBOARD" != true ]]; then
        run_onboard
    fi

    # 最终报告
    print_summary
}

main "$@"
