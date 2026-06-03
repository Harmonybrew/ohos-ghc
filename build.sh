#!/usr/bin/env bash
# ============================================================================
# build.sh — GHC 9.12.2 OHOS 交叉编译构建流水线
# ============================================================================
#
# 在 x86_64 Linux 主机上，将 GHC 9.12.2 交叉编译为 aarch64-unknown-linux-ohos
# 原生编译器（Stage 2）。构建产物可直接在 OpenHarmony 系统中运行。
#
# 用法:
#   bash build.sh --all                  # 完整构建（推荐）
#   bash build.sh --setup                # 下载 GHC 源码、引导 GHC 和 OHOS SDK
#   bash build.sh --deps                 # 交叉编译 GMP + libffi 目标库（静态）
#   bash build.sh --build                # 构建完整交叉编译链（Stage0→Stage1→Stage2）
#   bash build.sh --post-process         # 后处理: 修复 stage2 路径
#   bash build.sh --package              # 打包 stage2 产物
#
# 环境变量:
#   WORKDIR        工作目录 (默认: <仓库根>/ghc-ohos-work)
#   JOBS           并行编译任务数 (默认: nproc)
#   TARGET_TRIPLE  目标三元组 (默认: aarch64-unknown-linux-ohos)
#
# 依赖:
#   - build-essential unzip xz-utils autoconf python3 libgmp-dev libffi-dev
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# 配置
# ============================================================================
GHC_VERSION="9.12.2"
BOOT_GHC_VERSION="9.10.1"
PATCH_FILE="${SCRIPT_DIR}/0001-support-ohos.patch"

# 下载链接（稳定，可复现）
GHC_SRC_URL="https://downloads.haskell.org/~ghc/${GHC_VERSION}/ghc-${GHC_VERSION}-src.tar.xz"
BOOT_GHC_URL="https://downloads.haskell.org/~ghc/${BOOT_GHC_VERSION}/ghc-${BOOT_GHC_VERSION}-x86_64-ubuntu20_04-linux.tar.xz"
OHOS_SDK_URL="https://cidownload.openharmony.cn/version/Master_Version/OpenHarmony_6.1.0.31/20260311_020435/version-Master_Version-OpenHarmony_6.1.0.31-20260311_020435-ohos-sdk-full_6.1-Release.tar.gz"

WORKDIR="${WORKDIR:-${SCRIPT_DIR}/ghc-ohos-work}"
OHOS_SDK_DIR="${WORKDIR}/ohos-sdk"
GHC_SRC_DIR="${WORKDIR}/ghc-${GHC_VERSION}-src"
BUILD_ROOT="${GHC_SRC_DIR}/_build"

JOBS="${JOBS:-$(nproc)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-unknown-linux-ohos}"

# 内部路径
GMP_INSTALL_DIR="${WORKDIR}/gmp-install"
LIBFFI_INSTALL_DIR="${WORKDIR}/libffi-install"

# ============================================================================
# 辅助函数
# ============================================================================
info()  { echo "$*"; }
ok()    { echo "OK: $*"; }
warn()  { echo "WARN: $*"; }
err()   { echo "ERROR: $*" >&2; }
header(){ echo -e "\n*** $* ***\n"; }

logfile="${WORKDIR}/build.log"
exec 3>&1  # 保存 stdout
exec 4>&2  # 保存 stderr
log() {
  echo "[$(date '+%H:%M:%S')] $*" >> "$logfile"
}

# SDK 工具快捷方式
sdk_bin() { echo "${OHOS_SDK_DIR}/linux/native/llvm/bin"; }

