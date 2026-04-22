#!/bin/bash
# mod_db.sh - DB 健康檢查 (支援 Oracle / MSSQL / MySQL / DB2 / PostgreSQL / MongoDB)
# 自動偵測這台主機上有哪些 DB（local server / client only / none），
# 讓使用者挑一種或跑所有偵測到的。
#
# 配置檔：${CASLOG_CONF}/db.conf（若不存在則僅用偵測 + 預設值）
# 密碼：一律不寫在 db.conf，改指向各 DB 原生認證檔
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

CONF_FILE="${CASLOG_CONF}/db.conf"
[ -f "${CONF_FILE}" ] && . "${CONF_FILE}"

# =============================================================================
# 偵測 (每個函式回傳 server / client / none)
# =============================================================================
_listen_port() { ss -tlnp 2>/dev/null | awk -v p=":$1 " '$4 ~ p'; }
_has_cmd()     { command -v "$1" >/dev/null 2>&1; }
_svc_active()  { systemctl is-active "$1" 2>/dev/null | grep -qx active; }

detect_oracle() {
    [ -n "$(_listen_port 1521)" ] && { echo server; return; }
    pgrep -f 'ora_pmon_' >/dev/null 2>&1 && { echo server; return; }
    [ -d /u01/app/oracle ] || [ -n "${ORACLE_HOME:-}" ] && { echo server; return; }
    _has_cmd sqlplus && { echo client; return; }
    echo none
}
detect_mssql() {
    [ -n "$(_listen_port 1433)" ] && { echo server; return; }
    _svc_active mssql-server && { echo server; return; }
    [ -d /opt/mssql ] && { echo server; return; }
    _has_cmd sqlcmd || _has_cmd tsql && { echo client; return; }
    echo none
}
detect_mysql() {
    [ -n "$(_listen_port 3306)" ] && { echo server; return; }
    _svc_active mysqld   && { echo server; return; }
    _svc_active mariadb  && { echo server; return; }
    [ -d /var/lib/mysql ] && { echo server; return; }
    _has_cmd mysql && { echo client; return; }
    echo none
}
detect_db2() {
    [ -n "$(_listen_port 50000)" ] && { echo server; return; }
    pgrep -f 'db2sysc' >/dev/null 2>&1 && { echo server; return; }
    [ -d /opt/ibm/db2 ] && { echo server; return; }
    _has_cmd db2 && { echo client; return; }
    echo none
}
detect_pg() {
    [ -n "$(_listen_port 5432)" ] && { echo server; return; }
    systemctl -a 2>/dev/null | awk '/postgresql/ && /running/' | grep -q . && { echo server; return; }
    [ -d /var/lib/pgsql ] || [ -d /var/lib/postgresql ] && { echo server; return; }
    _has_cmd psql && { echo client; return; }
    echo none
}
detect_mongo() {
    [ -n "$(_listen_port 27017)" ] && { echo server; return; }
    _svc_active mongod && { echo server; return; }
    [ -d /var/lib/mongo ] || [ -d /var/lib/mongodb ] && { echo server; return; }
    _has_cmd mongosh || _has_cmd mongo && { echo client; return; }
    echo none
}

