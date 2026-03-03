# TetraBlocker

TetraBlocker 是一个面向 **非 Kubernetes / 非 Cilium Network Policy** 场景的主机侧网络访问控制原型（可产品化），基于 **Tetragon Enterprise** 的 eBPF 能力，在 Linux 主机上实现：

- **按域名（Domain/FQDN）** 的访问控制
- 精确到 **进程/二进制路径（Binary）+ 协议（TCP/UDP）+ 目的端口（DPort）+ 目的地址（IP/CIDR）**
- 同时支持 **黑名单（Block rules）** 与 **白名单（Allowlist：Learn → Enforce）**
- 支持 **声明式/幂等** 更新、持久化状态、紧急停用与快速清理策略

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

## 原理

### 1) 关键前提：Tetragon Enterprise 的高级网络与 L7 解析能力

TetraBlocker 的“按域名控制”依赖于 **Tetragon Enterprise 的 BPF DNS Parser** 与高级网络可观测能力：

- **Advanced L7 parsers**：DNS / HTTP / TLS 等  
- **Advanced network observability**：TCP、UDP、（以及更多网络事件类型）

在真实主机中，网络连接在内核里发生时看到的是 **目的 IP/端口**，而不是“域名”。要想实现“按域名”控制，就必须在主机侧可靠地得到：

- “某个进程解析了哪个域名”（process_dns）
- “某个进程连接到了哪个 IP/端口”（process_connect）
- “域名 ↔ IP” 来自 BPF DNS parser 的内核侧解析与映射表，1.17从DNS Dump获取，1.18以上直接从process_dns获取

如果没有企业版的 DNS BPF Parser，域名解析信息往往只能从用户态/应用日志间接获得，准确性、时序一致性与可控性都不足以支撑稳定的“按域名阻断”。

### 2) 实现链路：从“域名”落到“内核可阻断的 IP”

TetraBlocker 的核心思路是一个可控的“域名 → IP 学习器 + 策略生成器”，并将策略下发到 Tetragon 的 TracingPolicy（eBPF enforcement）中：

1. **事件输入（gRPC 流）**  
   通过 `tetra getevents --host` 持续订阅事件流。  
   - 白名单学习：主要使用 `process_connect` 与 `process_dns`  
   - 黑名单规则：主要依赖 `process_dns` 触发学习，然后更新 DAddr 列表

2. **域名/IP 关联（BPF DNS Parser 映射表）**  
   Tetragon Enterprise 1.18直接从process_dns事件获取，而之前版本的 `process_dns` 通常不直接携带 Answer IP，TetraBlocker 使用：
   - `tetra debug dns dump` 获取 **IP ↔ domain** 映射表（来自 BPF DNS parser）
   - 用映射表将“域名允许/阻断”落到“IP/CIDR 允许/阻断”
   - TetraBlocker会自适应不同的版本实现路径

3. **策略生成（TracingPolicy YAML）**  
   TetraBlocker 将策略渲染为 TracingPolicy YAML：
   - TCP：hook `tcp_connect`
   - UDP：hook `udp_sendmsg`
   - selector 里使用 `matchBinaries` + `DPort` + `DAddr` 等条件
   - 动作使用 `Sigkill` 或其它动作（可扩展）

4. **即时生效 + 启动持久化**  
   - 即时生效：`tetra tracingpolicy add <yaml>`  
   - 重启持久化：YAML 同时写入 `/etc/tetragon/tetragon.tp.d/`（重启后仍在）

---

## 白名单（Allowlist）

### 学习阶段（默认 5 分钟）
- TetraBlocker 启动后进入学习窗口（默认 300 秒；实际应用建议调到覆盖你环境网络行为的观察时长）
- 期间它会记录主机上发生过的网络行为：
  - binary（进程二进制路径）
  - proto（tcp/udp）
  - port（目的端口）
  - domains（目的域名，如果可关联）
  - cidrs（目的 IP 的 /32 或 /128）
- 学到的记录会追加写入一个 **人类可读且可修改** 的 allowlist 文件：`/etc/tetrablocker/allowlist.json`
- allowlist 文件可预置：通过 **seed allowlist** 提供最小初始白名单，避免“刚进 Enforce 影响系统的正常运作”。

