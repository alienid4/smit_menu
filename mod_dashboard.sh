#!/bin/bash
# mod_dashboard.sh - 健康儀表板 (lite-v0.2)
# 設計原則：
#   - 純讀 /proc /sys，零寫入、零網路、零重 fork
#   - 正常系統 ~1.5 秒；卡的系統可用 --fast (~0.3 秒)
#   - 每指標附「好壞方向 + 門檻」讓非技術人員也能判讀
#   - 套件不在自動降級顯示 ⚪ N/A，不擋流程
#
# 模式:
#   (no arg)   default  40+ 指標 含 1 秒網卡+iostat 取樣
#   --fast     精簡     只讀即時 /proc，無取樣
#   --full     完整     加 lsof / ethtool -S / dmidecode
#   --simple   淺白     給主管稽核看的淺顯版
#   --json     JSON     給聚合器 / node_exporter textfile 用
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
# 強烈配色（出問題用反白，讓使用者一眼看到）
FAIL_BG=$'\033[41;97;1m'   # 紅底白字粗體
WARN_BG=$'\033[43;30;1m'   # 黃底黑字粗體
PASS_BG=$'\033[42;30m'     # 綠底黑字
HDR_BG=$'\033[46;30;1m'    # 青底黑字粗體（區塊標題用）
BOLD=$'\033[1m'
GRN_EMOJI="🟢"; YEL_EMOJI="🟡"; RED_EMOJI="🔴"; GRY_EMOJI="⚪"

# ---- 讀設定檔 (若有, 用來覆寫預設門檻) ----
HEALTH_CONF="${CASLOG_CONF}/health.conf"
[ -f "${HEALTH_CONF}" ] && . "${HEALTH_CONF}"

# 預設門檻 (金融業合理值；conf 可覆寫)
: "${DISK_WARN_PCT:=80}";      : "${DISK_FAIL_PCT:=95}"
: "${SWAP_WARN_PCT:=10}";      : "${SWAP_FAIL_PCT:=50}"
: "${MEM_AVAIL_GB_WARN:=1.0}"; : "${MEM_AVAIL_GB_FAIL:=0.3}"
: "${LOAD_FACTOR_WARN:=2}";    : "${LOAD_FACTOR_FAIL:=4}"   # × cores
: "${CPU_IDLE_WARN:=10}"
: "${CONNTRACK_WARN:=80}";     : "${CONNTRACK_FAIL:=95}"
: "${CLOSE_WAIT_WARN:=100}";   : "${CLOSE_WAIT_FAIL:=500}"
: "${TIME_WAIT_PCT_WARN:=60}"; : "${TIME_WAIT_PCT_FAIL:=90}"
: "${TCP_RETRANS_WARN_PCT:=1}";: "${TCP_RETRANS_FAIL_PCT:=5}"
: "${FD_WARN_PCT:=80}";        : "${FD_FAIL_PCT:=95}"
: "${NIC_ERR_WARN:=1}"
: "${OOM_WARN:=1}";            : "${OOM_FAIL:=3}"
: "${IOAWAIT_WARN_MS:=20}";    : "${IOAWAIT_FAIL_MS:=100}"
: "${AUTO_DOWNGRADE_LOAD_MULTIPLE:=8}"   # load >= cores × 此值 → 自動 --fast

# ---- 模式解析 ----
MODE="default"
case "${1:-}" in
    --fast)    MODE="fast" ;;
    --full)    MODE="full" ;;
    --simple)  MODE="simple" ;;
    --verbose) MODE="verbose" ;;
    --json)    MODE="json" ;;
    --help|-h)
        cat <<EOF
用法:
  mod_dashboard.sh              預設 (40+ 指標, ~1.5 秒)
  mod_dashboard.sh --fast       精簡 (純 /proc 讀, ~0.3 秒, 卡系統用)
  mod_dashboard.sh --full       完整 (加 lsof/ethtool, ~3 秒)
  mod_dashboard.sh --simple     淺白版 (給主管稽核看)
  mod_dashboard.sh --json       JSON 輸出 (給聚合器用)
EOF
        exit 0 ;;
esac

# ---- 壓力感知自動降級 ----
CORES=$(nproc 2>/dev/null || echo 1)
LOAD1_NOW=$(awk '{print $1}' /proc/loadavg)
if [ "${MODE}" != "fast" ] && [ "${MODE}" != "json" ]; then
    DOWNGRADE_TH=$(awk -v c="${CORES}" -v m="${AUTO_DOWNGRADE_LOAD_MULTIPLE}" 'BEGIN{print c*m}')
    if awk -v l="${LOAD1_NOW}" -v t="${DOWNGRADE_TH}" 'BEGIN{exit !(l>=t)}'; then
        echo -e "${YEL}⚠️  系統壓力極高 (load=${LOAD1_NOW} >= cores × ${AUTO_DOWNGRADE_LOAD_MULTIPLE})${RST}"
        echo -e "${YEL}   自動降級為 --fast，避免加重負擔${RST}"
        MODE="fast"
        sleep 1
    fi
fi

# =============================================================================
# 資料收集
# =============================================================================
declare -A METRIC       # id → "state|value|threshold|direction|label"
declare -a ACTIONS      # 建議動作（有序）
declare -a MISSING_TOOLS
START_TS=$(date +%s.%N)

state_emoji() {
    case "$1" in
        PASS) echo "${GRN_EMOJI}" ;;
        WARN) echo "${YEL_EMOJI}" ;;
        FAIL) echo "${RED_EMOJI}" ;;
        NA|*) echo "${GRY_EMOJI}" ;;
    esac
}

