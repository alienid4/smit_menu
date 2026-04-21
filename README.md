# smit_menu — 金融業 Linux 維運工具 v1.1

[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![shell](https://img.shields.io/badge/shell-bash%204%2B-green.svg)]()
[![distro](https://img.shields.io/badge/OS-RHEL%20%7C%20Rocky%20%7C%20Debian%20%7C%20Ubuntu-orange.svg)]()

一套給**金融業資訊處 Linux SP** 使用的 bash 維運選單工具。單一主選單派遣 17 個模組，
涵蓋日常巡檢、客訴急救、DB 健康檢查、工具盤點、baseline 管理、**T0 合規稽核（無 SIEM 也能過關）**。

## 設計理念

- **合規優先**：每個動作寫審計 log（誰、何時、執行什麼、結果）
- **三色風險分級**：紅=高風險、黃=變更、白=查詢
- **分層確認**：查詢不問、變更按 Enter、高風險輸入 `CONFIRM`
- **交易期間友善**：秒級 triage (主選單 15) 與開盤前 baseline diff (主選單 16)
- **跨 distro**：自動偵測 RHEL/Rocky/CentOS 與 Ubuntu/Debian

## 快速開始

```bash
# 1. Clone
git clone https://github.com/alienid4/smit_menu.git
cd smit_menu

# 2. 安裝（需 root）
sudo bash install.sh

# 3. 啟動
bash /TWLog/AI/scripts/LinuxMenu.sh
```

自訂安裝根目錄：
```bash
BASE=/opt/smit sudo bash install.sh
```

`install.sh` 會建立：
```
${BASE}/
├── scripts/     所有 *.sh
├── logs/        審計 log (LinuxMenu_main_YYYYMMDD.log)
├── reports/     巡檢 / 客訴報告
│   └── baselines/
└── conf/        db.conf, app.conf, baseline.conf (chmod 600)
```

## 主選單 16 項

| 分類 | 選項 | 名稱 | 主要功能 |
|---|---|---|---|
| **查詢** | 1 | 系統資訊 | uptime / kernel / NTP / 硬體 (BIOS) / **加密熵值** / 開機關機紀錄 |
| | 2 | 網路診斷 | ip / route / port / ping / **bonding** / DNS / ARP / **防火牆 CRUD** |
| | 3 | 檔案 & 目錄 | 大檔搜尋 / **SUID-SGID 稽核** / **world-writable** / 敏感檔 sha256 |
| | 4 | 程序監控 | Top CPU / Top MEM / Zombie / **FD 耗用排名** / **可疑進程** / pstree |
| | 5 | 帳號 & 權限 | last / lastb / **UID=0 全清單** / **空密碼** / sudo / authorized_keys 稽核 |
| | 6 | 日誌 & 稽核 | syslog / authlog / dmesg / auditd / **root 登入統計** / sudo 錯誤 |
| | 7 | 套件 / Repo | Repo / **CVE 安全更新** / 套件歷史 / GPG key |
| | 8 | 儲存 & 備份 | 磁碟 / inode / LVM / **snapshot** / **fstab 驗證** / iostat / NFS |
| **變更** | 5 | *(同上)* | 解鎖帳號、重設失敗計數（黃） |
| | 9 | Java & 憑證 | **批次掃所有 keystore** / GC 設定 / 重啟服務（紅） |
| | 10 | 安全稽核 | sshd_config / SELinux / **fail2ban** / **auditctl** / **PAM** / 重啟 sshd（紅） |
| **報表/急救** | **11** | 快速自辯 (Troubleshoot) | **9 面向 + Appendix A**，非尖峰用，七段式報告 |
| | **15** | **快速 Triage (<1 秒)** | **交易期間 / freeze 時專用**，秒級檢查 |
| | 12 | 每日巡檢報表 | 18 區塊（含 CVE / 憑證到期 / 帳號變動） |
| | **13** | **DB 健康檢查** | Oracle / MSSQL / MySQL / DB2 / PostgreSQL / MongoDB **自動偵測** |
| **輔助** | 14 | 工具盤點 | 列缺哪些套件、匯 CSV 給變更申請 |
| | **16** | **Baseline 管理** | 開盤前快照 + diff「今天 vs 平日」 |
| | **17** | **審計封存與驗證** | **T0 合規**：append-only + HMAC，無 SIEM 也過稽核 |

## 客訴急救

```bash
ssh -t root@<主機> 'bash /TWLog/AI/scripts/LinuxMenu.sh'

# 非尖峰 / 客訴「慢」      →  選 11  (完整 9 面向，~30-60 秒)
# 交易期間 / freeze        →  選 15  (秒級，<1 秒，不加重負擔)
# 對比平日差異             →  選 16 → 4  (diff 今天 vs 最近 baseline)
```

### 選項 11 涵蓋面向

| # | 面向 | 檢查 |
|---|---|---|
| 1 | 效能 | Load / CPU idle / Swap / Mem |
| 2 | 頻寬 | NIC err/drop、TCP retrans、Ping、**conntrack**、**TIME_WAIT 佔比**、**SYN drops** |
| 3 | AP | 指定 port 是否有 listener、程序資源、近 1h journal |
| 4 | Session | EST / CLOSE_WAIT / TIME_WAIT、Top 10 來源 IP |
| 5 | Storage | df / inode / /tmp |
| 6 | 時間 / 憑證 | NTP 同步、憑證 30 天內到期 |
| 7 | DB | 呼叫 mod_db auto-check，6 種 DB |
| 8 | Infra 穩定 | OOM kill / MCE / systemd failed / kernel tainted |
| 9 | 運維軌跡 | 近 1h 誰登入 / 改 /etc / restart service（**主管問「剛動過什麼」的答案**） |
| +A | Appendix A | AP log ERROR / Java GC / jstack（需 `conf/app.conf`） |

每塊報告**七段式**：檢查範圍 / 指令 / 正常基準 / 實測值 / 判定依據 / 對客訴影響 / 建議動作。

## 交易期間 Baseline 工作流（選項 16）

```bash
# 每天開盤前 07:30 自動產生 baseline
sudo tee /etc/cron.d/linuxmenu-baseline >/dev/null <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

30 7 * * 1-5 root  bash /TWLog/AI/scripts/mod_baseline.sh --snapshot >> /TWLog/AI/logs/baseline.log 2>&1
EOF
```

交易中出事，秒級 diff：

```
-  Load(1/5/15m) = 0.30 / 0.25 / 0.20      [PASS]   ← 昨天
+  Load(1/5/15m) = 1.49 / 1.40 / 1.35      [PASS]   ← 今天
-  NIC 錯誤網卡 = 0 張  (err=0 drop=0)    [WARN]   ← 昨天
+  NIC 錯誤網卡 = 1 張  (err=0 drop=66)   [WARN]   ← 今天
```

**30 秒看出「今天什麼變了」**，比從頭分析快 10 倍。

## 設定檔（`${BASE}/conf/`）

| 檔 | 用途 | 必要 |
|---|---|---|
| `db.conf` | DB 連線 (6 種 DB 分段) | 選配 — 沒設就只做偵測 |
| `app.conf` | AP log 路徑、Java 程序名 (Appendix A 用) | 選配 |
| `baseline.conf` | Baseline cron 參數 | 選配 |

**密碼一律不寫 `conf/*.conf`**，指向各 DB 原生認證檔：

| DB | 認證檔 |
|---|---|
| Oracle | Wallet / TNS alias `sqlplus /@APPDB` |
| MySQL / MariaDB | `~/.my.cnf` `[client]` section |
| PostgreSQL | `~/.pgpass` |
| MSSQL | 自訂檔 (USER= / PASSWORD=) |
| DB2 | 自訂檔 |
| MongoDB | `/root/.mongo_uri` 單行連線字串 |

## 審計 log

所有動作寫入 `${BASE}/logs/LinuxMenu_main_YYYYMMDD.log`：

```
2026-04-20 14:32:05 | Unlock svc_ap02          | OK      | passwd -u svc_ap02
2026-04-20 14:35:12 | Restart tomcat           | CANCEL  | user declined
2026-04-20 14:40:08 | Troubleshoot report      | OK      | PASS=6 WARN=2 FAIL=1 ...
2026-04-20 14:41:23 | Triage tomcat:8080       | OK      | Pass=6 Warn=0 Fail=0 (0.17s)
```

可 `grep FAIL` / `grep CANCEL` / 送 SIEM。

## 合規稽核（T0 — 無 SIEM 也能過關）

金管會 / FISC 稽核要的是**三要素**（而非商業 SIEM 本身）：

1. ✅ **可追溯** — `audit_log` 已提供（人、時間、項目、結果、指令）
2. ✅ **不可竄改** — 透過 **append-only + HMAC 封存** 達成
3. ⚠️ **保留期足夠** — 由 logrotate / 中央備份配合

### 選項 17 — 審計封存與驗證

啟動選單 → 17，或 CLI：
```bash
bash ${BASE}/scripts/mod_audit_seal.sh --verify-all   # 驗證所有 log 未被動過
bash ${BASE}/scripts/mod_audit_seal.sh --verify LinuxMenu_main_20260420.log
bash ${BASE}/scripts/mod_audit_seal.sh --daily        # 手動 seal (平時 cron 自動跑)
bash ${BASE}/scripts/mod_audit_seal.sh --status       # 看 key / manifest / cron 狀態
```

### 三層機制

| 機制 | 實作 | 效果 |
|---|---|---|
| **append-only** | `chattr +a` (主檔啟動時自動) | 連 root 都不能 `rm` / `>` 覆寫 log (要先 `-a`，該動作會被偵測到) |
| **HMAC-SHA256 封存** | 每日 23:59 cron 自動 | sha256 + HMAC 存入 manifest；任何竄改都會讓 verify 失敗 |
| **離線 key 備份** | install 時產生 `${BASE}/conf/hmac.key` | **把 key 備份到離線安全處**，沒 key 無法偽造簽章 |

### 驗證流程（給稽核看）

```bash
# 稽核員想確認 2026-04-20 的 log 從當天到現在沒被改：
bash mod_audit_seal.sh --verify LinuxMenu_main_20260420.log

── Verify: LinuxMenu_main_20260420.log ──
 manifest sha256 : 7a3b...                  ← 當天 23:59 封存的
 目前    sha256  : 7a3b...                  ← 現在重算的
 manifest hmac   : a91f...
 目前    hmac    : a91f...
 結果 : PASS — log 未被竄改               ✓
```

若任何人動過，會 FAIL：
```
 結果 : FAIL — log 已被動過！
```

### 升級路線（預算允許時）

| 階層 | 成本 | 技術 | 適用組織 |
|---|---|---|---|
| **T0 (本版本內建)** | $0 | chattr +a / HMAC / cron | 小型金融、單機應用 |
| T1 中央化 | 1 VM | rsyslog central | 中型機構 |
| T2 自建 SIEM | 3-5 VM | Wazuh / Graylog / Elastic | 大型機構 |
| T3 商業 SIEM | 授權費 | Splunk / ArcSight | 金控集團 |

T0 先過基本稽核，之後有預算再一步步升級，不需重寫本工具。

## 三色 wrapper

| Wrapper | 標籤 | 確認 | 場景 |
|---|---|---|---|
| `run_cmd` | `[QUERY]` 白 | 無 | ps/df/ss/cat |
| `run_change_cmd` | `[CHANGE]` 黃 | 按 Enter | passwd -u, yum makecache |
| `run_impact_cmd` | `[IMPACT]` 紅 | 輸入 `CONFIRM` | systemctl restart, kill -9 |

## 跨 distro

| 能力 | RHEL 系 | Debian 系 |
|---|---|---|
| 套件管理 | `yum` / `dnf` | `apt` |
| 防火牆 | `firewall-cmd` | `ufw` |
| 認證 log | `/var/log/secure` | `/var/log/auth.log` |
| 系統 log | `/var/log/messages` | `/var/log/syslog` |
| SSH 服務 | `sshd` | `ssh` |
| 失敗計數 | `faillock` | `pam_tally2` |
| MAC | `sestatus` (SELinux) | `aa-status` (AppArmor) |

## 環境變數

| 變數 | 預設 |
|---|---|
| `TWLOG_BASE` | `/TWLog/AI` |
| `TWLOG_SCRIPT` | `${TWLOG_BASE}/scripts` |
| `TWLOG_LOG` | `${TWLOG_BASE}/logs` |
| `TWLOG_REPORT` | `${TWLOG_BASE}/reports` |
| `TWLOG_CONF` | `${TWLOG_BASE}/conf` |

## 前置套件

**零依賴可跑**（只用 bash / ss / ip / systemctl / journalctl 等 OS 內建）。

建議裝（讓 troubleshoot 功能完整）：

```bash
# RHEL / Rocky / CentOS
sudo dnf install -y sysstat lsof ethtool nmap-ncat chrony iputils \
                    psmisc fail2ban audit dmidecode java-17-openjdk

# Ubuntu / Debian
sudo apt-get install -y sysstat lsof ethtool netcat-openbsd chrony iputils-arping \
                        psmisc fail2ban auditd dmidecode openjdk-17-jre
```

或進主選單 **14 → 2** 讓工具告訴你這台缺哪些。

## 適用範圍

- ✅ 一般 AP / DB / Jump Host / MIS / 監控主機 (RHEL 7-9, Ubuntu 20.04+)
- ⚠️ DMZ 資安敏感機（只裝 core）、高頻交易主機（用選項 15 而非 11）
- ❌ 容器內 sidecar、K8s 業務 Pod、AIX/Solaris/Mainframe、Alpine/BusyBox

## 已知限制

1. Oracle wallet / TNS alias 需預先設好
2. Java GC 分析（Appendix A A2/A3）需要 **JDK** 不是 JRE
3. SIEM / syslog forwarding 未內建
4. 報告簽章 / HMAC 未實作（可外層 rsyslog 接）

## 版本

| 版本 | 日期 | 內容 |
|---|---|---|
| v1.0 | 2026-04-20 | 首版；16 模組；troubleshoot 9 面向 + DB 6 種 + triage + baseline + tooling |
| **v1.1** | **2026-04-20** | **新增選項 17 審計封存與驗證**（T0 合規：append-only + HMAC + 每日 cron seal） |

## License

[MIT](./LICENSE)