# ============================================================================
# 下载依赖（GHC 源码 + 引导 GHC + OHOS SDK）
# ============================================================================
phase_setup() {
  header "下载和准备依赖"

  mkdir -p "$WORKDIR"
  logfile="${WORKDIR}/build.log"
  touch "$logfile"

  # --- GHC 源码 ---
  if [ ! -f "${GHC_SRC_DIR}/configure" ]; then
    local src_tarball="${WORKDIR}/ghc-${GHC_VERSION}-src.tar.xz"
    if [ ! -f "$src_tarball" ]; then
      info "下载 GHC ${GHC_VERSION} 源码..."
      curl -fSLo "$src_tarball" "$GHC_SRC_URL"
      log "GHC 源码下载完成"
    fi
    info "解压 GHC 源码..."
    mkdir -p "$GHC_SRC_DIR"
    tar -xf "$src_tarball" -C "$GHC_SRC_DIR" --strip-components=1
    ok "GHC 源码已解压到 ${GHC_SRC_DIR}"

    # 应用补丁
    if [ -f "$PATCH_FILE" ]; then
      info "应用 OHOS 移植补丁..."
      cd "$GHC_SRC_DIR"
      patch -p1 < "$PATCH_FILE"
      cd "$SCRIPT_DIR"
      ok "补丁已应用"
    else
      warn "补丁文件不存在: ${PATCH_FILE}，跳过"
    fi
  else
    ok "GHC 源码已存在"
  fi

  # --- OHOS SDK ---
  if [ ! -d "${OHOS_SDK_DIR}/linux/native/llvm/bin" ]; then
    local sdk_tarball="${WORKDIR}/ohos-sdk-full.tar.gz"
    if [ ! -f "$sdk_tarball" ]; then
      info "下载 OHOS SDK (较大，请耐心等待)..."
      curl -fSLo "$sdk_tarball" "$OHOS_SDK_URL"
      log "OHOS SDK 下载完成"
    fi
    info "解压 OHOS SDK (linux/ 交叉编译部分)..."
    mkdir -p "${OHOS_SDK_DIR}/linux"
    tar -zxf "$sdk_tarball" -C "${OHOS_SDK_DIR}/linux" --strip-components=2 ohos-sdk/linux/
    cd "${OHOS_SDK_DIR}/linux"
    unzip -q native-*.zip
    rm -f *.zip
    cd "$SCRIPT_DIR"
    ok "OHOS SDK 已就绪 (交叉编译器)"
  else
    ok "OHOS SDK 已存在"
  fi

  export PATH="$(sdk_bin):${PATH}"

  # --- GHC 引导编译器 ---
  if [ ! -f "${WORKDIR}/_boot/bin/ghc" ]; then
    local boot_tarball="${WORKDIR}/ghc-${BOOT_GHC_VERSION}-boot.tar.xz"
    if [ ! -f "$boot_tarball" ]; then
      info "下载引导 GHC ${BOOT_GHC_VERSION}..."
      curl -fSLo "$boot_tarball" "$BOOT_GHC_URL"
      log "引导 GHC 下载完成"
    fi
    mkdir -p "${WORKDIR}/_boot"
    info "解压引导 GHC..."
    tar -xf "$boot_tarball" -C "${WORKDIR}/_boot" --strip-components=1
    ok "引导 GHC 已就绪"
  else
    ok "引导 GHC 已存在"
  fi
  export PATH="${WORKDIR}/_boot/bin:${PATH}"

  ok "依赖下载完成！"
}