# =============================================================================
# 健康檢查 (每函式吃 mode: server / client)
# 統一輸出格式；由 caller 收集 stdout 為 detail，以 return code 表示 PASS/WARN/FAIL
#   return 0 = PASS, 1 = WARN, 2 = FAIL
# =============================================================================
check_oracle() {
    local mode="$1"
    echo "── Oracle (${mode}) ──"
    [ "${ORACLE_ENABLE:-auto}" = "no" ] && { echo "SKIP: ORACLE_ENABLE=no"; return 0; }
    if ! _has_cmd sqlplus; then
        echo "WARN: sqlplus 未安裝，僅做 port 檢查"
        _listen_port 1521 || echo "port 1521 無 listener"
        return 1
    fi
    local tns="${ORACLE_TNS_ALIAS:-}"
    if [ -z "${tns}" ]; then
        echo "WARN: 未設定 ORACLE_TNS_ALIAS（conf/db.conf），跳過 SQL 測試"
        return 1
    fi
    local out
    out=$(echo -e "SET PAGES 0 FEED OFF\nSELECT 'OK' FROM DUAL;\nEXIT" \
          | sqlplus -S /@"${tns}" 2>&1)
    if echo "${out}" | grep -q '^OK'; then
        echo "PASS: 連線成功 (TNS=${tns})"
        echo "-- instance 資訊 --"
        echo -e "SET PAGES 100\nSELECT instance_name, host_name, version, status FROM v\$instance;\nEXIT" \
          | sqlplus -S /@"${tns}" 2>&1
        echo "-- tablespace 使用率 Top 5 --"
        echo -e "SET PAGES 100\nSELECT tablespace_name, ROUND(used_percent,1) pct FROM dba_tablespace_usage_metrics ORDER BY used_percent DESC FETCH FIRST 5 ROWS ONLY;\nEXIT" \
          | sqlplus -S /@"${tns}" 2>&1
        return 0
    else
        echo "FAIL: 無法連線"
        echo "${out}" | head -5
        return 2
    fi
}

check_mssql() {
    local mode="$1"
    echo "── MSSQL (${mode}) ──"
    [ "${MSSQL_ENABLE:-auto}" = "no" ] && { echo "SKIP"; return 0; }
    local tool=""
    if   _has_cmd sqlcmd; then tool="sqlcmd"
    elif _has_cmd tsql;   then tool="tsql"
    else echo "WARN: 無 sqlcmd / tsql"; return 1; fi

    local host="${MSSQL_HOST:-localhost}"
    local port="${MSSQL_PORT:-1433}"
    local user="${MSSQL_USER:-healthcheck}"
    local cred="${MSSQL_CRED_FILE:-}"

    if [ "${tool}" = "sqlcmd" ]; then
        if [ -z "${cred}" ] || [ ! -f "${cred}" ]; then
            echo "WARN: MSSQL_CRED_FILE 未設或不存在 (${cred}); 僅做 port 檢查"
            nc -zv -w 3 "${host}" "${port}" 2>&1
            return 1
        fi
        local pwd
        pwd=$(awk -F= '/^PASSWORD=/{print $2; exit}' "${cred}")
        local out
        out=$(sqlcmd -S "${host},${port}" -U "${user}" -P "${pwd}" -l 5 -Q "SELECT @@VERSION" 2>&1)
        if [ $? -eq 0 ]; then
            echo "PASS:"; echo "${out}" | head -10
            echo "-- 連線數 --"
            sqlcmd -S "${host},${port}" -U "${user}" -P "${pwd}" -l 5 -Q \
                "SELECT COUNT(*) AS sessions FROM sys.dm_exec_sessions;" 2>&1
            return 0
        else
            echo "FAIL:"; echo "${out}" | head -5
            return 2
        fi
    fi
    echo "WARN: tsql 僅能做連通測試"
    return 1
}

