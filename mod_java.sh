#!/bin/bash
# mod_java.sh - Java & 憑證 (含多 keystore 掃描 / GC 設定 / 服務重啟)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

KEYSTORE_DEFAULT="${JAVA_HOME:-/usr/lib/jvm/default}/lib/security/cacerts"
SERVICE_DEFAULT="tomcat"

check_keystore() {
    local ks="$1"; local pw="${2:-changeit}"
    [ -f "${ks}" ] || { echo "Keystore not found: ${ks}"; return 1; }
    echo "Keystore: ${ks}"
    keytool -list -v -keystore "${ks}" -storepass "${pw}" 2>/dev/null \
    | awk '
        /Alias name/    {alias=$3}
        /Valid from/    {
            sub(/.*until: /,""); exp=$0
            cmd="date -d \""exp"\" +%s"; cmd | getline exp_ts; close(cmd)
            now=systime(); days=int((exp_ts-now)/86400)
            status="OK"
            if (days<0)      status="EXPIRED"
            else if (days<30) status="WARN"
            printf "  %-30s  %5d days  %s\n", alias, days, status
        }'
}

scan_all_keystores() {
    echo "-- 系統預設 keystore --"
    check_keystore "${KEYSTORE_DEFAULT}" changeit
    echo
    echo "-- 掃描 /opt 與 /etc 下所有 .jks/.p12/.keystore --"
    find /opt /etc /usr -type f \( -name "*.jks" -o -name "*.p12" -o -name "*.keystore" \) 2>/dev/null \
      | while read -r f; do
          echo
          echo "== ${f} =="
          check_keystore "${f}" changeit
      done
}

check_pem() {
    local f="$1"
    [ -f "${f}" ] || { echo "not found: ${f}"; return 1; }
    local exp ts now days
    exp=$(openssl x509 -in "${f}" -noout -enddate | cut -d= -f2)
    ts=$(date -d "${exp}" +%s)
    now=$(date +%s)
    days=$(( (ts - now) / 86400 ))
    printf "  %-40s  %5d days  expires=%s\n" "${f}" "${days}" "${exp}"
}

gc_flags() {
    command -v jinfo >/dev/null 2>&1 || { echo "jinfo 不可用，需要 JDK (不是 JRE)"; return 1; }
    local pid
    for pid in $(pgrep -f 'java'); do
        local cmd
        cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
        echo "── PID=${pid}  ${cmd} ──"
        jinfo -flags "${pid}" 2>/dev/null | head -20
        echo
    done
}

menu() {
    clear
    echo "======================================================"
    echo " Java & 憑證 (Java & Cert)     Impact"
    echo "======================================================"
    echo "  1) Java 版本 (java -version)"
    echo "  2) JAVA_HOME / which java"
    echo "  3) 掃描系統預設 keystore"
    echo "  4) 掃描指定 keystore"
    echo "  5) 掃描所有系統 keystore (批次)"
    echo "  6) 掃描 PEM 憑證 (指定檔)"
    echo "  7) Java 程序列表"
    echo "  8) GC 設定 (jinfo)"
    echo -e "  9) ${RED}[高風險] 重啟 Java 服務 (e.g. tomcat)${RST}"
    echo "  b) 返回主選單"
    echo "======================================================"
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "java -version" bash -c "java -version 2>&1" ;;
        2) run_cmd "JAVA_HOME"     bash -c "echo JAVA_HOME=\$JAVA_HOME; which java" ;;
        3) run_cmd "Default keystore" check_keystore "${KEYSTORE_DEFAULT}" changeit ;;
        4) read -r -p "keystore [${KEYSTORE_DEFAULT}] > " ks
           ks="${ks:-$KEYSTORE_DEFAULT}"
           read -r -s -p "keystore 密碼 [changeit] > " pw; echo
           pw="${pw:-changeit}"
           run_cmd "Keystore scan ${ks}" check_keystore "${ks}" "${pw}" ;;
        5) run_cmd "All keystore scan" scan_all_keystores ;;
        6) read -r -p "PEM 路徑 > " f
           run_cmd "PEM cert" check_pem "${f}" ;;
        7) run_cmd "Java procs" bash -c "ps -eo pid,user,%cpu,%mem,args | grep -i [j]ava" ;;
        8) run_cmd "GC flags" gc_flags ;;
        9) read -r -p "service name [${SERVICE_DEFAULT}] > " sv
           sv="${sv:-$SERVICE_DEFAULT}"
           run_impact_cmd "Restart ${sv}" systemctl restart "${sv}" ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
