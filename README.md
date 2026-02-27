# TetraBlocker

TetraBlocker 是一个面向 **非 Kubernetes / 非 Cilium Network Policy** 场景的主机侧网络访问控制原型（可产品化），基于 **Tetragon Enterprise** 的 eBPF 能力，在 Linux 主机上实现：

- **按域名（Domain/FQDN）** 的访问控制
- 精确到 **进程/二进制路径（Binary）+ 协议（TCP/UDP）+ 目的端口（DPort）+ 目的地址（IP/CIDR）**
- 同时支持 **黑名单（Block rules）** 与 **白名单（Allowlist：Learn → Enforce）**
- 支持 **声明式/幂等** 更新、持久化状态、紧急停用

> 适用场景示例：传统裸机、虚拟机、边缘节点、隔离区主机、PoC/演示环境——当你没有 Kubernetes，也没有 Cilium Network Policy，但仍希望获得“按域名”的精细访问控制能力。

---

## 目标

在没有 Cilium Network Policy（也没有 Kubernetes）的前提下，提供与云原生网络策略类似的访问控制体验：

1. **基于域名（FQDN）的精确控制**：不仅看 IP，还能看 “访问哪个域名”。  
2. **精确到进程/Binary**：同一个主机上的不同进程可以有完全不同的访问权限。  
3. **精确到端口/协议**：例如允许 `curl` 访问 `google.com:443`，但阻断 `curl` 访问 `sina.com:443`；允许 UDP 53 做 DNS，但阻断未知二进制的任意 UDP 出站。  
4. **黑白名单并存**：
   - 黑名单：明确阻断某二进制访问某域名/IP 段
   - 白名单：学习阶段自动生成允许规则，随后进入强制执行（默认拒绝）

---

## 核心原理（为什么必须是企业版）

### 1) 关键前提：Tetragon Enterprise 的高级网络与 L7 解析能力

TetraBlocker 的“按域名控制”依赖于 **Tetragon Enterprise 的 BPF DNS Parser** 与高级网络可观测能力：

- **Advanced L7 parsers**：DNS / HTTP / TLS 等  
- **Advanced network observability**：TCP、UDP、（以及更多网络事件类型）

在真实主机中，网络连接在内核里发生时看到的是 **目的 IP/端口**，而不是“域名”。要想实现“按域名”控制，就必须在主机侧可靠地得到：

- “某个进程解析了哪个域名”（process_dns）
- “某个进程连接到了哪个 IP/端口”（process_connect）
- “域名 ↔ IP” 的映射缓存（来自 BPF DNS parser 的内核侧解析与映射表）

如果没有企业版的 DNS BPF Parser，域名解析信息往往只能从用户态/应用日志间接获得，准确性、时序一致性与可控性都不足以支撑稳定的“按域名阻断”。

### 2) 实现链路：从“域名”落到“内核可阻断的 IP”

TetraBlocker 的核心思路是一个可控的“域名 → IP 学习器 + 策略生成器”，并将策略下发到 Tetragon 的 TracingPolicy（eBPF enforcement）中：

1. **事件输入（gRPC 流）**  
   通过 `tetra getevents --host` 持续订阅事件流。  
   - 白名单学习：主要使用 `process_connect` 与 `process_dns`  
   - 黑名单规则：主要依赖 `process_dns` 触发学习，然后更新 DAddr 列表

2. **域名/IP 关联（BPF DNS Parser 映射表）**  
   由于主机环境的 `process_dns` 通常不直接携带 Answer IP，TetraBlocker 使用：
   - `tetra debug dns dump` 获取 **IP ↔ domain** 映射表（来自 BPF DNS parser）
   - 用映射表将“域名允许/阻断”落到“IP/CIDR 允许/阻断”

3. **策略生成（TracingPolicy YAML）**  
   TetraBlocker 将策略渲染为 TracingPolicy YAML：
   - TCP：hook `tcp_connect`
   - UDP：hook `udp_sendmsg`
   - selector 里使用 `matchBinaries` + `DPort` + `DAddr` 等条件
   - 动作使用 `Sigkill`或其它动作（可扩展）