check_mysql() {
    local mode="$1"
    echo "── MySQL / MariaDB (${mode}) ──"
    [ "${MYSQL_ENABLE:-auto}" = "no" ] && { echo "SKIP"; return 0; }
    if ! _has_cmd mysql; then
        echo "WARN: mysql client 未安裝"
        _listen_port 3306 || echo "port 3306 無 listener"
        return 1
    fi
    local opts=""
    if [ -n "${MYSQL_CRED_FILE:-}" ] && [ -f "${MYSQL_CRED_FILE}" ]; then
        opts="--defaults-file=${MYSQL_CRED_FILE}"
    fi
    local ver
    ver=$(mysql ${opts} --connect-timeout=5 -Nse "SELECT VERSION();" 2>&1)
    if [ $? -ne 0 ]; then
        echo "FAIL: ${ver}"
        return 2
    fi
    echo "PASS: version=${ver}"

    echo "-- 連線數 / 上限 --"
    mysql ${opts} -e "
        SHOW STATUS LIKE 'Threads_connected';
        SHOW STATUS LIKE 'Max_used_connections';
        SHOW VARIABLES LIKE 'max_connections';
    " 2>/dev/null

    echo "-- Replication (若為 slave) --"
    local repl_out
    repl_out=$(mysql ${opts} -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if [ -n "${repl_out}" ]; then
        echo "${repl_out}" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_Error"
        local lag
        lag=$(echo "${repl_out}" | awk -F': ' '/Seconds_Behind_Master/{print $2}' | tr -d ' ')
        local warn="${MYSQL_REPLICA_LAG_WARN:-60}"
        local fail="${MYSQL_REPLICA_LAG_FAIL:-300}"
        if [ -n "${lag}" ] && [ "${lag}" != "NULL" ]; then
            [ "${lag}" -ge "${fail}" ] 2>/dev/null && { echo "FAIL: replication lag ${lag}s"; return 2; }
            [ "${lag}" -ge "${warn}" ] 2>/dev/null && { echo "WARN: replication lag ${lag}s"; return 1; }
        fi
    else
        echo "(非 slave 或無權限)"
    fi

    if [ "${mode}" = "server" ]; then
        echo "-- datadir 空間 --"
        local datadir
        datadir=$(mysql ${opts} -Nse "SHOW VARIABLES LIKE 'datadir'" 2>/dev/null | awk '{print $2}')
        [ -n "${datadir}" ] && df -h "${datadir}" 2>/dev/null
    fi
    return 0
}

check_db2() {
    local mode="$1"
    echo "── DB2 (${mode}) ──"
    [ "${DB2_ENABLE:-auto}" = "no" ] && { echo "SKIP"; return 0; }
    if ! _has_cmd db2; then
        echo "WARN: db2 client 未安裝"
        _listen_port 50000 || echo "port 50000 無 listener"
        return 1
    fi
    local inst="${DB2_INSTANCE:-}"
    local dbname="${DB2_DATABASE:-}"
    local cred="${DB2_CRED_FILE:-}"
    if [ -z "${inst}" ] || [ -z "${dbname}" ]; then
        echo "WARN: DB2_INSTANCE / DB2_DATABASE 未設"
        return 1
    fi
    # 切到 instance
    su - "${inst}" -c "db2 get dbm cfg | head -20; db2 list active databases" 2>&1 || true

    if [ -n "${cred}" ] && [ -f "${cred}" ]; then
        local user pwd
        user=$(awk -F= '/^USER=/{print $2; exit}' "${cred}")
        pwd=$(awk -F= '/^PASSWORD=/{print $2; exit}' "${cred}")
        local out
        out=$(su - "${inst}" -c "db2 connect to ${dbname} user ${user} using '${pwd}'" 2>&1)
        if echo "${out}" | grep -qi "connection successful"; then
            echo "PASS: ${out}" | head -3
            return 0
        else
            echo "FAIL:"; echo "${out}" | head -5
            return 2
        fi
    fi
    echo "WARN: 無 credential 檔，僅跑 daemon 檢查"
    return 1
}

check_pg() {
    local mode="$1"
    echo "── PostgreSQL (${mode}) ──"
    [ "${PG_ENABLE:-auto}" = "no" ] && { echo "SKIP"; return 0; }
    if ! _has_cmd psql; then
        echo "WARN: psql 未安裝"
        _listen_port 5432 || echo "port 5432 無 listener"
        return 1
    fi
    local host="${PG_HOST:-localhost}"
    local port="${PG_PORT:-5432}"
    local user="${PG_USER:-postgres}"
    local conn="host=${host} port=${port} user=${user} connect_timeout=5"

    local ver
    ver=$(psql "${conn}" -Atc "SELECT version();" 2>&1)
    if [ $? -ne 0 ]; then
        echo "FAIL: ${ver}"
        return 2
    fi
    echo "PASS: ${ver}"

    echo "-- 連線數 --"
    psql "${conn}" -c "SELECT count(*) AS active_conns FROM pg_stat_activity;" 2>/dev/null
    psql "${conn}" -c "SHOW max_connections;" 2>/dev/null

    echo "-- Replication (若為 standby) --"
    psql "${conn}" -Atc "SELECT CASE WHEN pg_is_in_recovery() THEN EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int ELSE -1 END;" 2>/dev/null \
      | awk -v w="${PG_REPLICA_LAG_WARN:-60}" -v f="${PG_REPLICA_LAG_FAIL:-300}" '
          $1==-1 {print "(非 standby)"; next}
          $1>=f  {print "FAIL: lag " $1 "s"; rc=2; next}
          $1>=w  {print "WARN: lag " $1 "s"; if(rc<1)rc=1; next}
          {print "lag " $1 "s"} END{exit rc+0}'
    local rc=$?

    if [ "${mode}" = "server" ]; then
        echo "-- data dir 空間 --"
        local pgdata
        pgdata=$(psql "${conn}" -Atc "SHOW data_directory;" 2>/dev/null)
        [ -n "${pgdata}" ] && df -h "${pgdata}" 2>/dev/null
    fi
    return ${rc:-0}
}

check_mongo() {
    local mode="$1"
    echo "── MongoDB (${mode}) ──"
    [ "${MONGO_ENABLE:-auto}" = "no" ] && { echo "SKIP"; return 0; }
    local tool=""
    if   _has_cmd mongosh; then tool="mongosh"
    elif _has_cmd mongo;   then tool="mongo"
    else echo "WARN: 無 mongosh / mongo client"; _listen_port 27017 || echo "port 27017 無 listener"; return 1; fi

    local uri=""
    if [ -n "${MONGO_URI_FILE:-}" ] && [ -f "${MONGO_URI_FILE}" ]; then
        uri=$(head -1 "${MONGO_URI_FILE}")
    fi
    if [ -z "${uri}" ]; then
        uri="mongodb://localhost:27017"
        echo "(未設 MONGO_URI_FILE，用預設 ${uri} 無認證)"
    fi
    local out
    out=$(${tool} --quiet --eval 'JSON.stringify(db.hello())' "${uri}" 2>&1)
    if [ $? -eq 0 ] && echo "${out}" | grep -q 'isWritablePrimary\|ismaster'; then
        echo "PASS:"; echo "${out}" | head -3
        echo "-- serverStatus 摘要 --"
        ${tool} --quiet --eval 'var s=db.serverStatus(); print("connections current=" + s.connections.current + " available=" + s.connections.available); print("uptime=" + s.uptime + "s"); print("version=" + s.version)' "${uri}" 2>&1
        echo "-- replication --"
        ${tool} --quiet --eval 'try{var r=rs.status(); print("set=" + r.set + " myState=" + r.myState)}catch(e){print("(非 replica set)")}' "${uri}" 2>&1
        return 0
    else
        echo "FAIL:"; echo "${out}" | head -5
        return 2
    fi
}

# =============================================================================
# 一鍵檢查（mod_troubleshoot 也會呼叫）
# 輸出結構:  <dbname> <result> <note>
# =============================================================================
db_auto_check() {
    local failures=0 warns=0 checks=0
    for db in oracle mssql mysql db2 pg mongo; do
        local m; m=$(detect_${db})
        [ "${m}" = "none" ] && continue
        checks=$((checks+1))
        local out rc
        out=$(check_${db} "${m}" 2>&1); rc=$?
        local label="PASS"
        case "${rc}" in
            1) label="WARN"; warns=$((warns+1)) ;;
            2) label="FAIL"; failures=$((failures+1)) ;;
        esac
        # 把第一行 "── X (mode) ──" 與第二行（PASS/FAIL/WARN 訊息）濃縮成一行
        local note
        note=$(echo "${out}" | awk 'NR==2{print; exit}')
        printf "%-8s %-5s %s\n" "${db}" "${label}" "${note}"
    done
    # 用 return code 表達 overall
    if [ "${checks}" -eq 0 ]; then return 3; fi  # none detected
    [ "${failures}" -gt 0 ] && return 2
    [ "${warns}" -gt 0 ] && return 1
    return 0
}
export -f detect_oracle detect_mssql detect_mysql detect_db2 detect_pg detect_mongo \
          check_oracle check_mssql check_mysql check_db2 check_pg check_mongo \
          db_auto_check _listen_port _has_cmd _svc_active