### 自动进入 Enforce（无须额外开关）
学习窗口结束后，allowlist 文件会标记 `learning.completed=true`。从此：
- 程序自动进入 Enforce（默认拒绝）
- **重启服务也会直接进入 Enforce**（因为 completed 标记已持久化）
- 当认为有必要重新开始学习时，可以将：
  - `learning.completed` 置为 `false`，且
  - `learning.started_at` 置为 `0`
  - 然后按需调整本次的学习时长`duration_seconds`
  程序会自动开始新的学习窗口（已存在的 allowlist 不会自动清空，除非管理员手动清理）

### Enforce 的策略生成方式（精确到 binary + 目的地）
为了做到多重条件匹配，比如“只允许 `curl cisco.com`，阻断 `curl bigbad.com`”，TetraBlocker 使用 **同一 hook 多个 selector 的短路匹配** 语义：

- 对每个白名单的 binary（或 binary pattern）生成一个 `tb-allowlist-...` 策略：
  - **前几个 selector 是 allow selector**：匹配 “binary + port + addr” 后执行 `NoPost`（相当于放行）
  - **最后一个 selector 是 deny selector**：只匹配 binary，执行 `Sigkill`（兜底拒绝）
- 同时生成 `tb-allowlist-unknown-tcp/udp` 两条策略：对“不在 allowlist 的二进制”做兜底拒绝。

> 本应用特别对维持系统正常运作的系统二进制以及确认的可信二进制做了更方便的设置：支持 **Trusted Binary**（见下文），对可信二进制无需再进行详细策略设置，避免策略设置不当导致的误杀，也节省策略资源（例如 `systemd-resolved`）。

---

## 黑名单(DenyList)

黑名单则可以针对二进制、IP地址/Domain、协议类型、端口号进行匹配，匹配规则与白名单里匹配的规则一样，但每一条规则都可单独设置Action，默认为`Sigkill`(杀掉进程)。

黑名单的Action是`Sigkill`时，将具有绝对的高优先权，即当白名单的决策是放行，同时还匹配到了黑名单的`Sigkill`时，黑名单的决策优先。但如果黑名单放弃deny而是`NoPost`，则还是会落入白名单的默认deny。

---

## 白名单的构建

自主学习后的白名单是一个很好的起点，但在真实系统里，它常常不足以生成“稳定可用”的完整白名单。原因通常不在于“学习逻辑不工作”，而在于 **系统行为本身的不可穷举性**。

### 1) 为什么学习期可能“学不全”

常见影响因素：

1. **时间窗口问题**  
   学习期 5~30 分钟无法覆盖所有周期性任务（cron、timer、夜间任务、健康检查、偶发故障恢复流程）。

2. **启动顺序问题**  
   关键网络行为可能发生在 boot 早期（服务在 tetrablocker 启动前已完成关键外联），学习期看不到。

3. **缓存导致“没有发生”**  
   DNS、HTTP、TLS、包管理器都可能缓存命中；学习期命中缓存就不会产生对应网络事件，进入 Enforce 后缓存失效才出现“新外联”，导致误杀。

4. **归因不一致（helper/子进程）**  
   你以为是 `git` 出网，但实际发包的是 `ssh` 或 `git-remote-https`；你以为是应用本体，但实际发包的是解释器（`python3`/`node`/`java`）或系统守护进程。

5. **目的 IP 动态变化（CDN/短 TTL）**  
   学到的是某次解析得到的 IP；进入 Enforce 后 IP 变化导致“已学过域名但连接被拒绝”。需要依赖域名→IP 的持续刷新与预算管理。

6. **IPv6 与多栈差异**  
   学习期可能只看到 IPv4，而运行时走 IPv6（或反之），导致不匹配。

7. **加密 DNS（DoH/DoT）**  
   域名不可见时，只能按 IP 控制，学习期即使看到了“连接”，也无法稳定把它归因到域名。

### 2) 如何解决：

为了让系统在 Enforce 下“稳定可用”，建议采用组合策略：