4. **即时生效 + 启动持久化**  
   - 即时生效：`tetra tracingpolicy add <yaml>`  
   - 重启持久化：YAML 同时写入 `/etc/tetragon/tetragon.tp.d/`（重启后仍在）

---

## 白名单（Allowlist）机制：Learn → Enforce（默认拒绝）

### 学习阶段（默认 5 分钟）
- TetraBlocker 启动后进入学习窗口（默认300秒，这是为了调试方便的初始值，建议实际应用时调到足够反应环境网络情况的观察时长）
- 期间它会记录主机上发生过的网络行为：
  - binary（进程二进制路径）
  - proto（tcp/udp）
  - port（目的端口）
  - domains（目的域名，如果可关联）
  - cidrs（目的 IP 的 /32 或 /128）
- 学到的记录会追加写入一个 **人类可读且可修改** 的 allowlist 文件：`/etc/tetrablocker/allowlist.json`
- allowlist 文件可预置：程序默认会先放行 `systemd-resolved` 的 DNS 行为，避免进入 Enforce 后 DNS 瘫痪。

### 自动进入 Enforce（无须额外开关）
学习窗口结束后，allowlist 文件会标记 `learning.completed=true`。从此：
- 程序自动进入 Enforce（默认拒绝）
- **重启服务也会直接进入 Enforce**（因为 completed 标记已持久化），当认为有必要重新开始学习时，可以将learning.completed置为false，并将起始时间learning.started_at置为0。程序会自动读到新的状态开始继续学习（已经学习到的白名单并不会清空，除非管理员手动更改）。

### Enforce 的策略生成方式（精确到 binary + 目的地）
为了做到多重条件匹配，比如“只允许 `curl cisco.com`，阻断 `curl bigbad.com`”，TetraBlocker 使用 **同一 hook 多个 selector 的短路匹配** 语义：

- 对每个白名单的 binary（或 binary pattern）生成一个 `tb-allowlist-...` 策略：
  - **前几个 selector 是 allow selector**：匹配 “binary + port + addr” 后执行 `NoPost`（相当于放行）
  - **最后一个 selector 是 deny selector**：只匹配 binary，执行 `Sigkill`（兜底拒绝）
- 同时生成 `tb-allowlist-unknown-tcp/udp` 两条策略：对“不在 allowlist 的二进制”做兜底拒绝。

这样既能做到：
- 同一个 binary 不同域名/不同目的 IP 的精确放行/阻断
- 未出现在 allowlist 的 binary 一律阻断（TCP/UDP 都覆盖）

---

## 优势

1. **将eBPF能力从Cilium CNI扩展到普通虚机/物理机**  
   在传统主机上也能实现“按域名”访问控制体验。

2. **真正精确：binary + domain + ip + port + proto**  
   不是粗粒度“允许某个进程所有外联”，而是可控到具体目的地。domain在策略执行时会转换为动态更新的即时地址解析集合（ip_cache），与ip共同参与判定（或的关系），这样可以灵活适配同域名但CDN原因解析地址不断变化的网络环境。

3. **低延迟优化与效率改进（相对朴素轮询方案）**  
   - gRPC 流式订阅（无需全量扫日志文件）
   - DNS dump 节流（`dns_dump_min_interval_seconds`）避免高频 fork
   - 学习窗口与域名预热（getent）降低首次命中空窗
   - 快速重试（dns dump 暂时拿不到映射时短时间重试）
   - YAML hash 去抖：所有策略都有哈希校验，多次重复DNS如果地址解析没有发生变化就不会重复更新策略，避免数据面抖动
   - 声明式 reconcile：黑白名单策略变化后可幂等更新

4. **eBPF的高性能低开销特性得以充分发挥**
   - BPF DNS Parser 让 “域名 ↔ IP” 关联更可靠、更及时
   - 网络事件覆盖 TCP/UDP（可扩展到更多协议与事件类型）
   - eBPF enforcement 在内核层执行，具备可观测与可阻断的一体化能力

---

## 安装

