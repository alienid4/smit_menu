#!/bin/bash
# mod_cert.sh - 憑證掃描 (lite 版：去除 Java AP 相關)
# 保留：Java keystore (jks/p12/cacerts) + PEM 憑證到期掃描
# 移除 (vs full 版 mod_java.sh)：java -version、JAVA_HOME、Java 程序、GC 設定、重啟服務
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

KEYSTORE_DEFAULT="${JAVA_HOME:-/usr/lib/jvm/default}/lib/security/cacerts"

# 掃單一 keystore — 列出每個 alias 的剩餘天數
check_keystore() {
    local ks="$1"; local pw="${2:-changeit}"
    [ -f "${ks}" ] || { echo "Keystore not found: ${ks}"; return 1; }
    if ! command -v keytool >/dev/null 2>&1; then
        echo "keytool 未安裝 (需 openjdk)"
        return 1
    fi
    echo "Keystore: ${ks}"
    keytool -list -v -keystore "${ks}" -storepass "${pw}" 2>/dev/null \
    | awk '
        /Alias name/ { alias=$3 }
        /Valid from/ {
            sub(/.*until: /,""); exp=$0
            cmd="date -d \""exp"\" +%s 2>/dev/null"
            if ((cmd|getline ts)>0) {
                days=int((ts-systime())/86400)
                status="OK"
                if      (days<0)  status="EXPIRED"
                else if (days<30) status="WARN"
                printf "  %-30s  %5d days  %s\n", alias, days, status
            }
            close(cmd)
        }'
}

# 掃系統所有 keystore
scan_all_keystores() {
    echo "-- 系統預設 keystore --"
    check_keystore "${KEYSTORE_DEFAULT}" changeit
    echo
    echo "-- /etc /opt /usr 下所有 .jks / .p12 / .keystore --"
    find /etc /opt /usr -type f \( -name "*.jks" -o -name "*.p12" -o -name "*.keystore" \) 2>/dev/null \
      | while read -r f; do
          echo
          echo "== ${f} =="
          check_keystore "${f}" changeit
      done
}

# 單一 PEM 憑證
check_pem() {
    local f="$1"
    [ -f "${f}" ] || { echo "PEM not found: ${f}"; return 1; }
    if ! command -v openssl >/dev/null 2>&1; then
        echo "openssl 未安裝"; return 1
    fi
    local exp ts days
    exp=$(openssl x509 -in "${f}" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -z "${exp}" ] && { echo "非有效 PEM: ${f}"; return 1; }
    ts=$(date -d "${exp}" +%s)
    days=$(( (ts - $(date +%s)) / 86400 ))
    printf "  %-50s  %5d days  expires=%s\n" "${f}" "${days}" "${exp}"
}

# 掃常見位置的 PEM
scan_all_pem() {
    echo "-- /etc/pki /etc/ssl /etc/letsencrypt 下所有 *.pem / *.crt --"
    find /etc/pki /etc/ssl /etc/letsencrypt /opt -type f \( -name "*.pem" -o -name "*.crt" \) 2>/dev/null \
      | while read -r f; do
          check_pem "${f}" 2>/dev/null
      done
}

# 30 天到期摘要 (日常查詢)
expiry_summary() {
    echo "── 30 天內到期或已過期的憑證 ──"
    local found=0
    if command -v keytool >/dev/null 2>&1 && [ -f "${KEYSTORE_DEFAULT}" ]; then
        local tmpf="/tmp/cert_summary_k.$$"
        keytool -list -v -keystore "${KEYSTORE_DEFAULT}" -storepass changeit 2>/dev/null \
        | awk '
            /Alias name/ { alias=$3 }
            /Valid from/ {
                sub(/.*until: /,""); exp=$0
                cmd="date -d \""exp"\" +%s 2>/dev/null"
                if ((cmd|getline ts)>0) {
                    days=int((ts-systime())/86400)
                    if (days<30) {
                        printf "  [keystore]  %-30s  %5d days  %s\n", alias, days, (days<0?"EXPIRED":"WARN")
                    }
                }
                close(cmd)
            }' > "${tmpf}"
        if [ -s "${tmpf}" ]; then
            cat "${tmpf}"
            found=1
        fi
        rm -f "${tmpf}"
    fi
    for f in $(find /etc/pki /etc/ssl /etc/letsencrypt -type f \( -name "*.pem" -o -name "*.crt" \) 2>/dev/null); do
        local exp ts days
        exp=$(openssl x509 -in "${f}" -noout -enddate 2>/dev/null | cut -d= -f2)
        [ -z "${exp}" ] && continue
        ts=$(date -d "${exp}" +%s 2>/dev/null) || continue
        days=$(( (ts - $(date +%s)) / 86400 ))
        if [ "${days}" -lt 30 ]; then
            printf "  [PEM]       %-40s  %5d days  %s\n" "${f}" "${days}" "$([ "${days}" -lt 0 ] && echo EXPIRED || echo WARN)"
            found=1
        fi
    done
    [ "${found}" -eq 0 ] && echo "  (無)"
}

menu() {
    clear
    echo "======================================================"
    echo " 憑證掃描 (Certificate Scanner)"
    echo "======================================================"
    echo "  1) 掃描系統預設 keystore (cacerts)"
    echo "  2) 掃描指定 keystore (自訂路徑)"
    echo "  3) 掃描所有系統 keystore (批次)"
    echo "  4) 掃描單一 PEM / CRT 憑證"
    echo "  5) 掃描所有 PEM 憑證 (/etc/pki /etc/ssl /etc/letsencrypt)"
    echo "  6) 30 天內到期 / 已過期 憑證摘要 (日常查)"
    echo "  b) 返回主選單"
    echo "======================================================"
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "Default keystore"   check_keystore "${KEYSTORE_DEFAULT}" changeit ;;
        2) read -r -p "keystore 路徑 [${KEYSTORE_DEFAULT}] > " ks
           ks="${ks:-$KEYSTORE_DEFAULT}"
           read -r -s -p "keystore 密碼 [changeit] > " pw; echo
           pw="${pw:-changeit}"
           run_cmd "Keystore ${ks}"      check_keystore "${ks}" "${pw}" ;;
        3) run_cmd "All keystore scan"   scan_all_keystores ;;
        4) read -r -p "PEM / CRT 路徑 > " f
           run_cmd "PEM ${f}"            check_pem "${f}" ;;
        5) run_cmd "All PEM scan"        scan_all_pem ;;
        6) run_cmd "Expiry summary"      expiry_summary ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