#### A) Trusted Binary 机制（推荐作为默认基线）
- 对少量“系统生命线/网络生命线”二进制启用 trusted：
  - 典型如 `systemd-resolved`、NetworkManager 等，它们会被“保送”白名单
- trusted 的意义不是“完全放开出网”，而是：
  - 被“保送”进白名单后将**不再对该二进制生成 per-binary 的兜底 Sigkill selector**，但同时白名单也有可能学到它们更“具体”的网络活动，因此你会看到很多条目存在一定程度的重叠，就是因为有些是提前塞入的，有些是在学习窗口期动态学习到的，以后可以逐步优化
  - 提前”保送“的重要意义在于避免在学习窗口期没能捕捉到某个少见的端口/目的地导致关键进程被杀，进而造成系统功能瘫痪或将自身锁在外面的灾难

> Trust 列表应可通过配置项维护（无需改代码）。建议只 trust 系统生命线类进程和确定信任的二进制加入 trust，避免过渡授权。

#### B) Seed Allowlist（初始白名单）
- 在新系统上首次安装时，若 allowlist 文件不存在，则自动复制 `allowlist-seed.json` 作为 `/etc/tetrablocker/allowlist.json`
- seed allowlist 的目标是提供“最小可用基线”，例如确保 DNS resolver 自身永远可用（udp/tcp 53）

#### C) 全局 DNS Stub 放行（推荐）
- 允许所有进程访问本机 stub resolver（例如 `127.0.0.53:53`）
- 这样无需为每个应用单独加“访问 127.0.0.53:53”的白名单条目
- 这只解决“本机 DNS 请求能发出去”，并不等于放开外联；外联仍由 allowlist/unknown 机制控制

### 3) 在新系统上构建更完整白名单的最佳实践

在一台全新的系统上，要得到更完整的 trusted/seed 白名单，通常按以下方法做“面向系统真实环境的取样”：

1) 盘点系统关键网络组件（服务与进程）
- 利用下面脚本取得系统完整信息
```bash
 sudo ./gethostinfo.sh 
```

2) 明确服务器的角色/用途
- Web/DB/代理/CI等等具体用途明确

3) 尽可能列出已知的长期不断网的组件清单
- 比如Amazon SSM Agent、CloudWatch Agent、Splunk UF、包更新（dnf repo）、时间同步（chrony）、容器 runtime（containerd/docker）、自己的代理/VPN 等

4) 尽可能列出需要控制的颗粒度和预设条件
- 只按 domain 控制？还是要精确到 binary + port + protocol？
- 是否允许 IPv6（如果不允许，我会在 seed 里默认只放行 IPv4 A 记录，丢弃 AAAA 的 ips）
- 计划初始允许/禁止访问的域名集合，例如：允许 *.amazonaws.com（ECR/S3/STS/SSM）、github.com、pypi.org、公司内部域名等
- 以及你想默认 block 的域名类别（广告、追踪、已知恶意等）

5) 当前服务器的网络形态
- 是否有企业代理（http_proxy/https_proxy）？是否走 NAT / VPC Endpoint？
- 是否需要访问 VPC 内部 CIDR（私网服务）以及端口范围

将以上所有信息提交给ISOVALENT Tetragon企业版本地服务团队，或者你信任的AI（ISOVALENT强大的社区基础造就了AI对Tetragon丰富的知识能力），可以生成满意的`tetrablocker.conf`初始参数和`allowlist-seed.json`初始白名单。

最后在进入Enforce模式后需要持续观察与迭代，包括：
- 用日志快速定位误杀的 binary 与目的地
- 将“不可穷举但必须稳定”的组件收敛进 trust 或 seed allowlist
- 将“业务必需但变化大”的域名放入 allowlist，并通过 domain refresh 控制 IP churn

需要特别强调的一点是，真实环境会是极为复杂的，以上过程需要长期迭代，所以最佳实践是关闭操作系统上没有必要开启的任何服务和应用，采用极简的操作系统运行业务应用，这样不仅减少的暴露面，也可以有效减少策略数量，易于后期白名单的维护。