项目目录只需要 3 个文件：
- `tetrablocker`（主程序）
- `tetrablocker.conf`（配置）
- `tetrablocker.service`（systemd unit）

使用脚本 **install-update-all.sh** 一键安装/升级（幂等）。

```bash
chmod +x install-update-all.sh
sudo ./install-update-all.sh
```

脚本会自动：
- 停止现有 tetrablocker（如存在）
- 安装/覆盖程序、配置、service 文件（带备份）
- 创建必要目录（policy_dir/state_dir/allowlist_dir）
- 校验 Python 语法与 JSON 配置
- systemd reload + enable + start
- 打印常用运维命令

---

## 使用

### 1) tetrablocker.conf 配置项说明

以下字段均为 JSON 配置：

#### 基础
- `tetra_bin`  
  tetra CLI 的绝对路径（systemd 环境 PATH 可能不含 `/usr/local/bin`，建议使用绝对路径）。

- `tetra_args`  
  tetra 命令的附加参数（例如指定 gRPC 地址、TLS 等）。

- `policy_dir`  
  TracingPolicy YAML 落盘目录（用于重启后仍保留策略）。

- `state_dir`  
  运行状态持久化目录：保存黑名单规则的 IP cache / YAML hash / last_apply_ts，以及 allowlist 策略 hash 等。

- `config_reload_seconds`  
  周期性检查并 reload 配置文件的间隔（秒）。

- `dns_dump_min_interval_seconds`  
  运行 `tetra debug dns dump` 的最小间隔（秒）。用于节流，降低 CPU 与 fork 开销。

#### 黑名单（Block rules）相关（rules[]）
- `rules`  
  黑名单列表。每条 rule 会生成一个同名 TracingPolicy，并持续用 DNS 解析映射更新 DAddr。

每条 rule 字段：
- `name`：策略名（也用于 YAML 文件名）。  
- `binary`：精确匹配的二进制路径（例如 `/usr/bin/curl`）。  
- `domains`：域名列表（`sina.com` 与 `sina.com.` 都可写，程序会归一化）。  
- `action`：命中后动作（常用 `Sigkill`）。  
- `protocol`：目前规则侧以 `tcp` 为主（hook `tcp_connect`）。  
- `ports`：只针对这些目的端口生效（如 80/443）。  
- `ip_ttl_seconds`：学到的 IP 过期时间，避免列表无限增长。  
- `max_ips`：每条规则最多保留多少 CIDR。  
- `apply_cooldown_seconds`：同一规则最短重下发间隔，减少 churn。  

> 黑名单用于“明确禁止某进程访问某域名/目的地”，白名单用于“默认拒绝，仅允许已学习/已声明的访问”。两者可同时启用。

#### 白名单（Allowlist）相关（自动 Learn → Enforce）
- `allowlist`  
  是否启用 allowlist 功能。**紧急停用时改为 false**，程序会清理所有 `tb-allowlist-*` 策略与 YAML。

- `allowlist_file`  
  allowlist 文件路径（人类可读可编辑，默认 `/etc/tetrablocker/allowlist.json`）。

- `allowlist_learning_seconds`  
  学习阶段持续时间（秒），默认 300。学习结束后自动进入 enforce。重启后仍 enforce。

- `allowlist_policy_prefix`  
  allowlist 策略名前缀，默认 `tb-allowlist`。所有自动生成策略都以此开头，便于识别与清理。

- `allowlist_action`  
  默认拒绝动作（常用 `Sigkill`）。

- `allowlist_reload_seconds`  
  allowlist 文件变更检测频率（秒）。你可以人工编辑 allowlist，程序会自动加载并 reconcile。

- `allowlist_addr_values_per_selector`  
  每个 allow selector 最多放多少个 DAddr 值（CIDR）。用于控制单 selector 体积。

- `allowlist_port_values_per_selector`  
  每个 allow selector 最多放多少个端口范围值（例如 `80` 或 `80:90`）。用于控制体积。

- `allowlist_max_allow_selectors_per_policy`  
  每条策略最多允许多少个 allow selectors（再加 1 个 deny selector）。  
  注意：单个 hook 的 selector 数有硬上限（建议保持 allow selectors <= 4）。

