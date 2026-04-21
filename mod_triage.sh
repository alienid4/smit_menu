#!/bin/bash
# mod_triage.sh - 交易期間輕量診斷 (目標 <1 秒)
# 跟 mod_troubleshoot 的差別：
#   - 只做秒級檢查，不跑會取樣/阻塞的指令 (vmstat/iostat/ss 全掃/journalctl 大 grep)
#   - 不寫 summary/detail 檔，結果直接印在螢幕（方便貼 line / teams）
#   - 只寫一筆 audit log
# 適用：高頻交易主機、系統 freeze 中、尖峰時段
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

clear
echo "======================================================"
echo " 快速 Triage (Trading-hours Safe, 目標 <1 秒)"
echo " 只做秒級檢查，不跑 vmstat/iostat/ss 全掃/大 grep"
echo "======================================================"
read -r -p "Service 名稱 [tomcat] > " SVC || exit 0
SVC="${SVC:-tomcat}"
read -r -p "要檢查的 Port [8080] > " PORT || exit 0
PORT="${PORT:-8080}"

START_TS=$(date +%s.%N)

# ---- 結果收集 ----
declare -a RESULTS

# [A] service is-active (systemctl 呼叫 ≈ 10ms)
SVC_STATE=$(systemctl is-active "${SVC}" 2>/dev/null)
if [ "${SVC_STATE}" = "active" ]; then
    since=$(systemctl show "${SVC}" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2-)
    RESULTS+=("A|service active?|PASS|${SVC} active, since ${since:-N/A}")
else
    RESULTS+=("A|service active?|FAIL|${SVC} = '${SVC_STATE:-unknown}'")
fi

# [B] port listening (ss sport filter 只看 listener table，不掃 established)
LISTEN_LINE=$(ss -tln "sport = :${PORT}" 2>/dev/null | awk 'NR>1' | head -1)
if [ -n "${LISTEN_LINE}" ]; then
    RESULTS+=("B|port ${PORT} listen?|PASS|有 listener")
else
    RESULTS+=("B|port ${PORT} listen?|FAIL|無 listener (connection refused 的直接原因)")
fi

# [C] 近 1 分鐘 service error (journalctl 有 systemd filter 很快)
ERR_CNT=$(journalctl -u "${SVC}" --since '1 min ago' -p err --no-pager -q 2>/dev/null | wc -l)
if [ "${ERR_CNT}" -eq 0 ]; then
    RESULTS+=("C|近 1 分鐘 err log|PASS|0 筆")
elif [ "${ERR_CNT}" -lt 5 ]; then
    RESULTS+=("C|近 1 分鐘 err log|WARN|${ERR_CNT} 筆")
else
    RESULTS+=("C|近 1 分鐘 err log|FAIL|${ERR_CNT} 筆 (爆量)")
fi

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
    echo " 建議動作 (按嚴重度):"
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r tag name result note <<<"${line}"
        [ "${result}" = "FAIL" ] || continue
        case "${tag}" in
            A) echo "   - systemctl status ${SVC} -l --no-pager" ;;
            B) echo "   - ss -tlnp | grep :${PORT}；若真的沒聽，systemctl status ${SVC}" ;;
            C) echo "   - journalctl -u ${SVC} --since '5 min ago' -p err --no-pager" ;;
            D) echo "   - df -hP ; mod_file 找大檔 / 壓縮舊 log" ;;
            E) echo "   - dmesg -T | grep -i 'killed process' 看 OOM 歷史" ;;
            F) echo "   - ps --sort=-%cpu -eo pid,user,%cpu,comm | head -10" ;;
        esac
    done
    echo
    echo " 需要深入分析 → 維運窗口後跑主選單 11 (Troubleshoot 完整版)"
elif [ "${warn}" -gt 0 ]; then
    echo -e " 結論: ${YEL}WARN${RST} — ${warn} 項警訊，可觀察或與客訴時段比對"
    echo " 若客訴時段與警訊累積吻合，下次維運窗口跑主選單 11 看細節"
else
    echo " 結論: PASS — 6/6 通過，本主機端無異常"
    echo " 建議: 問題極可能不在本主機，請通知 AP / 網路 / DBA 組協作"
    echo "       本結果可當 SP 的自證清白快照（已寫入 audit log）"
fi

audit_log "Triage ${SVC}:${PORT}" "OK" "Pass=${pass} Warn=${warn} Fail=${fail} (${ELAPSED}s)"

echo
pause