# ============================================================================
# 构建目标库: 从源码交叉编译 GMP + libffi（静态库）
# ============================================================================
phase_deps() {
  header "构建目标库: 交叉编译 GMP + libffi (静态)"

  export PATH="$(sdk_bin):${PATH}"

  local sdk_bin_dir="$(sdk_bin)"
  export CC="${sdk_bin_dir}/aarch64-unknown-linux-ohos-clang"
  export CXX="${sdk_bin_dir}/aarch64-unknown-linux-ohos-clang++"
  export LD="${sdk_bin_dir}/ld.lld"
  export AR="${sdk_bin_dir}/llvm-ar"
  export AS="${sdk_bin_dir}/llvm-as"
  export NM="${sdk_bin_dir}/llvm-nm"
  export RANLIB="${sdk_bin_dir}/llvm-ranlib"
  export STRIP="${sdk_bin_dir}/llvm-strip"
  export OBJCOPY="${sdk_bin_dir}/llvm-objcopy"
  export OBJDUMP="${sdk_bin_dir}/llvm-objdump"

  # --- GMP ---
  if [ ! -f "${GMP_INSTALL_DIR}/lib/libgmp.a" ]; then
    local gmp_src="${WORKDIR}/gmp-6.3.0"
    if [ ! -d "$gmp_src" ]; then
      local gmp_tarball="${WORKDIR}/gmp-6.3.0.tar.gz"
      if [ ! -f "$gmp_tarball" ]; then
        info "下载 GMP 源码..."
        curl -fSLo "$gmp_tarball" "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.gz"
        log "GMP 源码下载完成"
      fi
      info "解压 GMP 源码..."
      tar -zxf "$gmp_tarball" -C "$WORKDIR"
    fi
    rm -rf "${GMP_INSTALL_DIR}"
    mkdir -p "${GMP_INSTALL_DIR}"
    info "编译 GMP..."
    cd "$gmp_src"
    ./configure --prefix="${GMP_INSTALL_DIR}" --disable-shared --host=aarch64-linux-musl
    make -j${JOBS}
    make install
    cd "$SCRIPT_DIR"
    if [ -f "${GMP_INSTALL_DIR}/lib/libgmp.a" ]; then
      ok "GMP 已从源码编译: $(ls -lh ${GMP_INSTALL_DIR}/lib/libgmp.a | awk '{print $5}')"
    else
      err "GMP 编译失败（libgmp.a 未找到）"
      return 1
    fi
  else
    ok "GMP 静态库已存在"
  fi

  # --- libffi ---
  if [ ! -f "${LIBFFI_INSTALL_DIR}/lib/libffi.a" ]; then
    local libffi_src="${WORKDIR}/libffi-3.5.2"
    if [ ! -d "$libffi_src" ]; then
      local libffi_tarball="${WORKDIR}/libffi-3.5.2.tar.gz"
      if [ ! -f "$libffi_tarball" ]; then
        info "下载 libffi 源码..."
        curl -fSLo "$libffi_tarball" "https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz"
        log "libffi 源码下载完成"
      fi
      info "解压 libffi 源码..."
      tar -zxf "$libffi_tarball" -C "$WORKDIR"
    fi
    rm -rf "${LIBFFI_INSTALL_DIR}"
    mkdir -p "${LIBFFI_INSTALL_DIR}"
    info "编译 libffi..."
    cd "$libffi_src"
    ./configure --prefix="${LIBFFI_INSTALL_DIR}" --disable-shared --disable-docs --host=aarch64-linux-musl
    make -j${JOBS}
    make install
    cd "$SCRIPT_DIR"
    if [ -f "${LIBFFI_INSTALL_DIR}/lib/libffi.a" ]; then
      ok "libffi 已从源码编译: $(ls -lh ${LIBFFI_INSTALL_DIR}/lib/libffi.a | awk '{print $5}')"
    else
      err "libffi 编译失败（libffi.a 未找到）"
      return 1
    fi
  else
    ok "libffi 静态库已存在"
  fi

  ok "目标库已从源码构建就绪。"
}

