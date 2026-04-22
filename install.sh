#!/bin/bash
# =============================================================================
# install.sh - Installer for Linux SMIT 維運工具 (v1.3)
#
# 使用方式：
#   1. 解壓 tarball 或直接把整個 scripts/ 目錄帶到目標機
#   2. cd scripts && sudo bash install.sh
#
# 會做的事：
#   - 建立 ${BASE}/{scripts,logs,reports,conf}  (預設 BASE=/CASLog/AI，可 env 覆蓋)
#   - 把本目錄下的 *.sh 複製到 ${BASE}/scripts/
#   - chmod 750
#   - 產出 /tmp/CASLog_AI_<timestamp>.tar.gz 方便散佈
# =============================================================================
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-/CASLog/AI}"
SCRIPT_DIR="${BASE}/scripts"
LOG_DIR="${BASE}/logs"
REPORT_DIR="${BASE}/reports"
CONF_DIR="${BASE}/conf"

echo "[install] 來源目錄: ${HERE}"
echo "[install] 建立目錄結構..."
mkdir -p "${SCRIPT_DIR}" "${LOG_DIR}" "${REPORT_DIR}" "${CONF_DIR}"
chmod 700 "${CONF_DIR}"

echo "[install] 複製腳本..."
EXPECTED=(LinuxMenu.sh mod_system.sh mod_network.sh mod_file.sh mod_process.sh
          mod_user.sh mod_audit.sh mod_pkg.sh mod_storage.sh mod_java.sh
          mod_security.sh mod_others.sh mod_troubleshoot.sh mod_daily.sh
          mod_db.sh mod_tooling.sh mod_triage.sh mod_baseline.sh
          mod_audit_seal.sh)
for f in "${EXPECTED[@]}"; do
    if [ ! -f "${HERE}/${f}" ]; then
        echo "[install] 警告: 缺少 ${f}"
        continue
    fi
    cp "${HERE}/${f}" "${SCRIPT_DIR}/${f}"
    chmod 750 "${SCRIPT_DIR}/${f}"
    echo "  → ${SCRIPT_DIR}/${f}"
done

# 設定檔範本（不覆蓋既有自訂，僅 sample 檔每次更新）
install_sample() {
    local sample="$1" target="$2"
    [ -f "${HERE}/${sample}" ] || return 0
    cp "${HERE}/${sample}" "${CONF_DIR}/${sample}"
    chmod 600 "${CONF_DIR}/${sample}"
    if [ ! -f "${CONF_DIR}/${target}" ]; then
        cp "${CONF_DIR}/${sample}" "${CONF_DIR}/${target}"
        chmod 600 "${CONF_DIR}/${target}"
        echo "[install] 已建立 ${CONF_DIR}/${target} (從 sample 複製)"
    else
        echo "[install] ${CONF_DIR}/${target} 已存在，保留自訂 (sample 已更新)"
    fi
}
install_sample "db.conf.sample"       "db.conf"
install_sample "app.conf.sample"      "app.conf"
install_sample "baseline.conf.sample" "baseline.conf"

# ============================================================================
# T0 合規設定 — HMAC key + 每日封存 cron + append-only
# ============================================================================
echo "[install] T0 合規：初始化 HMAC key + cron..."
bash "${SCRIPT_DIR}/mod_audit_seal.sh" --ensure-key || \
    echo "[install] 警告: HMAC key 初始化失敗 (audit seal 仍可手動啟用)"

# cron 設定 (若不存在才寫，避免覆蓋管理員客製)
CRON_FILE="/etc/cron.d/linuxmenu-audit-seal"
if [ ! -f "${CRON_FILE}" ]; then
    cat > "${CRON_FILE}" <<EOF_CRON
# 每日 23:59 封存今日 audit log (T0 合規)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

59 23 * * * root  bash ${SCRIPT_DIR}/mod_audit_seal.sh --daily >> ${LOG_DIR}/audit_seal.log 2>&1
EOF_CRON
    chmod 644 "${CRON_FILE}"
    echo "[install] 已建立 ${CRON_FILE}"
else
    echo "[install] ${CRON_FILE} 已存在，保留 (可手動檢視)"
fi

# 保護既有 audit log 為 append-only
bash "${SCRIPT_DIR}/mod_audit_seal.sh" --protect 2>/dev/null | sed 's/^/[install] /'

echo "[install] 產生 tarball ..."
TAR="/tmp/LinuxMenu_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "${TAR}" -C "$(dirname "${BASE}")" "$(basename "${BASE}")/scripts"
echo "[install] 封裝完成: ${TAR}"

cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  金融業 Linux 維運工具  v1.3  已安裝完成
║
║  啟動方式:
║      bash ${SCRIPT_DIR}/LinuxMenu.sh
║
║  審計日誌: ${LOG_DIR}
║  巡檢報表: ${REPORT_DIR}
║  設定檔  : ${CONF_DIR}
║
║  合規 (T0):
║    HMAC key  : ${CONF_DIR}/hmac.key  (請備份到離線安全保管!)
║    每日封存  : /etc/cron.d/linuxmenu-audit-seal (23:59 自動)
║    驗證指令  : bash ${SCRIPT_DIR}/mod_audit_seal.sh --verify-all
╚══════════════════════════════════════════════════════════════╝
EOF