- `allowlist_domain_refresh_seconds`  
  Enforce 阶段域名 IP 刷新周期（秒）。用于适配 CDN/短 TTL 域名。

- `allowlist_domain_max_ips`  
  每个域名最多保留多少个 IP（CIDR）。域名 IP 过多会触发 selector 预算压力（见“优化建议”）。

#### 其它行为控制
- `reconcile_on_reload`  
  配置变更后是否做声明式 reconcile（默认 true）。

- `prewarm_on_start` / `prewarm_on_reconcile`  
  启动或配置变更时是否做域名预热（`getent ahosts`），减少首访空窗。

- `dns_retry_attempts` / `dns_retry_sleep_seconds`  
  dns dump 暂时拿不到映射时的快速重试参数。

---

### 2) allowlist.json 典型条目解释

下面是一个典型 allowlist 文件结构（节选并解释）：

```json
{
  "items": [
    {
      "binary": "/opt/splunkforwarder/bin/splunkd",
      "binary_operator": "In",
      "cidrs": ["10.75.53.97/32"],
      "domains": [],
      "port": 9997,
      "proto": "tcp",
      "updated_at": 1772179012.1217167
    },
    {
      "binary": "/usr/bin/curl",
      "binary_operator": "In",
      "cidrs": ["74.125.68.101/32"],
      "domains": ["google.com."],
      "port": 80,
      "proto": "tcp",
      "updated_at": 1772178846.5596542
    },
    {
      "binary": "/usr/lib/systemd/systemd-resolved",
      "binary_operator": "In",
      "cidrs": [],
      "domains": ["*"],
      "port": 53,
      "proto": "tcp",
      "updated_at": 1772178716.0384495
    }
  ],
  "learning": {
    "completed": true,
    "completed_at": 1772179016.1552198,
    "duration_seconds": 300,
    "started_at": 1772178716.0717344
  },
  "version": 1
}
```

字段含义：

- `binary`  
  进程二进制路径（用于 matchBinaries）。

- `binary_operator`  
  二进制匹配运算符：  
  - `In`：精确路径匹配  
  - `Prefix`：前缀匹配（建议用来减少条目数，例如 `/usr/bin/*`）  
  - `Postfix`：后缀匹配（不建议滥用，容易误伤）

- `proto` / `port`  
  协议与目的端口。每条 item 通常对应 “binary + proto + port”。  
  这样能保证严格控制：只允许该 binary 在该端口上的访问。

- `domains`  
  允许访问的域名集合：  
  - `["google.com."]` 表示只允许访问该域名（程序会用 DNS parser 映射把域名扩展为一组 IP/CIDR）  
  - `["*"]` 表示允许任意域名（用于 DNS 组件/系统组件的放行）

- `cidrs`  
  允许访问的 IP/CIDR 集合（通常是学习阶段采集到的目的 IP 变成 /32 或 /128）。  
  若 domains 为空，则只按 IP 控制；若 domains 非空，则 domains 也会转化为 IP 集合并合并进策略。

- `updated_at`  
  最后一次观察到该条目发生的时间戳（epoch seconds）。可用于人工清理陈旧条目。

- `learning`  
  学习状态。`completed=true` 表示已进入 Enforce（默认拒绝），重启后仍 enforce。

---

## 更新策略、幂等性与紧急停止

### 1) 更新 allowlist（声明式、幂等）
- 你可以直接编辑 `allowlist.json`（增加/删除 items、改 domains/cidrs/port/proto 等）
- 保存后，程序会在 `allowlist_reload_seconds` 周期内自动加载并 reconcile
- reconcile 是幂等的：策略内容 hash 不变不会重复下发

### 2) 更新 tetrablocker.conf（声明式、幂等）
- 修改 `tetrablocker.conf` 后，程序在 `config_reload_seconds` 内自动 reload 并 reconcile
- 黑名单规则（rules[]）与白名单 enforcement 都会随配置变化更新