add_metric() {
    # $1=id $2=state $3=value $4=threshold_desc $5=direction_arrow $6=label
    METRIC[$1]="$2|$3|$4|$5|$6"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() {
    if ! has_cmd "$1"; then
        MISSING_TOOLS+=("$1")
        return 1
    fi
    return 0
}

with_timeout() { timeout "$1" "${@:2}" 2>/dev/null; }

# =============================================================================
# 區塊 1: 系統資源 (CPU / Memory / Disk / IO)
# =============================================================================
collect_sys_resources() {
    # --- Load ---
    local lw lf load_state
    lw=$((CORES * LOAD_FACTOR_WARN))
    lf=$((CORES * LOAD_FACTOR_FAIL))
    load_state="PASS"
    awk -v l="${LOAD1_NOW}" -v t="${lf}" 'BEGIN{exit !(l>=t)}' && load_state="FAIL"
    [ "${load_state}" = "PASS" ] && awk -v l="${LOAD1_NOW}" -v t="${lw}" 'BEGIN{exit !(l>=t)}' && load_state="WARN"
    add_metric "cpu_load" "${load_state}" "${LOAD1_NOW}" \
               "[<${lw} 正常 / ≥${lw} 注意 / ≥${lf} 危險]" "↓" "CPU 繁忙度 (Load 1m)"

    # --- CPU idle (default/full 做取樣；fast 只讀瞬間 /proc/stat) ---
    local idle_pct="N/A" idle_state="NA"
    if [ "${MODE}" = "fast" ]; then
        # 瞬間算: /proc/stat user+sys+idle 比例
        idle_pct=$(awk '/^cpu /{idle=$5; total=0; for(i=2;i<=8;i++)total+=$i; printf "%.0f", (idle/total)*100}' /proc/stat 2>/dev/null)
    else
        if has_cmd vmstat; then
            idle_pct=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $15}')
        else
            idle_pct="N/A"; MISSING_TOOLS+=("vmstat")
        fi
    fi
    if [ "${idle_pct}" != "N/A" ] && [ -n "${idle_pct}" ]; then
        idle_state="PASS"
        [ "${idle_pct:-100}" -lt "${CPU_IDLE_WARN}" ] 2>/dev/null && idle_state="WARN"
    fi
    add_metric "cpu_idle" "${idle_state}" "${idle_pct}%" \
               "[≥${CPU_IDLE_WARN}% 正常 / <${CPU_IDLE_WARN}% 注意]" "↑" "CPU 閒置率"

    # --- CPU steal (VM 下被宿主壓榨) ---
    local steal="N/A" steal_state="NA"
    if [ "${MODE}" != "fast" ] && has_cmd vmstat; then
        steal=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $17}')
        [ -n "${steal}" ] && {
            steal_state="PASS"
            [ "${steal:-0}" -gt 5 ] 2>/dev/null && steal_state="WARN"
        }
    fi
    add_metric "cpu_steal" "${steal_state}" "${steal}${steal:+%}" \
               "[=0 正常 / >5% 注意: VM 被壓榨]" "↓" "CPU steal (VM)"

    # --- Memory available ---
    local mem_avail_kb mem_avail_gb mem_state
    mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    mem_avail_gb=$(awk -v k="${mem_avail_kb:-0}" 'BEGIN{printf "%.2f", k/1048576}')
    mem_state="PASS"
    awk -v m="${mem_avail_gb}" -v w="${MEM_AVAIL_GB_WARN}" 'BEGIN{exit !(m<w)}' && mem_state="WARN"
    awk -v m="${mem_avail_gb}" -v f="${MEM_AVAIL_GB_FAIL}" 'BEGIN{exit !(m<f)}' && mem_state="FAIL"
    add_metric "mem_avail" "${mem_state}" "${mem_avail_gb} GB" \
               "[≥${MEM_AVAIL_GB_WARN} 正常 / <${MEM_AVAIL_GB_WARN} 注意 / <${MEM_AVAIL_GB_FAIL} 危險]" "↑" "可用記憶體"

    # --- Swap ---
    local swap_pct swap_state
    swap_pct=$(awk '/^Swap(Total|Free):/ {v[$1]=$2} END{t=v["SwapTotal:"]; f=v["SwapFree:"]; if(t>0)printf "%d",((t-f)/t)*100; else print 0}' /proc/meminfo)
    swap_state="PASS"
    [ "${swap_pct:-0}" -ge "${SWAP_WARN_PCT}" ] && swap_state="WARN"
    [ "${swap_pct:-0}" -ge "${SWAP_FAIL_PCT}" ] && swap_state="FAIL"
    add_metric "swap" "${swap_state}" "${swap_pct}%" \
               "[<${SWAP_WARN_PCT}% 正常 / ≥${SWAP_WARN_PCT}% 注意 / ≥${SWAP_FAIL_PCT}% 危險]" "↓" "Swap 使用率"

    # --- Disk max (timeout protected 防斷 NFS 卡死) ---
    local d_info disk_pct disk_mnt disk_state
    d_info=$(with_timeout 3 df -hP 2>/dev/null | awk 'NR>1 && $6!~/^\/(dev|proc|sys|run)/ {gsub(/%/,"",$5); print $5, $6}' | sort -rn | head -1)
    disk_pct=$(echo "${d_info}" | awk '{print $1}')
    disk_mnt=$(echo "${d_info}" | awk '{print $2}')
    disk_pct="${disk_pct:-0}"
    disk_state="PASS"
    [ "${disk_pct}" -ge "${DISK_WARN_PCT}" ] 2>/dev/null && disk_state="WARN"
    [ "${disk_pct}" -ge "${DISK_FAIL_PCT}" ] 2>/dev/null && disk_state="FAIL"
    add_metric "disk_max" "${disk_state}" "${disk_pct}% @ ${disk_mnt:-?}" \
               "[<${DISK_WARN_PCT} 正常 / ${DISK_WARN_PCT}-$((DISK_FAIL_PCT-1)) 注意 / ≥${DISK_FAIL_PCT} 危險]" "↓" "磁碟使用率 (最滿)"

    # --- Inode max ---
    local inode_pct inode_state
    inode_pct=$(with_timeout 3 df -i 2>/dev/null | awk 'NR>1 && $5~/%/ && $6!~/^\/(dev|proc|sys|run)/ {gsub(/%/,"",$5); print $5}' | sort -rn | head -1)
    inode_pct="${inode_pct:-0}"
    inode_state="PASS"
    [ "${inode_pct}" -ge "${DISK_WARN_PCT}" ] 2>/dev/null && inode_state="WARN"
    [ "${inode_pct}" -ge "${DISK_FAIL_PCT}" ] 2>/dev/null && inode_state="FAIL"
    add_metric "inode_max" "${inode_state}" "${inode_pct}%" \
               "[<${DISK_WARN_PCT} 正常 / ≥${DISK_WARN_PCT} 注意]" "↓" "Inode 使用率"

    # --- IO await (default/full) ---
    local iow="N/A" iow_state="NA"
    if [ "${MODE}" = "default" ] || [ "${MODE}" = "full" ]; then
        if has_cmd iostat; then
            iow=$(iostat -x 1 2 2>/dev/null | awk '/^[sv]d[a-z]|^nvme|^dm-/ && NR>10 {if($NF+0>max)max=$NF+0} END{printf "%.0f", max+0}')
            iow_state="PASS"
            [ "${iow:-0}" -ge "${IOAWAIT_WARN_MS}" ] && iow_state="WARN"
            [ "${iow:-0}" -ge "${IOAWAIT_FAIL_MS}" ] && iow_state="FAIL"
        else
            MISSING_TOOLS+=("iostat (sysstat)")
        fi
    fi
    add_metric "io_await" "${iow_state}" "${iow}${iow:+ ms}" \
               "[<${IOAWAIT_WARN_MS}ms 正常 / ≥${IOAWAIT_WARN_MS} 注意]" "↓" "磁碟延遲 (IO await)"

    # --- PSI (kernel 5.2+) ---
    local psi_mem="N/A" psi_io="N/A"
    if [ -r /proc/pressure/memory ]; then
        psi_mem=$(awk '/^some/{gsub("avg60=",""); print $3}' /proc/pressure/memory | tr -d ',')
    fi
    if [ -r /proc/pressure/io ]; then
        psi_io=$(awk '/^some/{gsub("avg60=",""); print $3}' /proc/pressure/io | tr -d ',')
    fi
    add_metric "psi_mem" "PASS" "${psi_mem}${psi_mem:+%}" "[<5% 正常]" "↓" "PSI memory 壓力 60s"
    add_metric "psi_io"  "PASS" "${psi_io}${psi_io:+%}"   "[<5% 正常]" "↓" "PSI io 壓力 60s"
}

# =============================================================================
# 區塊 2: Session / TCP
# =============================================================================
collect_session() {
    if ! has_cmd ss; then
        add_metric "session" "NA" "-" "[需 iproute2]" "" "TCP session"
        return
    fi

    local est cw tw synrecv orphan sshn
    est=$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)
    cw=$(ss -tn state close-wait 2>/dev/null | tail -n +2 | wc -l)
    tw=$(ss -tn state time-wait 2>/dev/null | tail -n +2 | wc -l)
    synrecv=$(ss -tn state syn-recv 2>/dev/null | tail -n +2 | wc -l)
    orphan=$(awk '/TCP/ {print $9}' /proc/net/sockstat 2>/dev/null | head -1)
    sshn=$(who 2>/dev/null | wc -l)

    local cw_state="PASS"
    [ "${cw}" -gt "${CLOSE_WAIT_WARN}" ] && cw_state="WARN"
    [ "${cw}" -gt "${CLOSE_WAIT_FAIL}" ] && cw_state="FAIL"

    # TIME_WAIT 佔 ephemeral port range 比例
    local port_lo port_hi range tw_pct tw_state="PASS"
    read -r port_lo port_hi < <(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null)
    if [ -n "${port_lo}" ] && [ -n "${port_hi}" ]; then
        range=$((port_hi - port_lo + 1))
        tw_pct=$(awk -v t="${tw}" -v r="${range}" 'BEGIN{if(r>0)printf "%.0f",(t/r)*100; else print 0}')
        [ "${tw_pct}" -ge "${TIME_WAIT_PCT_WARN}" ] && tw_state="WARN"
        [ "${tw_pct}" -ge "${TIME_WAIT_PCT_FAIL}" ] && tw_state="FAIL"
    else
        tw_pct="N/A"
    fi

    add_metric "sess_est" "PASS" "${est}" "[視主機承載]" "" "進行中連線數"
    add_metric "sess_cw"  "${cw_state}" "${cw}" \
               "[<${CLOSE_WAIT_WARN} 正常 / ≥${CLOSE_WAIT_WARN} 注意 (疑 AP 沒關 socket)]" "↓" "半關連線 CLOSE_WAIT"
    add_metric "sess_tw"  "${tw_state}" "${tw_pct}%" \
               "[<${TIME_WAIT_PCT_WARN}% 正常 / ≥${TIME_WAIT_PCT_FAIL}% 危險 (新連線會失敗)]" "↓" "TIME_WAIT 佔比"
    add_metric "sess_syn" "PASS" "${synrecv}" "[正常低；高=尖峰或攻擊]" "↓" "半連線 SYN_RECV"
    add_metric "sess_orph" "PASS" "${orphan:-0}" "[多=kernel memory 洩漏]" "↓" "Orphan sockets"
    add_metric "sess_ssh" "PASS" "${sshn}" "[本就沒人連=0 正常]" "" "SSH 登入人數"

    if [ "${cw_state}" != "PASS" ]; then
        ACTIONS+=("${cw_state}|ss -tnp state close-wait | head          (${cw} 條 CLOSE_WAIT，查哪個 PID)")
    fi
    if [ "${tw_state}" != "PASS" ] && [ "${tw_pct}" != "N/A" ]; then
        ACTIONS+=("${tw_state}|sysctl net.ipv4.ip_local_port_range     (拉大 ephemeral port)")
    fi
}

