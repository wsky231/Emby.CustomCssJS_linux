#!/usr/bin/env bash
set -euo pipefail

# 配置：按你的实际安装路径
BASE="/opt/emby-server/system"
PLUGINS_DIR="$BASE/plugins"
UI_DIR="$BASE/dashboard-ui"
MODULES_DIR="$UI_DIR/modules"
APP_JS="$UI_DIR/app.js"
BAK_DIR="$UI_DIR/bak"

# 源文件 URL（来自原脚本的同一仓库）
PLUGIN_URL="https://raw.githubusercontent.com/Shurelol/Emby.CustomCssJS/main/src/Emby.CustomCssJS.dll"
JS_URL="https://raw.githubusercontent.com/Shurelol/Emby.CustomCssJS/main/src/CustomCssJS.js"

# 日志与错误
log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
die()  { echo -e "[ERR ] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

download() {
  # usage: download <url> <out_path>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    die "需要 curl 或 wget 任一下载工具"
  fi
}

ensure_dirs() {
  sudo mkdir -p "$PLUGINS_DIR" "$MODULES_DIR" "$BAK_DIR"
}

backup_app() {
  if [[ -f "$APP_JS" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    # 基线备份（只留一份）
    if [[ ! -f "$BAK_DIR/app.js" ]]; then
      cp -f "$APP_JS" "$BAK_DIR/app.js"
      log "已创建基线备份: $BAK_DIR/app.js"
    fi
    # 时间戳备份
    cp -f "$APP_JS" "$BAK_DIR/app.js.$ts"
    log "已创建时间戳备份: $BAK_DIR/app.js.$ts"
  else
    die "未找到 app.js: $APP_JS，请确认 Emby 安装路径是否正确"
  fi
}

install_plugin() {
  local target="$PLUGINS_DIR/Emby.CustomCssJS.dll"
  if [[ -f "$target" ]]; then
    log "插件已存在: $target（跳过下载）"
  else
    local tmp
    tmp="$(mktemp)"
    log "下载插件 DLL..."
    download "$PLUGIN_URL" "$tmp"
    sudo cp -f "$tmp" "$target"
    sudo chmod 755 "$target"
    rm -f "$tmp"
    log "插件已安装: $target"
  fi
}

install_module_js() {
  local target="$MODULES_DIR/CustomCssJS.js"
  local tmp
  tmp="$(mktemp)"
  log "下载前端模块 JS..."
  download "$JS_URL" "$tmp"
  sudo cp -f "$tmp" "$target"
  sudo chmod 644 "$target" || true
  rm -f "$tmp"
  log "模块已部署: $target"
}

already_injected() {
  grep -q 'CustomCssJS\.js' "$APP_JS"
}

inject_app_js() {
  if already_injected; then
    log "检测到 app.js 已包含 CustomCssJS.js，跳过注入"
    return 0
  fi

  backup_app

  # 允许空白的更稳健匹配
  local pattern_ere='Promise[[:space:]]*\.all\([[:space:]]*list[[:space:]]*\.map\([[:space:]]*loadPlugin[[:space:]]*\)[[:space:]]*\)'

  if grep -qE "$pattern_ere" "$APP_JS"; then
    # 用 | 作分隔符，\0 回带原匹配
    sudo sed -E -i 's|'"$pattern_ere"'|list.push("./modules/CustomCssJS.js"),\0|' "$APP_JS"
  else
    warn "未找到主锚点，尝试在 var list=[ ... ] 中兜底注入"
    # 只在第一次出现的 var list=[ 后面插入
    sudo sed -E -i '0,/(var[[:space:]]+list[[:space:]]*=\[)/s//\1".\/modules\/CustomCssJS.js",/' "$APP_JS"
  fi

  if already_injected; then
    log "app.js 注入成功"
  else
    die "注入后仍未检测到 CustomCssJS.js，请手动检查 $APP_JS"
  fi
}

revert_app_js() {
  if [[ -f "$BAK_DIR/app.js" ]]; then
    log "回滚到基线备份: $BAK_DIR/app.js"
    sudo cp -f "$BAK_DIR/app.js" "$APP_JS"
    log "已回滚 app.js"
  else
    warn "找不到基线备份，尝试从当前 app.js 移除注入片段"
    if [[ -f "$APP_JS" ]]; then
      sudo sed -i 's/list\.push("\.\/modules\/CustomCssJS\.js"),\s*//g' "$APP_JS"
      log "已尝试移除注入片段。请自行验证 UI 是否正常。"
    else
      die "未找到 app.js: $APP_JS"
    fi
  fi
}

usage() {
  cat <<EOF
用法: $0 [install|revert]

  install  安装 Emby.CustomCssJS 插件与前端模块，并向 app.js 注入加载语句
  revert   回滚 app.js（优先使用 bak/app.js 基线备份；若无则尝试移除注入片段）

说明：
- 本脚本假定 Emby 安装在: $BASE
- 插件目录:      $PLUGINS_DIR
- 前端 UI 目录:   $UI_DIR
- 模块目录:       $MODULES_DIR
- app.js 路径:    $APP_JS
- 备份目录:       $BAK_DIR
- 需要具有对 /opt 目录的写权限（必要时用 sudo 运行）
EOF
}

main() {
  local action="${1:-install}"
  need_cmd grep
  need_cmd sed
  ensure_dirs

  case "$action" in
    install)
      install_plugin
      install_module_js
      inject_app_js
      log "完成。建议重启 Emby 服务以生效。"
      ;;
    revert)
      revert_app_js
      log "回滚完成。建议重启 Emby 服务以生效。"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