# ============================================================================
# 构建完整的 GHC 交叉编译器
#
# 在交叉编译模式下 (--target=TARGET)，hadrian 自动处理依赖链:
#   Stage 0 (boot GHC on x86_64)
#     → Stage 1 (交叉编译器: runs on x86_64, targets OHOS)
#     → Stage 2 (原生编译器: runs on OHOS, targets OHOS)
# ============================================================================
phase_build() {
  header "构建完整的 GHC 交叉编译器 (Stage 0 → Stage 1 → Stage 2)"

  cd "$GHC_SRC_DIR"
  export PATH="${WORKDIR}/_boot/bin:$(sdk_bin):${PATH}"

  local sdk_bin_dir="$(sdk_bin)"
  local clang="${sdk_bin_dir}/aarch64-unknown-linux-ohos-clang"

  if [ ! -f "$clang" ]; then
    err "OHOS SDK clang 未找到: $clang"
    return 1
  fi
  ok "使用 OHOS clang: $clang"

  # 确保目标库已就绪
  if [ ! -f "${GMP_INSTALL_DIR}/lib/libgmp.a" ] || [ ! -f "${LIBFFI_INSTALL_DIR}/lib/libffi.a" ]; then
    info "目标库未就绪，先构建..."
    phase_deps
  fi

  # --- 运行 boot （生成 configure 和 .autoconf.in 等）---
  info "运行 python3 boot.source..."
  python3 boot.source 2>&1 | tail -5
  ok "boot.source 完成"

  # 确保 configure 可执行
  chmod +x configure

  # --- 删除旧的 system.config 以强制重新配置 ---
  rm -f "hadrian/cfg/system.config" "hadrian/cfg/default.host.target" "hadrian/cfg/default.target"

  # --- configure ---
  info "运行 configure (交叉编译模式)..."
  local cfg_log="${WORKDIR}/configure.log"
  CC="${clang}" \
  CXX="${sdk_bin_dir}/aarch64-unknown-linux-ohos-clang++" \
  LD="${sdk_bin_dir}/ld.lld" \
  AR="${sdk_bin_dir}/llvm-ar" \
  NM="${sdk_bin_dir}/llvm-nm" \
  RANLIB="${sdk_bin_dir}/llvm-ranlib" \
  OBJDUMP="${sdk_bin_dir}/llvm-objdump" \
  STRIP="${sdk_bin_dir}/llvm-strip" \
  OBJCOPY="${sdk_bin_dir}/llvm-objcopy" \
  CPP="${clang} -E" \
  GHC="${WORKDIR}/_boot/bin/ghc" \
  CrossCompiling=YES \
  ./configure \
    --target="${TARGET_TRIPLE}" \
    --with-gmp-includes="${GMP_INSTALL_DIR}/include" \
    --with-gmp-libraries="${GMP_INSTALL_DIR}/lib" \
    --with-system-libffi \
    --with-ffi-includes="${LIBFFI_INSTALL_DIR}/include" \
    --with-ffi-libraries="${LIBFFI_INSTALL_DIR}/lib" \
    > "${cfg_log}" 2>&1 || {
      err "configure 失败，详情: ${cfg_log}"
      tail -30 "${cfg_log}"
      return 1
    }
  ok "configure 完成"

  # --- 验证 configure 产物 ---
  if [ ! -f "hadrian/cfg/system.config" ]; then
    err "configure 未生成 system.config"
    return 1
  fi
  ok "system.config 已生成"

  # --- 构建 hadrian（通过 bootstrap.py）---
  info "构建 hadrian..."

  if command -v python3 &>/dev/null; then
    info "使用 bootstrap.py 构建 hadrian..."
    python3 hadrian/bootstrap/bootstrap.py \
      -w "${WORKDIR}/_boot/bin/ghc" \
      -d hadrian/bootstrap/plan-bootstrap-${BOOT_GHC_VERSION//./_}.json \
      2>&1 | tee -a "${logfile}" || {
        err "bootstrap.py 构建 hadrian 失败"
        return 1
      }
    ok "hadrian 构建完成 (bootstrap.py)"
  else
    info "使用 cabal 构建 hadrian..."
    cabal new-build -j${JOBS} --project-file=hadrian/cabal.project \
      2>&1 | tee -a "${logfile}" || {
        err "cabal 构建 hadrian 失败"
        return 1
      }
    ok "hadrian 构建完成 (cabal)"
  fi

  # --- 验证 hadrian 二进制 ---
  local hadrian_bin
  hadrian_bin="$(find _build/bin -name 'hadrian' -type f -executable 2>/dev/null | head -1)"
  if [ -z "$hadrian_bin" ]; then
    hadrian_bin="$(find _build/stage0/bin -name 'hadrian' -type f 2>/dev/null | head -1)"
  fi
  if [ -z "$hadrian_bin" ]; then
    hadrian_bin="$(find _build -path '*/hadrian' -type f -executable 2>/dev/null | head -1)"
  fi
  if [ -z "$hadrian_bin" ]; then
    hadrian_bin="_build/bin/hadrian"
  fi
  if [ -f "$hadrian_bin" ]; then
    ok "hadrian 二进制: $(${hadrian_bin} --version 2>/dev/null || ${hadrian_bin} --help 2>/dev/null | head -1 || file $hadrian_bin)"
  else
    warn "hadrian 二进制未找到，尝试使用 hadrian/build 脚本..."
    hadrian_bin="./hadrian/build"
  fi

  export PATH="${WORKDIR}/_boot/bin:$(sdk_bin):${PATH}"

  # 显式列出所有原生编译器（Stage 2）构建目标
  local native_targets=(
    "stage3:exe:ghc-bin"
    "stage3:exe:ghc-pkg"
    "stage3:exe:hsc2hs"
    "stage3:exe:hp2ps"
    "stage3:exe:unlit"
  )

  info "开始构建 Stage0→Stage1→Stage2 交叉编译链..."
  info "目标列表: ${native_targets[*]}"
  info "GHC: $(which ghc), GHC version: $(ghc --version 2>&1)"
  info "SDK clang: $(which ${TARGET_TRIPLE}-clang 2>&1 || which clang 2>&1)"

  local build_args=(
    "-j${JOBS}"
    "--flavour=quick"
  )

  info "运行 hadrian/build ..."
  ${hadrian_bin} "${build_args[@]}" "${native_targets[@]}" \
    2>&1 | tee -a "${logfile}" || {
      err "GHC 构建失败"
      return 1
    }

  # --- 验证 Stage 2 产物 ---
  local stage2_bin="${BUILD_ROOT}/stage2/bin/${TARGET_TRIPLE}-ghc"
  if [ -f "$stage2_bin" ]; then
    ok "Stage 2 编译器已构建: ${stage2_bin}"
    file "$stage2_bin"
    "$stage2_bin" --version 2>&1 || true
  else
    warn "Stage 2 ghc 未在预期路径，尝试查找..."
    find "${BUILD_ROOT}/stage2" -name 'ghc' -type f 2>/dev/null | head -5
    find "${BUILD_ROOT}/stage2" -name "*ghc*" -type f 2>/dev/null | head -10
  fi

  ok "构建完成！Stage0→Stage1→Stage2 交叉编译链已全部就绪。"
}

# ============================================================================
# 后处理: 修复 stage2 settings 中的工具路径
# ============================================================================
post_process_stage2() {
  header "后处理: 修复 Stage 2 settings 路径"

  local triple="${TARGET_TRIPLE}"
  local settings_file="${BUILD_ROOT}/stage2/lib/settings"

  if [ ! -f "$settings_file" ]; then
    err "settings 文件未找到: $settings_file (构建未完成?)"
    return 1
  fi

  # --- 1. 移除 LLVM 工具路径中的 SDK 前缀（改为简单命令名）---
  info "正在将 LLVM 工具路径改为命令名..."
  if grep -q "${OHOS_SDK_DIR}" "$settings_file"; then
    sed -i \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?clang++"|"clang++"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?clang[^"]*"|"clang"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?lld"|"lld"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?ld\.lld"|"ld.lld"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-ar"|"llvm-ar"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-nm"|"llvm-nm"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-ranlib"|"llvm-ranlib"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-objcopy"|"llvm-objcopy"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-objdump"|"llvm-objdump"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-strip"|"llvm-strip"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-as"|"llvm-as"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llvm-link"|"llvm-link"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?opt"|"opt"|g' \
      -e 's|"[^"]*/\(aarch64-unknown-linux-ohos-\)\?llc"|"llc"|g' \
      "$settings_file"
    ok "settings 路径已清理（移除 SDK 前缀，改用命令名）"
  else
    local has_paths=0
    while IFS= read -r line; do
      if echo "$line" | grep -qE '"(clang|ld\.lld|llvm-ar|llvm-nm)"' && echo "$line" | grep -q '/'; then
        has_paths=1
        break
      fi
    done < "$settings_file"
    if [ "$has_paths" = "1" ]; then
      warn "settings 中包含带路径的命令但 SDK 路径不匹配"
    else
      ok "settings 路径已为命令名格式，无需处理"
    fi
  fi

  # --- 2. 修复误设的 llvm-as ---
  if grep -q '"aarch64-unknown-linux-ohos-clang"' "$settings_file" 2>/dev/null; then
    info "修复被误设为 clang 的 llvm-as..."
    sed -i 's|"aarch64-unknown-linux-ohos-clang"|"llvm-as"|g' "$settings_file"
    ok "llvm-as 已修复: clang → llvm-as"
  fi

  # --- 3. 修复 package.conf.d 中的构建期路径 ---
  info "修复 package.conf.d 中的构建期路径..."
  local pkg_conf_dir="${BUILD_ROOT}/stage2/lib/package.conf.d"
  local cleaned=0
  if [ -d "$pkg_conf_dir" ]; then
    for conf in "$pkg_conf_dir"/*.conf; do
      if [ -f "$conf" ]; then
        sed -i \
          -e "s|${GHC_SRC_DIR}/||g" \
          -e "s|${BUILD_ROOT}/stage2/||g" \
          "$conf"
        cleaned=$((cleaned + 1))
      fi
    done
    local ghc_pkg="${BUILD_ROOT}/stage2/bin/${TARGET_TRIPLE}-ghc-pkg"
    if [ -f "$ghc_pkg" ]; then
      "$ghc_pkg" --package-db="$pkg_conf_dir" recache 2>/dev/null && \
        ok "已清理 $cleaned 个 .conf 文件并重建 package.cache" || \
        warn "ghc-pkg recache 失败"
    fi
  else
    ok "未找到需修复的 .conf 文件"
  fi

  ok "Stage 2 后处理完成！"
}

# ============================================================================
# 打包产物
# ============================================================================
package_all() {
  header "打包构建产物"

  local triple="${TARGET_TRIPLE}"
  local out_dir="${1:-${WORKDIR}/ghc-${GHC_VERSION}-ohos-arm64}"
  local stage2_bindir="${BUILD_ROOT}/stage2/bin"
  local stage2_libdir="${BUILD_ROOT}/stage2/lib"

  if [ ! -d "$stage2_bindir" ]; then
    err "Stage 2 产物未找到，请先构建"
    return 1
  fi

  rm -rf "$out_dir"
  mkdir -p "$out_dir/bin" "$out_dir/lib" "$out_dir/lib/package.conf.d" "$out_dir/share"

  # 复制二进制文件
  info "复制二进制..."
  cp "$stage2_bindir"/* "$out_dir/bin/" 2>/dev/null || true
  rm -f "$out_dir/bin/"*.hi "$out_dir/bin/"*.o 2>/dev/null || true

  # 创建非前缀符号链接
  local symlink_count=0
  for f in "$out_dir/bin/${triple}"-*; do
    if [ -f "$f" ] || [ -L "$f" ]; then
      local base_name; base_name="$(basename "$f")"
      local target_name="${base_name#${triple}-}"
      rm -f "$out_dir/bin/$target_name"
      ln -sf "$base_name" "$out_dir/bin/$target_name"
      symlink_count=$((symlink_count + 1))
    fi
  done
  if [ "$symlink_count" -gt 0 ]; then
    info "创建了 ${symlink_count} 个非前缀符号链接"
  fi

  # 验证关键程序
  local required_bins=("${triple}-ghc" "${triple}-ghc-pkg")
  local missing_bins=()
  for b in "${required_bins[@]}"; do
    if [ ! -f "$out_dir/bin/$b" ]; then
      missing_bins+=("$b")
    fi
  done
  if [ ${#missing_bins[@]} -gt 0 ]; then
    err "关键程序缺失: ${missing_bins[*]}"
    return 1
  fi

  # 复制库文件
  info "复制库文件..."
  cp -r "$stage2_libdir"/* "$out_dir/lib/" 2>/dev/null || true

  # 确保 settings 已修复
  if [ -f "${stage2_libdir}/settings" ]; then
    cp "${stage2_libdir}/settings" "$out_dir/lib/settings"
  fi

  # 复制文档
  if [ -d "${BUILD_ROOT}/stage2/share" ]; then
    cp -r "${BUILD_ROOT}/stage2/share"/* "$out_dir/share/" 2>/dev/null || true
  fi

  # 版本文件
  echo "${GHC_VERSION}" > "$out_dir/version"

  # 开源许可证
  cat <<EOF > $out_dir/licenses.txt
This document describes the licenses of all software distributed with the
bundled application.
==========================================================================

ghc
=============
$(cat $GHC_SRC_DIR/LICENSE)

gmp
=============
==license==
$(cat ${WORKDIR}/gmp-6.3.0/COPYING)
==authors==
$(cat ${WORKDIR}/gmp-6.3.0/AUTHORS)

libffi
=============
$(cat ${WORKDIR}/libffi-3.5.2/LICENSE)
EOF

  # 打包
  local tarball="${out_dir}.tar.gz"
  tar -czf "$tarball" -C "$(dirname "$out_dir")" "$(basename "$out_dir")"

  # 清理临时目录
  rm -rf "$out_dir"

  ok "打包完成: ${tarball}"
  ls -lh "$tarball"
}


# ============================================================================
# 主入口
# ============================================================================
show_help() {
  cat << 'HELP'
用法: bash build.sh [选项]

选项:
  --help              显示此帮助
  --setup             下载所有依赖（GHC 源码、引导 GHC、OHOS SDK）
  --deps              交叉编译 GMP + libffi 目标库（从源码，静态）
  --build             构建完整 GHC 交叉编译器（Stage0→Stage1→Stage2）
  --post-process      后处理: 修复 stage2 路径，使其可移植
  --package [dir]     打包所有产物
  --all               完整构建（setup + deps + build + post-process + package）

环境变量:
  WORKDIR      工作目录（默认: <仓库根>/ghc-ohos-work）
  JOBS         并行任务数（默认: nproc）
  TARGET_TRIPLE 目标三元组（默认: aarch64-unknown-linux-ohos）

HELP
}

main() {
  if [ $# -eq 0 ]; then
    show_help
    return
  fi

  case "${1:-}" in
    --help)         show_help ;;
    --setup)        phase_setup ;;
    --deps)         phase_deps ;;
    --build)        phase_build ;;
    --post-process) post_process_stage2 ;;
    --package)      package_all "${2:-}" ;;
    --all)
      phase_setup
      phase_deps
      phase_build
      post_process_stage2
      package_all "${2:-}"
      ;;
    *)
      show_help
      return 1
      ;;
  esac
}

main "$@"