# =============================================================================
# 區塊 3: 網路流量 / NIC
# =============================================================================
collect_network() {
    # --- conntrack ---
    local ct_state="NA" ct_pct="N/A" ct_c ct_m
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        ct_c=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
        ct_m=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
        ct_pct=$(awk -v c="${ct_c}" -v m="${ct_m}" 'BEGIN{if(m>0)printf "%.0f",(c/m)*100; else print 0}')
        ct_state="PASS"
        [ "${ct_pct}" -ge "${CONNTRACK_WARN}" ] && ct_state="WARN"
        [ "${ct_pct}" -ge "${CONNTRACK_FAIL}" ] && ct_state="FAIL"
    fi
    add_metric "net_conntrack" "${ct_state}" "${ct_pct}%${ct_c:+ (${ct_c}/${ct_m})}" \
               "[<${CONNTRACK_WARN}% 正常 / ≥${CONNTRACK_FAIL}% 危險 (新連線被默默丟)]" "↓" "網路追蹤表用量"

    # --- TCP retrans ---
    local tseg tret retrans_pct retrans_state
    tseg=$(awk '/^Tcp:/ && h++{print $11}' /proc/net/snmp | head -1)
    tret=$(awk '/^Tcp:/ && h++{print $13}' /proc/net/snmp | head -1)
    if [ -n "${tseg}" ] && [ "${tseg}" -gt 0 ]; then
        retrans_pct=$(awk -v r="${tret}" -v s="${tseg}" 'BEGIN{printf "%.3f",(r/s)*100}')
    else
        retrans_pct="0.000"
    fi
    retrans_state="PASS"
    awk -v p="${retrans_pct}" -v w="${TCP_RETRANS_WARN_PCT}" 'BEGIN{exit !(p>=w)}' && retrans_state="WARN"
    awk -v p="${retrans_pct}" -v f="${TCP_RETRANS_FAIL_PCT}" 'BEGIN{exit !(p>=f)}' && retrans_state="FAIL"
    add_metric "net_retrans" "${retrans_state}" "${retrans_pct}%" \
               "[<${TCP_RETRANS_WARN_PCT}% 正常 / ≥${TCP_RETRANS_FAIL_PCT}% 危險]" "↓" "TCP 封包重送率"

    # --- NIC errors cumulative ---
    local tot_err=0 tot_drop=0
    for nic in $(ls /sys/class/net/ 2>/dev/null | grep -v '^lo$'); do
        for k in rx_errors tx_errors rx_dropped tx_dropped; do
            local v=$(cat /sys/class/net/${nic}/statistics/${k} 2>/dev/null || echo 0)
            case "$k" in
                *errors) tot_err=$((tot_err + v)) ;;
                *dropped) tot_drop=$((tot_drop + v)) ;;
            esac
        done
    done
    local err_state="PASS"
    [ "$((tot_err + tot_drop))" -gt 0 ] && err_state="WARN"
    add_metric "net_err" "${err_state}" "${tot_err}/${tot_drop}" \
               "[=0/0 正常 / >0 注意]" "=" "NIC 累積 錯誤/丟棄"

    # --- 1 秒取樣 rx/tx pps (只在 default/full) ---
    local rx_pps="N/A" tx_pps="N/A" rx_mbps="N/A" tx_mbps="N/A"
    if [ "${MODE}" = "default" ] || [ "${MODE}" = "full" ]; then
        local pnic rx0 tx0 rxp0 txp0 rx1 tx1 rxp1 txp1
        pnic=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}' | head -1)
        pnic="${pnic:-eth0}"
        if [ -r /sys/class/net/${pnic}/statistics/rx_bytes ]; then
            rx0=$(cat /sys/class/net/${pnic}/statistics/rx_bytes)
            tx0=$(cat /sys/class/net/${pnic}/statistics/tx_bytes)
            rxp0=$(cat /sys/class/net/${pnic}/statistics/rx_packets)
            txp0=$(cat /sys/class/net/${pnic}/statistics/tx_packets)
            sleep 1
            rx1=$(cat /sys/class/net/${pnic}/statistics/rx_bytes)
            tx1=$(cat /sys/class/net/${pnic}/statistics/tx_bytes)
            rxp1=$(cat /sys/class/net/${pnic}/statistics/rx_packets)
            txp1=$(cat /sys/class/net/${pnic}/statistics/tx_packets)
            rx_mbps=$(awk -v a="${rx0}" -v b="${rx1}" 'BEGIN{printf "%.1f",(b-a)/1048576}')
            tx_mbps=$(awk -v a="${tx0}" -v b="${tx1}" 'BEGIN{printf "%.1f",(b-a)/1048576}')
            rx_pps=$((rxp1 - rxp0))
            tx_pps=$((txp1 - txp0))
        fi
    fi
    add_metric "net_rx" "PASS" "${rx_mbps}${rx_mbps:+ MB/s (pps ${rx_pps})}" "[視工作負載]" "" "網卡 rx (流入)"
    add_metric "net_tx" "PASS" "${tx_mbps}${tx_mbps:+ MB/s (pps ${tx_pps})}" "[視工作負載]" "" "網卡 tx (流出)"
}