### 3) 紧急停止阻断（Emergency Off）
将 `tetrablocker.conf` 中：
- `"allowlist": false`

然后：
```bash
sudo systemctl restart tetrablocker
```

程序会自动清理所有 `tb-allowlist-*` TracingPolicy（运行时）和对应 YAML（磁盘），恢复到无 allowlist enforcement 的状态。

> 提示：如果你仍启用了黑名单 rules[]，黑名单阻断仍会生效；如需完全停止阻断，请同时清理 rules[] 或停服务。

---

## 优化建议（面向生产可控性）

### 1) 将常见 binary 改为 Prefix/Postfix，减少条目数
当你发现同一路径下存在很多子命令（例如 `/usr/bin/*`），建议将 allowlist 里的 binary 改成：
- `binary_operator: "Prefix"`
- `binary: "/usr/bin/"`

这可以显著减少 allowlist 项数量与策略体积。

### 2) 域名 IP 过多会触发 selector 预算压力
CDN/大站点（例如某些云服务域名）可能在短时间内映射到大量 IP。由于单个 hook 的 selector 数与每个 selector 的 value 数都有限，可能出现：
- 放行 selector 不够用（预算被耗尽）
- 需要你人工做取舍

建议应对策略：
- 缩小域名范围（只保留必要域名）
- 改用更粗 CIDR（例如 /24，谨慎评估误伤风险）
- 拆分策略：将一个 binary 的访问范围按业务拆成多个更小集合
- 调整 `allowlist_domain_max_ips`、`allowlist_addr_values_per_selector`，在“精确性 vs 规模”之间做平衡

### 3) 学习窗口覆盖面与误伤
学习 5 分钟无法覆盖所有偶发路径（cron、故障恢复、夜间任务）。建议流程：
- 先 learning + 人工 review allowlist
- 再 enforce
- 为关键系统组件（DNS、时间同步、包管理、监控 agent）预置 allowlist 条目

---

## 注意事项与限制（当前版本）

1. **依赖 Tetragon Enterprise**  
   特别是 BPF DNS parser 与高级网络可观测能力是“按域名控制”的关键基础。

2. **域名可见性限制**  
   - DoH/DoT（加密 DNS）可能导致域名不可见，只能按 IP 控制
   - 应用直接连接 IP 时无域名信息

3. **策略生效存在秒级延迟**  
   TracingPolicy add 后需要 Tetragon 加载/attach eBPF，可能有秒级延迟（属于控制面/attach 开销）。

4. **误杀风险**  
   默认动作 `Sigkill` 会直接杀进程。建议在生产环境将策略验证充分后再启用，或引入更温和动作（可扩展）。

5. **脚本/解释器路径**  
   对脚本执行，binary 通常是解释器（如 `/usr/bin/python3`），白名单需要允许解释器路径。

6. **路径 allowlist 的先天缺陷**  
   若允许的二进制被替换为恶意版本，仍会被允许联网。未来可扩展 FIM 校验（当前版本不包含）。

---

## 运维命令速查

```bash
# 查看日志
sudo journalctl -u tetrablocker -f

# 查看状态
sudo systemctl status tetrablocker --no-pager

# 停止/启动/重启
sudo systemctl stop tetrablocker
sudo systemctl start tetrablocker
sudo systemctl restart tetrablocker

# 列出当前 TracingPolicy
sudo tetra tracingpolicy list

# 查看 allowlist 文件
cat /etc/tetrablocker/allowlist.json | sed -n '1,200p'

# 查看自动生成的 allowlist 策略 YAML
ls -l /etc/tetragon/tetragon.tp.d/tb-allowlist-*.yaml 2>/dev/null || true
```

---

## Roadmap（可选增强）

- FIM 校验：对 allowlist binary 做哈希/签名校验，防止二进制被替换
- 更丰富的动作：从 Sigkill 扩展到更温和的 block/deny（按场景选择）
- 更强的域名/IP 管理策略：TTL 对齐、IP 变更回收、策略自动拆分与预算提示
- 统一策略可视化：输出策略摘要、命中统计、审计报告等

   