---

## 优势

1. **将 eBPF 能力从 Cilium CNI 扩展到普通虚机/物理机**  
   在传统主机上也能实现“按域名”访问控制体验。

2. **真正精确：binary + domain + ip + port + proto**  
   不是粗粒度“允许某个进程所有外联”，而是可控到具体目的地。domain 在策略执行时会转换为动态更新的即时地址解析集合（ip_cache），与 ip 共同参与判定（或的关系），可适配 CDN/短 TTL 环境。

3. **低延迟优化与效率改进（相对朴素轮询方案）**  
   - gRPC 流式订阅（无需全量扫日志文件）
   - DNS dump 节流（`dns_dump_min_interval_seconds`）避免高频 fork
   - 学习窗口与域名预热（getent）降低首次命中空窗
   - 快速重试（dns dump 暂时拿不到映射时短时间重试）
   - YAML hash 去抖：策略内容不变不重复下发，避免数据面抖动
   - 声明式 reconcile：配置参数、黑白名单策略变化后可随时在线幂等更新

4. **eBPF 的高性能低开销特性得以充分发挥**
   - BPF DNS Parser 让 “域名 ↔ IP” 关联更可靠、更及时
   - 网络事件覆盖 TCP/UDP（可扩展到更多协议与事件类型）
   - eBPF enforcement 在内核层执行，具备可观测与可阻断的一体化能力

5. **稳定性考量**
   - 全面考虑各种临界状态下网络的稳定，比如重启后会自动高频检测dns缓存状态，没有充分预热前不加载策略以避免误杀

6. **安全性考量**
   - 内核态实现关键安全逻辑，即便用户态Agent被非法中断，也不影响安全措施
   - 内核态逻辑有自保护挂钩，几乎无法在不触碰挂钩情况下破坏内核逻辑
   - 自带健康度监测，对非法迫害、运行异常等都会产生对应告警

---

## 安装

项目目录建议包含以下文件：
- `tetrablocker`（主程序）
- `tetrablocker.conf`（配置，第一次安装可从example文件修订而来）
- `tetrablocker.service`（systemd unit）
- `allowlist-seed.json`（初始白名单 seed，第一次安装可从example文件修订而来）
- `install_update_all.sh`（一键安装/升级，幂等）
- `clean-stop`（清理策略并停服务）
- `....example-XXX` (配置或初始白名单示例)

安装前请确认Tetragon Enterprise的gRPC流式事件输出正常：
```bash
timeout 10 sudo tetra getevents -o compact
🚀 process server /usr/sbin/ip6tables -w 5 -W 100000 -S KUBE-PROXY-CANARY -t mangle 
🚀 process server /usr/sbin/iptables -w 5 -W 100000 -S KUBE-PROXY-CANARY -t mangle 
💥 exit server /usr/sbin/ip6tables -w 5 -W 100000 -S KUBE-PROXY-CANARY -t mangle 0 
💥 exit server /usr/sbin/iptables -w 5 -W 100000 -S KUBE-PROXY-CANARY -t mangle 0 
🚀 process server /usr/sbin/iptables -w 5 -W 100000 -S KUBE-KUBELET-CANARY -t mangle 
```

确认所需的各事件类型都在：
```bash
timeout 10 sudo tetra getevents | jq -c 'select(.process_dns != null)'
timeout 10 sudo tetra getevents | jq -c 'select(.process_connect != null)'
```

1.17.x版本请确认DNS dump正常：
```bash
sudo tetra debug dns dump
```

**最重要的，是需要先设置好tetrablocker.conf的各项配置以及在开启学习模式之前的初始白名单allowlist-seed.json，请详见“白名单的构建”以及“使用”部分**

确认以上后就可以使用脚本 **install_update_all.sh** 一键安装/升级（幂等）：

```bash
chmod +x install_update_all.sh
sudo ./install_update_all.sh
```