# =============================================================================
# 區塊 4: File / FD
# =============================================================================
collect_fd() {
    # 全系統 open files
    local sys_cur sys_max sys_pct sys_state
    read -r sys_cur _ sys_max < /proc/sys/fs/file-nr 2>/dev/null
    sys_pct=$(awk -v c="${sys_cur:-0}" -v m="${sys_max:-1}" 'BEGIN{if(m>0)printf "%.1f",(c/m)*100; else print 0}')
    sys_state="PASS"
    awk -v p="${sys_pct}" -v w="${FD_WARN_PCT}" 'BEGIN{exit !(p>=w)}' && sys_state="WARN"
    awk -v p="${sys_pct}" -v f="${FD_FAIL_PCT}" 'BEGIN{exit !(p>=f)}' && sys_state="FAIL"
    add_metric "fd_sys" "${sys_state}" "${sys_pct}% (${sys_cur:-?}/${sys_max:-?})" \
               "[<${FD_WARN_PCT}% 正常 / ≥${FD_FAIL_PCT}% 危險]" "↓" "全系統 open files"

    # Top-1 FD — 只在 --full 才掃 (掃全 /proc 慢)；否則 N/A
    local top_pid top_count top_limit top_pct top_state="NA" top_comm
    if [ "${MODE}" = "full" ]; then
        top_pid=$(for p in /proc/[0-9]*; do
            pid=${p##*/}
            n=$(ls "$p/fd" 2>/dev/null | wc -l)
            echo "$n $pid"
        done 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
        if [ -n "${top_pid}" ] && [ -d /proc/${top_pid} ]; then
            top_count=$(ls /proc/${top_pid}/fd 2>/dev/null | wc -l)
            top_limit=$(awk '/^Max open files/{print $4}' /proc/${top_pid}/limits 2>/dev/null)
            top_comm=$(cat /proc/${top_pid}/comm 2>/dev/null)
            # 避免天文數字 (systemd 常設 RLIMIT=infinity 顯示為 10^9)
            if [ -n "${top_limit}" ] && [ "${top_limit}" -gt 0 ] && [ "${top_limit}" -lt 1048576 ]; then
                top_pct=$(awk -v c="${top_count}" -v l="${top_limit}" 'BEGIN{printf "%.0f",(c/l)*100}')
                top_state="PASS"
                awk -v p="${top_pct}" -v w="${FD_WARN_PCT}" 'BEGIN{exit !(p>=w)}' && top_state="WARN"
                [ "${top_pct}" -ge 100 ] 2>/dev/null && top_state="FAIL"
            else
                # RLIMIT 過大或 infinity (systemd 等) — 不該當警告
                top_state="PASS"
                top_pct="low"
            fi
        fi
    fi
    add_metric "fd_top" "${top_state:-NA}" "${top_pct:-N/A}${top_count:+ (${top_count}/${top_limit:-∞} PID ${top_pid} ${top_comm})}" \
               "[<${FD_WARN_PCT}% 正常 / ≥100% 已超上限 — 僅 --full 掃]" "↓" "最多 FD 程式"
    if [ "${top_state}" = "WARN" ] || [ "${top_state}" = "FAIL" ]; then
        ACTIONS+=("${top_state}|ls -la /proc/${top_pid}/fd | head -30                 (查 ${top_comm} FD 用在哪)")
    fi

    # inotify watches
    if [ -r /proc/sys/fs/inotify/max_user_watches ]; then
        local ino_max
        ino_max=$(cat /proc/sys/fs/inotify/max_user_watches)
        add_metric "fd_inotify" "PASS" "max=${ino_max}" "[預設 8192~65535]" "" "inotify max_user_watches"
    fi

    # PID / Thread count
    local pid_cnt pid_max thr_cnt thr_max
    pid_cnt=$(ls /proc/[0-9]* 2>/dev/null -d | wc -l)
    pid_max=$(cat /proc/sys/kernel/pid_max 2>/dev/null)
    thr_max=$(cat /proc/sys/kernel/threads-max 2>/dev/null)
    thr_cnt=$(wc -l /proc/*/task/* 2>/dev/null | tail -1 | awk '{print $1}')
    add_metric "fd_pid" "PASS" "${pid_cnt}/${pid_max}" "[<80% 正常]" "↓" "PID 使用量"
}

# =============================================================================
# 區塊 5: Infra 歷史 (OOM / MCE / systemd failed / taint)
# =============================================================================
collect_infra() {
    local oom mce failed failed_list taint oom_state="PASS" failed_state="PASS"

    oom=$(with_timeout 3 journalctl -k --since '24 hour ago' --no-pager -q 2>/dev/null | grep -ci 'killed process' 2>/dev/null)
    oom="${oom:-0}"; oom="${oom//[^0-9]/}"; oom="${oom:-0}"
    [ "${oom}" -ge "${OOM_WARN}" ] 2>/dev/null && oom_state="WARN"
    [ "${oom}" -ge "${OOM_FAIL}" ] 2>/dev/null && oom_state="FAIL"

    mce=$(with_timeout 3 dmesg -T 2>/dev/null | grep -ciE 'mce:|hardware error|edac.*correct|ecc error' 2>/dev/null)
    mce="${mce:-0}"; mce="${mce//[^0-9]/}"; mce="${mce:-0}"

    failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    [ "${failed}" -gt 0 ] && failed_state="WARN"
    [ "${failed}" -gt 3 ] && failed_state="FAIL"
    failed_list=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')

    taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo 0)
    local taint_state="PASS"
    [ "${taint:-0}" -ne 0 ] && taint_state="WARN"

    local mce_state="PASS"
    [ "${mce}" -gt 0 ] && mce_state="FAIL"

    add_metric "infra_oom" "${oom_state}" "${oom}" "[=0 正常 / ≥${OOM_FAIL} 危險]" "=" "24h OOM 殺程式次數"
    add_metric "infra_mce" "${mce_state}" "${mce}" "[=0 正常 / >0 硬體記憶體壞]" "=" "硬體記憶體錯誤"
    add_metric "infra_failed" "${failed_state}" "${failed}${failed_list:+ (${failed_list})}" \
               "[=0 正常 / >0 有服務掛掉]" "=" "異常 systemd 服務"
    add_metric "infra_taint" "${taint_state}" "${taint}" "[=0 正常]" "=" "kernel 異常標記"

    if [ "${failed_state}" != "PASS" ] && [ -n "${failed_list}" ]; then
        ACTIONS+=("${failed_state}|systemctl status ${failed_list//,/ }      (先處理異常服務)")
    fi
    if [ "${oom_state}" != "PASS" ]; then
        ACTIONS+=("${oom_state}|dmesg -T | grep -i 'killed process'       (查 OOM 細節)")
    fi
}

# =============================================================================
# 區塊 6: 合規 / 憑證
# =============================================================================
collect_compliance() {
    # NTP
    local ntp_sync ntp_state
    ntp_sync=$(with_timeout 2 timedatectl 2>/dev/null | awk -F: '/synchronized/{gsub(/^ */,"",$2); print $2}')
    ntp_sync="${ntp_sync:-unknown}"
    ntp_state="PASS"
    [ "${ntp_sync}" != "yes" ] && ntp_state="WARN"
    add_metric "comp_ntp" "${ntp_state}" "${ntp_sync}" "[yes 正常]" "=" "時間同步 (NTP)"

    # 憑證 30 天內到期
    local cert_warn=0 cert_fail=0
    local defks="${JAVA_HOME:-/usr/lib/jvm/default}/lib/security/cacerts"
    if has_cmd keytool && [ -f "${defks}" ] && [ "${MODE}" != "fast" ]; then
        read -r cert_warn cert_fail < <(with_timeout 5 keytool -list -v -keystore "${defks}" -storepass changeit 2>/dev/null | awk '
            /Valid from/ {
                sub(/.*until: /,""); exp=$0
                cmd="date -d \""exp"\" +%s 2>/dev/null"
                if ((cmd|getline ts)>0) {
                    d=int((ts-systime())/86400)
                    if (d<0) f++
                    else if (d<30) w++
                }
                close(cmd)
            }
            END { print w+0, f+0 }')
    fi
    local cert_state="PASS"
    [ "${cert_warn:-0}" -gt 0 ] && cert_state="WARN"
    [ "${cert_fail:-0}" -gt 0 ] && cert_state="FAIL"
    add_metric "comp_cert" "${cert_state}" "${cert_warn:-0}/${cert_fail:-0}" \
               "[0/0 正常 / 右邊 >0 已過期]" "=" "憑證 30 天內到期/已過期"

    # Append-only 保護數
    local protected=0
    if has_cmd lsattr; then
        protected=$(lsattr "${CASLOG_LOG}"/*.log 2>/dev/null | awk '{print $1}' | grep -c 'a' || echo 0)
    fi
    add_metric "comp_append" "PASS" "${protected} 檔" "[log 應設 append-only]" "↑" "Log 防竄改保護"

    # 昨日 seal
    local seal_state="PASS" seal_info="未 seal 過"
    if [ -f "${CASLOG_LOG}/audit_seal.manifest" ]; then
        local seal_n
        seal_n=$(wc -l < "${CASLOG_LOG}/audit_seal.manifest")
        seal_info="manifest ${seal_n} 筆"
    else
        seal_state="WARN"
    fi
    add_metric "comp_seal" "${seal_state}" "${seal_info}" "[定期 seal 正常]" "" "審計封存 (HMAC)"
}

# =============================================================================
# 區塊 6.5: 帳號鎖定 / 密碼到期 (金融業 service account 被誤鎖 = AP 連不上 DB)
# =============================================================================
collect_accounts() {
    # 被鎖帳號數 — 用 awk 一次讀 /etc/shadow (快 50 倍 vs passwd -S 逐個 fork)
    # shadow 第二欄以 ! 開頭 = locked；* 開頭 = 永不能登入(系統帳號，不算鎖)
    local locked_n=0 locked_list=""
    if [ -r /etc/shadow ]; then
        locked_n=$(awk -F: '$2 ~ /^!/ {print $1}' /etc/shadow | wc -l)
        # 抓真正的「service account」(有可登入 UID >= 500，名字看起來像服務用)
        locked_list=$(awk -F: '$2 ~ /^!/ {print $1}' /etc/shadow | grep -E '^(svc|app|ap|db|web|tomcat|nginx|mysql|oracle|postgres|jboss|kafka)' | tr '\n' ' ')
    fi
    local locked_state="PASS"
    # service account 被鎖 → FAIL (會影響服務)
    [ -n "${locked_list}" ] && locked_state="FAIL"
    # 一般帳號被鎖多 (>5) → WARN (可能 fail2ban 誤判)
    [ "${locked_n}" -gt 5 ] && [ "${locked_state}" = "PASS" ] && locked_state="WARN"
    add_metric "acc_locked" "${locked_state}" "${locked_n}${locked_list:+ (svc: ${locked_list})}" \
               "[=0 最佳 / service 帳號被鎖 = AP 連不上]" "↓" "被鎖帳號數"

    # 密碼已過期 / 7 天內到期
    local now_day=$(( $(date +%s) / 86400 ))
    local pw_expired=0 pw_warn=0
    if [ -r /etc/shadow ]; then
        while IFS=: read -r u _ lastchg _ maxd _; do
            [ -z "${maxd}" ] && continue
            [ "${maxd}" = "99999" ] && continue    # 永不過期
            [ "${lastchg:-0}" -eq 0 ] && continue  # 從未設密碼 (root 常這樣)
            [ -z "${lastchg}" ] && continue
            local expire_day=$(( lastchg + maxd ))
            local days_left=$(( expire_day - now_day ))
            if [ "${days_left}" -lt 0 ]; then
                pw_expired=$((pw_expired+1))
            elif [ "${days_left}" -lt 7 ]; then
                pw_warn=$((pw_warn+1))
            fi
        done < /etc/shadow
    fi
    local pw_state="PASS"
    [ "${pw_warn}" -gt 0 ] && pw_state="WARN"
    [ "${pw_expired}" -gt 0 ] && pw_state="FAIL"
    add_metric "acc_pw" "${pw_state}" "${pw_expired}/${pw_warn}" \
               "[已過期/7日內到期；=0/0 正常 / 左邊 >0 已有帳號無法登入]" "↓" "密碼過期/即將到期"

    # UID=0 帳號數 (應該 = 1 = 只有 root)
    local uid0_n
    uid0_n=$(awk -F: '$3==0' /etc/passwd | wc -l)
    local uid0_state="PASS"
    [ "${uid0_n}" -gt 1 ] && uid0_state="FAIL"
    add_metric "acc_uid0" "${uid0_state}" "${uid0_n}" "[應=1，>1 可能是後門]" "=" "UID=0 帳號數"

    # 空密碼帳號
    local empty_pw=0
    if [ -r /etc/shadow ]; then
        empty_pw=$(awk -F: '$2==""' /etc/shadow | wc -l)
    fi
    local epw_state="PASS"
    [ "${empty_pw}" -gt 0 ] && epw_state="FAIL"
    add_metric "acc_emptypw" "${epw_state}" "${empty_pw}" "[應=0，>0 為合規問題]" "=" "空密碼帳號"

    # 若有異常，加入 ACTION 與通知
    if [ "${locked_state}" = "FAIL" ]; then
        ACTIONS+=("FAIL|faillock --user <svc> --reset   (service 帳號被鎖, 解鎖後排查)")
    fi
    if [ "${pw_state}" = "FAIL" ]; then
        ACTIONS+=("FAIL|chage -l <user>                 (檢查密碼過期設定)")
    fi
    if [ "${uid0_state}" = "FAIL" ]; then
        ACTIONS+=("FAIL|awk -F: '\$3==0' /etc/passwd    (查 UID=0 帳號來源!)")
    fi
}

# =============================================================================
# 區塊 7: 近 1h 運維軌跡
# =============================================================================
collect_ops_trail() {
    local since_1h
    since_1h=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M' 2>/dev/null)
    local login_n etc_n svc_n combined_state="PASS"

    login_n=$(with_timeout 3 last -s "${since_1h}" 2>/dev/null | grep -c -v '^$\|^wtmp begins' 2>/dev/null)
    login_n="${login_n:-0}"
    etc_n=$(with_timeout 3 find /etc -mmin -60 -type f 2>/dev/null | wc -l)
    svc_n=$(with_timeout 3 journalctl --since '1 hour ago' --no-pager -q 2>/dev/null | grep -ciE 'Started|Stopped|Restarted' || echo 0)

    # 3 項都 >0 代表「剛動過」，需要 SP 注意
    if [ "${login_n}" -gt 0 ] && [ "${etc_n}" -gt 0 ] && [ "${svc_n}" -gt 0 ]; then
        combined_state="WARN"
    fi

    add_metric "ops_login" "PASS" "${login_n}" "[異動期間才會 >0]" "" "近 1h 登入次數"
    add_metric "ops_etc"   "PASS" "${etc_n}"   "[變更期間才會 >0]" "" "近 1h /etc 異動"
    add_metric "ops_svc"   "${combined_state}" "${svc_n}" "[異常期間才會 >0]" "" "近 1h service 事件"
}

# =============================================================================
# 通知建議 (根據異常自動歸類該通知哪個單位)
# =============================================================================
declare -a NOTIFY_SEC      # 資安
declare -a NOTIFY_NET      # 網路
declare -a NOTIFY_DBA      # DBA
declare -a NOTIFY_AP       # AP 團隊
declare -a NOTIFY_HW       # 硬體 / 機房
declare -a NOTIFY_SP       # SP 自己

build_notifications() {
    # 資安：合規/稽核類 FAIL
    local ck_state="${METRIC[comp_cert]%%|*}"
    [ "${ck_state}" = "FAIL" ] && NOTIFY_SEC+=("有憑證已過期 → 憑證更新流程")
    local sl_state="${METRIC[comp_seal]%%|*}"
    [ "${sl_state}" = "WARN" ] || [ "${sl_state}" = "FAIL" ] && NOTIFY_SEC+=("審計封存異常")

    # 網路：TCP retrans / conntrack / NIC err
    local rt_state="${METRIC[net_retrans]%%|*}"
    [ "${rt_state}" = "WARN" ] || [ "${rt_state}" = "FAIL" ] && {
        local rt_v
        rt_v=$(echo "${METRIC[net_retrans]}" | cut -d'|' -f2)
        NOTIFY_NET+=("TCP 封包重送率 ${rt_v} (上游網路或對端 ack 問題)")
    }
    local ct_state="${METRIC[net_conntrack]%%|*}"
    [ "${ct_state}" = "WARN" ] || [ "${ct_state}" = "FAIL" ] && {
        local ct_v
        ct_v=$(echo "${METRIC[net_conntrack]}" | cut -d'|' -f2)
        NOTIFY_NET+=("conntrack 用量 ${ct_v} (需擴表或檢查連線洩漏)")
    }
    local err_state="${METRIC[net_err]%%|*}"
    [ "${err_state}" = "WARN" ] && {
        local err_v
        err_v=$(echo "${METRIC[net_err]}" | cut -d'|' -f2)
        NOTIFY_NET+=("NIC 累積 err/drop ${err_v} (實體線/SFP/交換器)")
    }

    # DBA：systemd failed 含 DB 名 / CLOSE_WAIT 到 DB port (lite 不檢 DB port 但保留邏輯)
    local failed_v="${METRIC[infra_failed]}"
    if echo "${failed_v}" | grep -qiE 'mysql|mariadb|postgres|oracle|mongod|db2'; then
        NOTIFY_DBA+=("systemd 失敗服務含 DB: $(echo "${failed_v}" | cut -d'|' -f2)")
    fi

    # AP 團隊：systemd failed (非 DB)
    if echo "${failed_v}" | grep -qiE 'nginx|tomcat|httpd|apache|node|java|php-fpm'; then
        NOTIFY_AP+=("systemd 失敗服務含 AP: $(echo "${failed_v}" | cut -d'|' -f2)")
    fi
    # FD 洩漏 (Top-1 接近上限 = AP 開 FD 沒關)
    local fd_state="${METRIC[fd_top]%%|*}"
    [ "${fd_state}" = "WARN" ] || [ "${fd_state}" = "FAIL" ] && {
        local fd_v
        fd_v=$(echo "${METRIC[fd_top]}" | cut -d'|' -f2)
        NOTIFY_AP+=("有程式 FD 接近上限 ${fd_v} (疑 AP socket/file 洩漏)")
    }
    # CLOSE_WAIT 多 = AP 沒關 socket
    local cw_state="${METRIC[sess_cw]%%|*}"
    [ "${cw_state}" = "WARN" ] || [ "${cw_state}" = "FAIL" ] && {
        local cw_v
        cw_v=$(echo "${METRIC[sess_cw]}" | cut -d'|' -f2)
        NOTIFY_AP+=("CLOSE_WAIT ${cw_v} 條 (AP 未妥善關閉連線)")
    }

    # 硬體：MCE / OOM 嚴重
    local mce_state="${METRIC[infra_mce]%%|*}"
    [ "${mce_state}" = "FAIL" ] && NOTIFY_HW+=("硬體記憶體錯誤 (ECC/MCE) - 請硬體廠商檢查記憶體")
    local oom_state="${METRIC[infra_oom]%%|*}"
    [ "${oom_state}" = "FAIL" ] && NOTIFY_HW+=("24h OOM kill 過多 - 可能記憶體規劃不足")

    # 帳號鎖定 / 合規
    local locked_state="${METRIC[acc_locked]%%|*}"
    if [ "${locked_state}" = "FAIL" ]; then
        NOTIFY_SEC+=("service 帳號被鎖 → AP 可能連不上 DB/其他系統")
        NOTIFY_AP+=("若該帳號是 AP 用 → 確認 AP 是否連線失敗中")
    elif [ "${locked_state}" = "WARN" ]; then
        NOTIFY_SEC+=("被鎖帳號數偏多 → 可能 fail2ban 誤判或暴力破解")
    fi
    local uid0_state="${METRIC[acc_uid0]%%|*}"
    [ "${uid0_state}" = "FAIL" ] && NOTIFY_SEC+=("多個 UID=0 帳號 → 疑後門，立即調查")
    local epw_state="${METRIC[acc_emptypw]%%|*}"
    [ "${epw_state}" = "FAIL" ] && NOTIFY_SEC+=("發現空密碼帳號 → 合規問題，立即鎖定")
    local pw_state="${METRIC[acc_pw]%%|*}"
    [ "${pw_state}" = "FAIL" ] && NOTIFY_SEC+=("有帳號密碼已過期 → 聯絡帳號負責人重設")

    # SP 自己處理
    local ntp_state="${METRIC[comp_ntp]%%|*}"
    [ "${ntp_state}" = "WARN" ] && NOTIFY_SP+=("NTP 未同步 → systemctl restart chronyd")
    local disk_state="${METRIC[disk_max]%%|*}"
    [ "${disk_state}" = "WARN" ] || [ "${disk_state}" = "FAIL" ] && {
        local disk_v
        disk_v=$(echo "${METRIC[disk_max]}" | cut -d'|' -f2)
        NOTIFY_SP+=("磁碟 ${disk_v} 清理 (du -sh /var/* 找大檔)")
    }
    local swap_state="${METRIC[swap]%%|*}"
    [ "${swap_state}" = "WARN" ] && NOTIFY_SP+=("Swap 已用，確認無記憶體壓力 (dmesg -T | grep killed)")
}

print_notifications() {
    local has_any=0
    [ ${#NOTIFY_SEC[@]} -gt 0 ] && has_any=1
    [ ${#NOTIFY_NET[@]} -gt 0 ] && has_any=1
    [ ${#NOTIFY_DBA[@]} -gt 0 ] && has_any=1
    [ ${#NOTIFY_AP[@]}  -gt 0 ] && has_any=1
    [ ${#NOTIFY_HW[@]}  -gt 0 ] && has_any=1
    [ ${#NOTIFY_SP[@]}  -gt 0 ] && has_any=1
    [ "${has_any}" -eq 0 ] && return

    echo "├─ 通知建議 (自動依異常歸類) $(printf '─%.0s' $(seq 1 38))─┤"
    if [ ${#NOTIFY_SEC[@]} -gt 0 ]; then
        echo "│   🟣 資安單位 (Security):"
        for n in "${NOTIFY_SEC[@]}"; do echo "│      - ${n}"; done
    fi
    if [ ${#NOTIFY_NET[@]} -gt 0 ]; then
        echo "│   🔵 網路單位 (Network):"
        for n in "${NOTIFY_NET[@]}"; do echo "│      - ${n}"; done
    fi
    if [ ${#NOTIFY_DBA[@]} -gt 0 ]; then
        echo "│   🟠 DBA 單位:"
        for n in "${NOTIFY_DBA[@]}"; do echo "│      - ${n}"; done
    fi
    if [ ${#NOTIFY_AP[@]} -gt 0 ]; then
        echo "│   🟢 AP 團隊 (依 service 名找負責人):"
        for n in "${NOTIFY_AP[@]}"; do echo "│      - ${n}"; done
    fi
    if [ ${#NOTIFY_HW[@]} -gt 0 ]; then
        echo "│   ⚙️  硬體廠商 / 機房:"
        for n in "${NOTIFY_HW[@]}"; do echo "│      - ${n}"; done
    fi
    if [ ${#NOTIFY_SP[@]} -gt 0 ]; then
        echo "│   👷 SP 自行處理:"
        for n in "${NOTIFY_SP[@]}"; do echo "│      - ${n}"; done
    fi
}

# =============================================================================
# 統計與結論
# =============================================================================
summarize() {
    PASS=0; WARN=0; FAIL=0; NA=0
    for k in "${!METRIC[@]}"; do
        local s=${METRIC[$k]%%|*}
        case "$s" in
            PASS) PASS=$((PASS+1)) ;;
            WARN) WARN=$((WARN+1)) ;;
            FAIL) FAIL=$((FAIL+1)) ;;
            NA)   NA=$((NA+1)) ;;
        esac
    done
    OVERALL="PASS"
    [ "${WARN}" -gt 0 ] && OVERALL="WARN"
    [ "${FAIL}" -gt 0 ] && OVERALL="FAIL"
    END_TS=$(date +%s.%N)
    ELAPSED=$(awk -v s="${START_TS}" -v e="${END_TS}" 'BEGIN{printf "%.2f", e-s}')
}

# =============================================================================
# 輸出 — default (完整)
# =============================================================================
print_block() {
    local title="$1"; shift
    echo "├─ ${title} $(printf '─%.0s' $(seq 1 $((65 - ${#title}))))─┤"
    local ids=("$@")
    for id in "${ids[@]}"; do
        [ -z "${METRIC[$id]:-}" ] && continue
        IFS='|' read -r state value th dir label <<<"${METRIC[$id]}"
        printf "│   %s %-22s %-18s %s %s\n" \
            "$(state_emoji "${state}")" "${label}" "${value}" "${th}" "${dir}"
    done
}

output_default() {
    local host=$(hostname)
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    # ══════ 頂端：強烈狀態列 ══════
    local banner_bg banner_text
    case "${OVERALL}" in
        PASS) banner_bg="${PASS_BG}"; banner_text="  ${GRN_EMOJI}  主機狀況：正常  ${GRN_EMOJI}  " ;;
        WARN) banner_bg="${WARN_BG}"; banner_text="  ${YEL_EMOJI}  主機狀況：需注意  ${YEL_EMOJI}  " ;;
        FAIL) banner_bg="${FAIL_BG}"; banner_text="  ${RED_EMOJI}  主機狀況：異常  ${RED_EMOJI}  " ;;
    esac

    echo
    printf "${banner_bg}%s${RST}\n" "$(printf '%-70s' '')"
    printf "${banner_bg}%-70s${RST}\n" "${banner_text}"
    printf "${banner_bg}%-70s${RST}\n" "  ${host}   ${ts}   模式: ${MODE}   耗時: ${ELAPSED}s"
    printf "${banner_bg}%s${RST}\n" "$(printf '%-70s' '')"
    echo

    # ══════ 統計 ══════
    echo "┌─ 統計 ────────────────────────────────────────────────┐"
    printf "│   ${FAIL_BG} FAIL ${RST} %-3d  ${WARN_BG} WARN ${RST} %-3d  ${PASS_BG} PASS ${RST} %-3d  ⚪ N/A %-3d  (共 %d 項) │\n" \
        "${FAIL}" "${WARN}" "${PASS}" "${NA}" "$((FAIL + WARN + PASS + NA))"
    echo "└────────────────────────────────────────────────────────┘"
    echo

    # ══════ 問題清單（只列 FAIL / WARN，依嚴重度排序） ══════
    if [ "${FAIL}" -gt 0 ] || [ "${WARN}" -gt 0 ]; then
        echo "┌─ 問題項目（依嚴重度排序）─────────────────────────────┐"
        # 先印 FAIL
        local issues_printed=0
        for state_filter in FAIL WARN; do
            local bg="${WARN_BG}"
            [ "${state_filter}" = "FAIL" ] && bg="${FAIL_BG}"
            for k in "${!METRIC[@]}"; do
                IFS='|' read -r state value th dir label <<<"${METRIC[$k]}"
                [ "${state}" = "${state_filter}" ] || continue
                issues_printed=$((issues_printed+1))
                printf "│\n"
                printf "│  ${bg} %-4s ${RST}  %s  = %s\n" "${state}" "${label}" "${value}"
                printf "│         門檻: %s %s\n" "${th}" "${dir}"
                # 找 ACTIONS 中對應的建議
                for a in "${ACTIONS[@]}"; do
                    IFS='|' read -r sev cmd <<<"${a}"
                    if echo "${cmd}" | grep -qF "${label}"; then
                        printf "│         建議: %s\n" "${cmd}"
                        break
                    fi
                done
            done
        done
        echo "│"
        echo "└────────────────────────────────────────────────────────┘"
        echo

        # ══════ 建議指令（可 copy-paste 執行） ══════
        if [ ${#ACTIONS[@]} -gt 0 ]; then
            echo "┌─ 建議指令（可複製直接執行） ─────────────────────────┐"
            for a in "${ACTIONS[@]}"; do
                IFS='|' read -r sev cmd <<<"${a}"
                local ico
                case "${sev}" in FAIL) ico="🔴" ;; WARN) ico="🟡" ;; *) ico="  " ;; esac
                echo "│  ${ico} ${cmd}"
            done
            echo "└────────────────────────────────────────────────────────┘"
            echo
        fi

        # ══════ 通知建議（只在有問題時顯示） ══════
        local notify_count=0
        notify_count=$((${#NOTIFY_SEC[@]} + ${#NOTIFY_NET[@]} + ${#NOTIFY_DBA[@]} + ${#NOTIFY_AP[@]} + ${#NOTIFY_HW[@]}))
        if [ "${notify_count}" -gt 0 ]; then
            echo "┌─ 建議通知單位 ─────────────────────────────────────────┐"
            [ ${#NOTIFY_SEC[@]} -gt 0 ] && {
                echo "│  🟣 資安單位 (Security)"
                for n in "${NOTIFY_SEC[@]}"; do echo "│      → ${n}"; done
            }
            [ ${#NOTIFY_NET[@]} -gt 0 ] && {
                echo "│  🔵 網路單位 (Network)"
                for n in "${NOTIFY_NET[@]}"; do echo "│      → ${n}"; done
            }
            [ ${#NOTIFY_DBA[@]} -gt 0 ] && {
                echo "│  🟠 DBA 單位"
                for n in "${NOTIFY_DBA[@]}"; do echo "│      → ${n}"; done
            }
            [ ${#NOTIFY_AP[@]} -gt 0 ] && {
                echo "│  🟢 AP 團隊"
                for n in "${NOTIFY_AP[@]}"; do echo "│      → ${n}"; done
            }
            [ ${#NOTIFY_HW[@]} -gt 0 ] && {
                echo "│  ⚙️  硬體廠商 / 機房"
                for n in "${NOTIFY_HW[@]}"; do echo "│      → ${n}"; done
            }
            [ ${#NOTIFY_SP[@]} -gt 0 ] && {
                echo "│  👷 SP 自行處理"
                for n in "${NOTIFY_SP[@]}"; do echo "│      → ${n}"; done
            }
            echo "└────────────────────────────────────────────────────────┘"
            echo
        fi
    else
        echo "┌─ 結論 ─────────────────────────────────────────────────┐"
        echo "│                                                        │"
        echo "│   ✅ 所有 ${PASS} 項指標皆正常，主機健康                    │"
        echo "│                                                        │"
        echo "└────────────────────────────────────────────────────────┘"
        echo
    fi

    # ══════ 完整細項報告位置 ══════
    echo "完整 ${PASS}+${WARN}+${FAIL}+${NA} 項指標細項：已寫入 report 檔"
    echo "  → ${CASLOG_REPORT}/health_$(hostname)_$(date '+%Y%m%d_%H%M%S').txt"
    echo "  若要終端展開請執行：  mod_dashboard.sh --verbose"

    if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
        echo
        local uniq_tools
        uniq_tools=$(printf "%s\n" "${MISSING_TOOLS[@]}" | sort -u | tr '\n' ' ')
        echo "提示: 未裝套件 ${uniq_tools}— 部分指標 N/A"
        case "${DISTRO_FAMILY}" in
            rhel)   echo "  補裝: sudo dnf install -y sysstat ethtool lsof" ;;
            debian) echo "  補裝: sudo apt install -y sysstat ethtool lsof" ;;
        esac
    fi
}

# 完整細項版（--verbose 用，也寫 report）
output_verbose() {
    local overall_emoji=$(state_emoji "${OVERALL}")
    local host=$(hostname)
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "┌─ ${host} 健康儀表板（完整）$(printf '─%.0s' $(seq 1 14)) ${ts} ─┐"
    echo "│"
    echo "│   主機狀況: ${overall_emoji} $(case "${OVERALL}" in PASS) echo '正常';; WARN) echo '需注意';; FAIL) echo '異常';; esac)  (${FAIL} 危險, ${WARN} 注意, ${PASS} 正常)"
    echo "│"
    print_block "系統資源" cpu_load cpu_idle cpu_steal mem_avail swap disk_max inode_max io_await psi_mem psi_io
    print_block "Session / 連線" sess_est sess_cw sess_tw sess_syn sess_orph sess_ssh
    print_block "網路流量" net_rx net_tx net_err net_conntrack net_retrans
    print_block "檔案描述子" fd_sys fd_top fd_inotify fd_pid
    print_block "Infra 歷史 (24h)" infra_oom infra_mce infra_failed infra_taint
    print_block "合規 / 憑證" comp_ntp comp_cert comp_append comp_seal
    print_block "帳號鎖定 / 密碼到期" acc_locked acc_pw acc_uid0 acc_emptypw
    print_block "近 1h 運維軌跡" ops_login ops_etc ops_svc
    echo "└$(printf '─%.0s' $(seq 1 70))┘"
    echo
    echo "圖例: 🟢 正常  🟡 注意  🔴 危險  ⚪ 無資料"
    echo "      ↑ 越高越好  ↓ 越低越好  = 應等於特定值"
}

output_fast() {
    # 同 default 但少幾個不做取樣的指標
    output_default
}

output_full() {
    output_default
    # TODO: 加 ethtool -S 每網卡、lsof top
}

# =============================================================================
# 輸出 — --simple (給主管/稽核)
# =============================================================================
output_simple() {
    local host=$(hostname)
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "┌─ ${host} 健康報告（簡易版）──── ${ts} ─┐"
    echo "│"
    local status_label status_emoji
    case "${OVERALL}" in
        PASS) status_label="正常"; status_emoji="✅" ;;
        WARN) status_label="需注意"; status_emoji="⚠️" ;;
        FAIL) status_label="異常"; status_emoji="❌" ;;
    esac
    echo "│   系統狀況: ${status_emoji} ${status_label}"
    echo "│"

    simple_line() {
        local id="$1" label="$2" good_msg="$3" bad_msg="$4"
        [ -z "${METRIC[$id]:-}" ] && return
        IFS='|' read -r state value _ _ _ <<<"${METRIC[$id]}"
        case "${state}" in
            PASS) echo "│   ✅ ${label}    ${good_msg} (${value})" ;;
            WARN|FAIL) echo "│   $([ "${state}" = "FAIL" ] && echo "❌" || echo "⚠️") ${label}    ${bad_msg} (${value})" ;;
            NA) echo "│   ⚪ ${label}    無資料 (未裝套件)" ;;
        esac
    }

    simple_line "cpu_idle"     "CPU 使用率" "正常" "負載偏高"
    simple_line "mem_avail"    "記憶體"    "充足" "偏低"
    simple_line "disk_max"     "磁碟空間"  "充足" "接近滿"
    simple_line "sess_est"     "網路連線"  "正常" "異常"
    simple_line "infra_failed" "服務狀態"  "全部正常" "有服務異常"
    simple_line "comp_ntp"     "時間同步"  "正常" "未同步"
    simple_line "comp_seal"    "合規稽核"  "正常運作" "未啟用"

    echo "│"
    # 通知單位建議 (淺白版)
    local has_notify=0
    [ ${#NOTIFY_SEC[@]} -gt 0 ] || [ ${#NOTIFY_NET[@]} -gt 0 ] || \
    [ ${#NOTIFY_DBA[@]} -gt 0 ] || [ ${#NOTIFY_AP[@]}  -gt 0 ] || \
    [ ${#NOTIFY_HW[@]}  -gt 0 ] && has_notify=1
    if [ "${has_notify}" -eq 1 ]; then
        echo "│   建議通知:"
        [ ${#NOTIFY_SEC[@]} -gt 0 ] && echo "│     🟣 資安單位 (合規/稽核事件)"
        [ ${#NOTIFY_NET[@]} -gt 0 ] && echo "│     🔵 網路單位 (頻寬/延遲/TCP)"
        [ ${#NOTIFY_DBA[@]} -gt 0 ] && echo "│     🟠 DBA 單位"
        [ ${#NOTIFY_AP[@]}  -gt 0 ] && echo "│     🟢 AP 團隊 (應用服務)"
        [ ${#NOTIFY_HW[@]}  -gt 0 ] && echo "│     ⚙️  硬體廠商 / 機房"
        echo "│"
    fi
    if [ ${#NOTIFY_SP[@]} -gt 0 ]; then
        echo "│   SP 可自行處理:"
        local i=1
        for n in "${NOTIFY_SP[@]}"; do
            echo "│     ${i}. ${n}"
            i=$((i+1))
        done
        echo "│"
    fi
    echo "│   （技術細節請選 0 看完整儀表板）"
    echo "└$(printf '─%.0s' $(seq 1 60))┘"
}

# =============================================================================
# 輸出 — --json
# =============================================================================
output_json() {
    local host=$(hostname)
    local ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "{"
    echo "  \"host\": \"${host}\","
    echo "  \"timestamp\": \"${ts}\","
    echo "  \"mode\": \"${MODE}\","
    echo "  \"overall\": \"${OVERALL}\","
    echo "  \"counts\": {\"pass\": ${PASS}, \"warn\": ${WARN}, \"fail\": ${FAIL}, \"na\": ${NA}},"
    echo "  \"elapsed_sec\": ${ELAPSED},"
    echo "  \"metrics\": {"
    local first=1
    for k in "${!METRIC[@]}"; do
        IFS='|' read -r state value th dir label <<<"${METRIC[$k]}"
        [ "${first}" -eq 0 ] && echo ","
        first=0
        printf '    "%s": {"state": "%s", "value": "%s", "label": "%s"}' \
            "${k}" "${state}" "${value//\"/\\\"}" "${label//\"/\\\"}"
    done
    echo
    echo "  }"
    echo "}"
}

# =============================================================================
# CSV timeline (每次跑 append 一行)
# =============================================================================
append_timeline() {
    local csv="${CASLOG_REPORT}/health_timeline.csv"
    if [ ! -f "${csv}" ]; then
        echo "timestamp,host,overall,pass,warn,fail,na,load_1m,cpu_idle_pct,mem_avail_gb,disk_max_pct,conntrack_pct,close_wait,elapsed_sec" > "${csv}"
    fi
    local load_v idle_v mem_v disk_v ct_v cw_v
    load_v="${METRIC[cpu_load]##*|}"; load_v="${METRIC[cpu_load]%|*|*|*|*}"; load_v=$(echo "${METRIC[cpu_load]}" | cut -d'|' -f2)
    idle_v=$(echo "${METRIC[cpu_idle]:-}" | cut -d'|' -f2 | tr -d '%')
    mem_v=$(echo "${METRIC[mem_avail]:-}" | cut -d'|' -f2 | awk '{print $1}')
    disk_v=$(echo "${METRIC[disk_max]:-}" | cut -d'|' -f2 | awk -F'%' '{print $1}')
    ct_v=$(echo "${METRIC[net_conntrack]:-}" | cut -d'|' -f2 | tr -d '%' | awk '{print $1}')
    cw_v=$(echo "${METRIC[sess_cw]:-}" | cut -d'|' -f2)
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),${OVERALL},${PASS},${WARN},${FAIL},${NA},${load_v},${idle_v},${mem_v},${disk_v},${ct_v},${cw_v},${ELAPSED}" >> "${csv}"
}

# =============================================================================
# 落地報告
# =============================================================================
write_report() {
    local ts=$(date '+%Y%m%d_%H%M%S')
    local rpt="${CASLOG_REPORT}/health_$(hostname)_${ts}.txt"
    # 完整版寫入 report (含所有 PASS)
    {
        output_verbose
        echo
        echo "── 建議動作 ──"
        for a in "${ACTIONS[@]:-}"; do
            [ -z "${a}" ] && continue
            IFS='|' read -r sev cmd <<<"${a}"
            echo "  [${sev}] ${cmd}"
        done
        echo
        echo "── 通知建議 ──"
        [ ${#NOTIFY_SEC[@]} -gt 0 ] && { echo "[資安]"; for n in "${NOTIFY_SEC[@]}"; do echo "  - $n"; done; }
        [ ${#NOTIFY_NET[@]} -gt 0 ] && { echo "[網路]"; for n in "${NOTIFY_NET[@]}"; do echo "  - $n"; done; }
        [ ${#NOTIFY_DBA[@]} -gt 0 ] && { echo "[DBA]"; for n in "${NOTIFY_DBA[@]}"; do echo "  - $n"; done; }
        [ ${#NOTIFY_AP[@]}  -gt 0 ] && { echo "[AP 團隊]"; for n in "${NOTIFY_AP[@]}"; do echo "  - $n"; done; }
        [ ${#NOTIFY_HW[@]}  -gt 0 ] && { echo "[硬體]"; for n in "${NOTIFY_HW[@]}"; do echo "  - $n"; done; }
        [ ${#NOTIFY_SP[@]}  -gt 0 ] && { echo "[SP]"; for n in "${NOTIFY_SP[@]}"; do echo "  - $n"; done; }
    } > "${rpt}" 2>&1
    # 不再 echo report 位置（已在 output_default 提）
}

# =============================================================================
# main
# =============================================================================
collect_sys_resources
collect_session
collect_network
collect_fd
collect_infra
collect_compliance
collect_accounts
collect_ops_trail
summarize
build_notifications

case "${MODE}" in
    simple)  output_simple ;;
    json)    output_json ;;
    verbose) output_verbose ;;
    *)       output_default; write_report ;;
esac

append_timeline

audit_log "Dashboard (${MODE})" "OK" "pass=${PASS} warn=${WARN} fail=${FAIL} (${ELAPSED}s)"

[ "${MODE}" != "json" ] && [ -t 0 ] && { echo; pause; }