# =============================================================================
# 互動選單
# =============================================================================
emoji() {
    case "$1" in
        server) echo "[${GRN}✓${RST} local: listener/server 偵測到]" ;;
        client) echo "[△ 僅 client 工具 (可用於連遠端)]" ;;
        none)   echo "[✗ 未偵測到]" ;;
    esac
}

show_menu() {
    clear
    echo "======================================================"
    echo " DB 健康檢查    主機: $(hostname)    Conf: ${CONF_FILE}"
    [ -f "${CONF_FILE}" ] || echo -e " ${YEL}(db.conf 不存在，僅以偵測 + 預設值執行)${RST}"
    echo "======================================================"
    echo " 偵測結果："
    DB_ORACLE=$(detect_oracle); DB_MSSQL=$(detect_mssql); DB_MYSQL=$(detect_mysql)
    DB_DB2=$(detect_db2);       DB_PG=$(detect_pg);       DB_MONGO=$(detect_mongo)
    printf "   1) Oracle         %s\n" "$(emoji ${DB_ORACLE})"
    printf "   2) MSSQL          %s\n" "$(emoji ${DB_MSSQL})"
    printf "   3) MySQL/MariaDB  %s\n" "$(emoji ${DB_MYSQL})"
    printf "   4) DB2            %s\n" "$(emoji ${DB_DB2})"
    printf "   5) PostgreSQL     %s\n" "$(emoji ${DB_PG})"
    printf "   6) MongoDB        %s\n" "$(emoji ${DB_MONGO})"
    echo "------------------------------------------------------"
    echo "   A) 自動跑所有偵測到的 DB"
    echo "   b) 返回主選單"
    echo "======================================================"
}