脚本会自动：
- 停止现有 tetrablocker（如存在）
- 安装/覆盖程序、配置、service 文件（带备份）
- 创建必要目录（policy_dir/state_dir/allowlist_dir）
- **如果 allowlist 文件不存在：复制 allowlist-seed.json 作为初始 allowlist**
- 校验 Python 语法与 JSON 配置
- systemd reload + enable + start，保证TetraBlocker在主机重启后也会自动加载运行
- 打印常用运维命令

---

## 使用

日常使用中黑白名单甚至基础参数的修改都无需重启应用，应用本身会自动识别加载，刷新现有策略和配置。

极少数情况（如修改源代码）需要重启应用也只需执行 `install_update_all.sh`，程序会幂等更新。重启后白名单不会进入学习状态、已学习的也不会丢失。

如需切换到学习状态可按前面说明修改`learning.completed`和`learning.started_at`字段。如需重新开始从零学习，只需除了修改前面字段以外，再删去不想要的白名单部分即可。

>注意，只有把`tetrablocker.conf`文件和`allowlist.json`文件置于`/etc/tetrablocker/`目录中才会生效。所以可以直接修改这些目录内的文件，**推荐的做法是`tetrablocker.conf`要修改当前工作目录的这个版本，然后手工复制到`/etc/tetrablocker/`或直接执行`install_update_all.sh`；而`allowlist.json`则直接修改`/etc/tetrablocker/`目录中的文件，因为当前工作目录只保留初始白名单`allowlist-seed...`，而自动脚本`install_update_all.sh`也只有在第一次安装时才会把初始白名单复制到`/etc/tetrablocker/`目录**。

### 1) tetrablocker.conf 配置项说明(生效文件是/etc/tetrablocker/tetrablocker.conf)

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

#### 白名单（Allowlist）配置项说明（生效文件是/etc/tetrablocker/allowlist.json）
- `allowlist`  
  是否启用 allowlist 功能。紧急停用时改为 false，程序会清理所有 `tb-allowlist-*` 策略与 YAML。

- `allowlist_file`  
  allowlist 文件路径（人类可读可编辑，默认 `/etc/tetrablocker/allowlist.json`）。

- `allowlist_learning_seconds`  
  学习阶段持续时间（秒）。学习结束后自动进入 enforce。重启后仍 enforce。

- `allowlist_policy_prefix`  
  allowlist 策略名前缀，默认 `tb-allowlist`。所有自动生成策略都以此开头，便于识别与清理。

- `allowlist_action`  
  默认拒绝动作（常用 `Sigkill`）。

- `allowlist_reload_seconds`  
  allowlist 文件变更检测频率（秒）。你可以人工编辑 allowlist，程序会自动加载并 reconcile。

- `allowlist_addr_values_per_selector`  
  每个 allow selector 最多放多少个 DAddr 值（CIDR）。地址 values 是 map 装载，不受一般运算符下4个value的限制，此处仅用于控制单 selector 体积。

- `allowlist_port_values_per_selector`  
  每个 allow selector 最多放多少个端口范围值（例如 `80` 或 `80:90`）。端口 values 是 map 装载，不受一般运算符下4个value的限制，此处仅用于控制单 selector 体积。

- `allowlist_max_allow_selectors_per_policy`  
  每条策略最多允许多少个 allow selectors。  
  注意：当前版本单个 hook 的 selector 数有硬上限5，考虑到除了trusted binary以外都有用于默认deny的deny selector，因此建议保持 allow selectors <= 4。由于每个selector限定了地址/端口数量，所以单策略（即每个Binary）理论最大 allow 地址/port 数量为 4 x addr/port_values_per_selector 

- `allowlist_domain_refresh_seconds`  
  Enforce 阶段域名 IP 刷新周期（秒）。用于适配 CDN/短 TTL 域名。

- `allowlist_domain_max_ips`  
  每个域名最多保留多少个 IP（CIDR）。域名 IP 过多会触发 selector 预算压力（见“优化建议”）。

#### 可信组件与本机 DNS stub（推荐）
- `allowlist_trusted_binaries`  
  可信二进制路径列表（exact match）。对这些 binary 生成的 per-binary policy 不再包含deny selector (“兜底 Sigkill selector”)，避免系统生命线误杀。在unknown兜底策略中它们也将会被排除在Sigkill的目标以外。

