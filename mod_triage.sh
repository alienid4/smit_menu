#!/bin/bash
# mod_triage.sh (lite 版) - 純系統秒級診斷 (目標 <1 秒)
# 跟 full 版差別：去掉 AP 相關三項 (service active / port listen / service err log)
# 只保留系統層 3 項：磁碟、記憶體、Load
# 適用：純觀察主機、交易期間、freeze 時不要加重負擔
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

clear
echo "======================================================"
echo " 快速 Triage (Lite, 純系統觀察, 目標 <1 秒)"
echo " 只看系統層 3 項 (磁碟 / 記憶體 / Load)"
echo "======================================================"

START_TS=$(date +%s.%N)

declare -a RESULTS

# [D] 磁碟最高使用率 (df 瞬間)
read -r D_PCT D_MNT < <(df -hP 2>/dev/null | awk 'NR>1 && $6!~/^\/(dev|proc|sys|run)/ {gsub(/%/,"",$5); print $5, $6}' | sort -rn | head -1)
D_PCT="${D_PCT:-0}"
D_STATUS="PASS"
[ "${D_PCT}" -ge 80 ] 2>/dev/null && D_STATUS="WARN"
[ "${D_PCT}" -ge 95 ] 2>/dev/null && D_STATUS="FAIL"
RESULTS+=("D|磁碟最高使用率|${D_STATUS}|${D_PCT}% @ ${D_MNT:-?}")

# [E] 記憶體可用 (讀 /proc/meminfo 瞬間)
MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%.2f", $2/1024/1024}' /proc/meminfo)
M_STATUS="PASS"
awk -v m="${MEM_AVAIL}" 'BEGIN{exit !(m<1.0)}' && M_STATUS="WARN"
awk -v m="${MEM_AVAIL}" 'BEGIN{exit !(m<0.3)}' && M_STATUS="FAIL"
RESULTS+=("E|記憶體可用|${M_STATUS}|${MEM_AVAIL} GB")

# [F] Load(1m) vs cores (讀 /proc/loadavg 瞬間)
CORES=$(nproc 2>/dev/null || echo 1)
LOAD1=$(awk '{print $1}' /proc/loadavg)
L_STATUS="PASS"
awk -v l="${LOAD1}" -v c="${CORES}" 'BEGIN{exit !(l>=c*2)}' && L_STATUS="WARN"
awk -v l="${LOAD1}" -v c="${CORES}" 'BEGIN{exit !(l>=c*4)}' && L_STATUS="FAIL"
RESULTS+=("F|Load(1m) vs cores|${L_STATUS}|${LOAD1} / ${CORES} cores")

END_TS=$(date +%s.%N)
ELAPSED=$(awk -v s="${START_TS}" -v e="${END_TS}" 'BEGIN{printf "%.2f", e-s}')

# ---- 輸出 ----
echo
echo "------------------------------------------------------"
pass=0; warn=0; fail=0
for line in "${RESULTS[@]}"; do
    IFS='|' read -r tag name result note <<<"${line}"
    color=""
    case "${result}" in
        WARN) color="${YEL}"; warn=$((warn+1)) ;;
        FAIL) color="${RED}"; fail=$((fail+1)) ;;
        PASS) pass=$((pass+1)) ;;
    esac
    printf "  [%s] %-22s ${color}%-5s${RST}  %s\n" "${tag}" "${name}" "${result}" "${note}"
done
echo "------------------------------------------------------"
echo " 耗時: ${ELAPSED} 秒    Pass=${pass}  Warn=${warn}  Fail=${fail}"
echo "======================================================"

# ---- 結論 ----
echo
if [ "${fail}" -gt 0 ]; then
    echo -e " 結論: ${RED}FAIL${RST} — 本主機偵測到 ${fail} 項明確異常"
    echo " 建議動作:"
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r tag name result note <<<"${line}"
        [ "${result}" = "FAIL" ] || continue
        case "${tag}" in
            D) echo "   - df -hP 看詳情；主選單 3 找大檔" ;;
            E) echo "   - dmesg -T | grep -i 'killed process' 看 OOM 歷史" ;;
            F) echo "   - ps --sort=-%cpu -eo pid,user,%cpu,comm | head -10" ;;
        esac
    done
    echo
    echo " 深入分析 → 主選單 11 (Troubleshoot 7 面向)"
elif [ "${warn}" -gt 0 ]; then
    echo -e " 結論: ${YEL}WARN${RST} — ${warn} 項警訊，可觀察或與 baseline 對比 (選 16)"
else
    echo " 結論: PASS — 3/3 通過，系統層無異常"
    echo " 建議: 若仍有客訴，問題可能在 AP / 網路 / DBA 端"
fi

audit_log "Triage (lite)" "OK" "Pass=${pass} Warn=${warn} Fail=${fail} (${ELAPSED}s)"

echo
pause