run_one() {
    local name="$1" mode="$2"
    if [ "${mode}" = "none" ]; then
        echo "${name} 未偵測到，要強制跑嗎？會以 client 模式連 conf 內設定的 host。"
        read -r -p "Y/N > " y
        [[ "${y}" =~ ^[Yy] ]] || return 0
        mode="client"
    fi
    run_cmd "DB check: ${name} (${mode})" check_${name} "${mode}"
}

# 只有直接執行時才跑互動選單；被其他 mod source 時只匯入函式不進 loop
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    while true; do
        show_menu
        read -r -p "選擇 > " c || exit 0
        case "$c" in
            1) run_one oracle "${DB_ORACLE}" ;;
            2) run_one mssql  "${DB_MSSQL}"  ;;
            3) run_one mysql  "${DB_MYSQL}"  ;;
            4) run_one db2    "${DB_DB2}"    ;;
            5) run_one pg     "${DB_PG}"     ;;
            6) run_one mongo  "${DB_MONGO}"  ;;
            a|A)
                echo "── 自動跑所有偵測到的 DB ──"
                db_auto_check | tee -a "${LOG_FILE:-/dev/null}"
                ;;
            b|B) exit 0 ;;
            *)   echo "無效選項" ;;
        esac
        pause
    done
fi