- `allowlist_global_dns_stub_allow`  
  是否允许任意 binary 访问本机 stub resolver（推荐 true）。

- `allowlist_dns_stub_cidrs` / `allowlist_dns_stub_ports`  
  本机 DNS stub 的 CIDR 与端口（例如 `127.0.0.53/32` + `53`）。

> 在启用“全局 DNS Stub 放行”之后，只要本节点使用DNS stub（大部分都默认使用），那么在手工为白名单增加新的允许访问项目时无须特别为该二进制设置DNS放行策略

#### 其它行为控制
- `reconcile_on_reload`  
  配置变更后是否做声明式 reconcile（默认 true）。

- `prewarm_on_start` / `prewarm_on_reconcile`  
  启动或配置变更时是否做域名预热（`getent ahosts`），减少首访空窗。

- `dns_retry_attempts` / `dns_retry_sleep_seconds`  
  dns dump 暂时拿不到映射时的快速重试参数。

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

然后执行`install_update_all.sh`或者
```bash
sudo systemctl restart tetrablocker
```

程序会自动清理所有 `tb-allowlist-*` TracingPolicy（运行时）和对应 YAML（磁盘），恢复到无 allowlist enforcement 的状态。

> 提示：如果你仍启用了黑名单 rules[]，黑名单阻断仍会生效；如需完全停止阻断，请同时清理 rules[] 或执行`clean-stop`脚本。

### 4) clean-stop：停服务并清理所有自动策略（不影响 tetragon-enterprise）
当你希望立刻停止 tetrablocker，并确保它生成的 TracingPolicy 全部移除（包括运行时已加载的、以及落盘在 policy_dir 的 YAML）时，使用 `clean-stop`：

```bash
chmod +x clean-stop
sudo ./clean-stop
```

行为：
- 停止 `tetrablocker.service`（不停止 `tetragon-enterprise.service`）
- 删除所有匹配指定前缀的 TracingPolicy（默认前缀 `tb-`，可配置）
- 删除 `/etc/tetragon/tetragon.tp.d/` 下匹配前缀的 YAML 文件
- 默认不会修改或删除白名单 allowlist.json（保留你的学习成果）

如果你要做“彻底重置策略状态缓存”（不改 allowlist.json），可以用：

```bash
sudo ./clean-stop --purge-state
```
它删除策略文件时也把一致性哈希缓存清除。

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
学习窗口无法覆盖所有偶发路径（timer、cron、故障恢复、夜间任务）。建议流程（详细见前面获取更完整白名单的最佳实践）：
- 先 learning + 人工 review allowlist
- 再 enforce
- 为关键系统组件（DNS、网络管理、监控 agent）预置 seed allowlist 与 trusted binaries
- 通过 allowlist 的 domain refresh 机制对抗 CDN/IP churn

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
   若允许的二进制被替换为恶意版本，仍会被允许联网。好在Tetragon支持基于eBPF的 FIM 校验（TetraBlocker会在后续版本增加此功能）。

---

## 运维命令速查

```bash
# Logs
sudo journalctl -u tetrablocker -f

# Status
sudo systemctl status tetrablocker --no-pager

# Stop / Start / Restart
sudo systemctl stop tetrablocker
sudo systemctl start tetrablocker
sudo systemctl restart tetrablocker

# List tracing policies
sudo tetra tracingpolicy list

# Show all tracingpolicies content
sudo ./getpolicy.sh 

# Show allowlist
cat /etc/tetrablocker/allowlist.json | sed -n '1,200p'

# Show configuration and denylist
cat /etc/tetrablocker/tetrablocker.conf

# Show generated allowlist/denylist policies
ls -l /etc/tetragon/tetragon.tp.d/tb-*.yaml 2>/dev/null || true
```

---

## Roadmap（可选增强）

- FIM 校验：对 allowlist binary 做哈希/签名校验，防止Binary被替换
- 更强的域名/IP 管理策略：TTL 对齐、IP 变更回收、策略自动拆分与预算提示
- 统一部署/策略治理：分布式集中部署、输出策略摘要、命中统计、审计报告等

