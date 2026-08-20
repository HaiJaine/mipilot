# MiPilot

当前版本: `1.0.1`, 配置持久化、TUN和规则分组修复版本。

MiPilot 取意于“Mihomo + Pilot”, 是面向 Ubuntu 的 Mihomo 一键安装与维护工具。首次执行时可完全使用本地的 Mihomo 内核和地理数据完成安装; 安装完成后通过 `mipilot` 管理订阅、节点、TUN、终端代理、服务、更新、备份和卸载。

## 安装

### 使用完整离线包

从 [MiPilot v1.0.1 Release](https://github.com/HaiJaine/mipilot/releases/tag/v1.0.1) 下载:

```text
mipilot-v1.0.1-linux-amd64-offline.tar.gz
SHA256SUMS
```

校验、解压并安装:

```bash
sha256sum -c SHA256SUMS --ignore-missing
tar -xzf mipilot-v1.0.1-linux-amd64-offline.tar.gz
cd mipilot-v1.0.1
bash ./mipilot
```

完整离线包解压后就是可直接安装的完整项目目录, 包含管理脚本、测试文件、许可证、Mihomo上游原始资产 `mihomo-linux-amd64-v1.19.30.gz`、`country.mmdb` 和 `geosite.dat`。首次安装这些组件不需要访问GitHub。

### 克隆源码安装

```bash
git clone https://github.com/HaiJaine/mipilot.git
cd mipilot
```

从可信设备下载以下 3 个文件, 再复制到 `mipilot` 项目根目录:

```text
country.mmdb
geosite.dat
mihomo-linux-amd64-v1.19.30.gz
```

确认 3 个文件与脚本位于同一目录:

```bash
ls -lh mipilot country.mmdb geosite.dat mihomo-linux-amd64-v1.19.30.gz
bash ./mipilot
```

Git仓库不会提交这3个第三方大文件。它们可以从 [Mihomo v1.19.30](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30) 和 [meta-rules-dat Releases](https://github.com/MetaCubeX/meta-rules-dat/releases) 获取; GitHub无法访问时也可以在其他设备下载后传入服务器。

安装完成后执行:

```bash
source ~/.bashrc
mipilot
```

## 支持范围

- Ubuntu 20.04 或更高版本.
- amd64/x86_64 架构.
- systemd.
- Bash. 请使用 `bash mipilot`, 不支持 `sh mipilot`.
- 当前用户可使用 `sudo`.

其他 Linux 发行版和 arm64 暂不在首版支持范围内。

## 首次安装流程

完整离线包已经把以下文件放在同一个目录:

```text
mipilot
country.mmdb
geosite.dat
mihomo-linux-amd64-v1.19.30.gz
```

文件用途:

| 文件 | 安装位置 | 来源 |
| --- | --- | --- |
| `mihomo-linux-amd64-v1.19.30.gz` | `/usr/local/bin/mihomo` | 完整离线包内置的上游原始资产, 安装时校验并解压 |
| `country.mmdb` | `/etc/mihomo/Country.mmdb` | [MetaCubeX/meta-rules-dat Releases](https://github.com/MetaCubeX/meta-rules-dat/releases) |
| `geosite.dat` | `/etc/mihomo/GeoSite.dat` | [MetaCubeX/meta-rules-dat Releases](https://github.com/MetaCubeX/meta-rules-dat/releases) |

以普通用户执行脚本, 并按提示授权 `sudo`:

```bash
bash ./mipilot
```

安装向导会依次完成:

1. 检查 Ubuntu 版本、amd64 架构、Bash、systemd 和 sudo.
2. 检查所需系统命令. 缺少依赖时, 经确认后尝试使用 APT 安装; 单个第三方软件源更新失败时仍会继续尝试从可用索引安装依赖.
3. 校验本地 Mihomo 文件、临时内核版本、地理数据和生成配置.
4. 选择运行方式. 默认是手动模式; 只有明确输入 `y` 才安装并启用 systemd 服务.
5. 安装 Mihomo、地理数据、安全的初始直连配置、管理脚本和 `mipilot` 命令.
6. 服务模式会立即启动并可选添加首个订阅; 手动模式安装后保持停止, 进入 `mipilot` 启动后再管理订阅.

完成后在当前终端执行:

```bash
source ~/.bashrc
mipilot
```

初始配置关闭 TUN, 控制 API 仅监听本机, 且不包含代理节点。

手动模式不会创建 `mihomo.service`, 也不会开机自启。用户仍通过 `mipilot` 启动和停止 Mihomo; 管理器会使用 `sudo` 启动进程, 因此开启 TUN 时仍具备所需网络权限。手动模式日志保存在 `/var/lib/mipilot/mihomo.log`, PID 文件保存在 `/run/mipilot/mihomo.pid`。可在“运行维护”中随时切换手动模式和 systemd 服务模式。

MiPilot 将用户设置统一保存在 `/etc/mipilot/config.json`, 权限为 `600`。该文件是订阅、运行模式、TUN、地区分组和节点选择的持久状态源; `/etc/mihomo/config.yaml` 是合并订阅与这些设置后生成的 Mihomo 运行配置。已有安装首次启动新版管理器时, 会自动从旧状态文件迁移并保留旧文件作为派生兼容数据。

离线资产可以避免首次安装访问 GitHub, 但不能替代系统依赖。如果系统缺少依赖且 APT 也不可用, 安装会在写入系统文件前停止并显示缺失清单。请先从可信来源准备依赖和 3 个离线资产; 首次安装不附带上游签名或可信摘要时, 完整性检测不能替代来源真实性校验。

## 启动时的安装状态

同一个脚本会根据环境进入对应流程:

| 状态 | 行为 |
| --- | --- |
| 全新环境 | 直接进入首次安装向导. |
| 已有但未受管的 Mihomo | 可接管现有安装, 或使用本地离线包重新安装. |
| 部分安装 | 显示缺失组件并进入修复流程. |
| 已受管安装 | 提示使用 `mipilot`; 项目目录中的脚本较新时可执行本地管理器升级. |

使用离线包重新安装已有环境时, 可以选择保留现有配置、订阅和节点, 或先备份再重置为初始直连配置。脚本会先完成离线包校验, 再替换现有受管服务和组件。

安装或升级会移除旧的 `mihomo_menu` Shell 集成, 并统一使用 `mipilot`。

## 日常管理

执行:

```bash
mipilot
```

主菜单提供运行状态、订阅管理、节点管理、规则/全局/直连模式、终端代理、TUN 和服务维护等功能。通过 `.bashrc` 中的受管 `mipilot` 函数进入菜单时, 终端代理开关可以立即作用于当前 Shell。

地区分组管理与节点管理相互独立。地区分组管理可以自动生成常用地区组, 也可以将日本、新加坡等多个地区组合成一个自定义 `MiPilot-` 分组。创建后可以查看实际匹配节点、修改自动测速/故障回退/负载均衡/手动选择策略或删除分组; 旧版已保存分组继续按自动测速处理。规则模式只把订阅规则实际引用的手动策略组视为原生规则入口, 节点管理会显示该入口下的订阅分组和 `MiPilot-` 自定义分组; 全局模式只显示并切换具体代理节点。订阅没有被规则引用的手动策略组时, MiPilot会创建自己的兜底规则出口并接管最终 `MATCH` 规则, 自定义地区分组不再依赖订阅的 Selector。这个兜底出口不会改写更早命中的订阅规则。订阅更新后会按新节点重新生成地区分组; 新订阅恢复明确的原生规则入口时会优先回挂原生入口, 无法唯一确认入口时迁移到MiPilot兜底规则出口。

下载、测速、配置验证、TUN切换、服务操作和更新等耗时任务会显示动态进度与等待时间。可安全取消的阶段支持Esc; 配置替换、服务重启、路由修改和回滚阶段会明确显示“不可中断”。

### TUN与公网服务兼容

开启TUN时, MiPilot使用Mihomo原生的 `auto-route: true` 和 `auto-detect-interface: true`, 并关闭 `auto-redirect`。MiPilot在独立的 `inet mipilot_tun` nftables表中按conntrack连接方向标记DNAT入站连接, 再通过优先于Mihomo的受管 `ip rule` 让对应回包查询main表。Docker或Podman容器主动访问互联网仍然进入TUN; 外部访问标准bridge端口发布产生的回包保持原物理网络路径。该机制不扫描监听端口, 不依赖Docker是否已安装、容器网段、网桥名称或服务启动顺序, 因此开启TUN后再安装Docker、创建网络或发布新端口不需要重新配置MiPilot。

MiPilot会在 `/var/lib/mipilot/tun-routing.state` 保存自己分配的规则优先级和连接标记, 启停时只操作该状态对应的规则。已占用的候选优先级和连接标记会被跳过; 若同名nftables表没有受管状态或全部候选资源均不可用, TUN启动会失败并保留原配置。服务模式通过Mihomo unit的启动前和停止后动作恢复、清理规则; 手动模式在Mihomo进程启动前同步规则。两种入口使用独立文件锁串行修改TUN路由状态, 运行检查同时验证nftables链内的连接方向和mark规则, 缺失时会重新建立。启用后会检查Mihomo API、TUN回程规则、IPv4路由、当前SSH客户端回程和公网连通性。运行维护中的“网络兼容性检查”或 `sudo mipilot --doctor` 可以只读查看默认路由、相关虚拟接口、受管规则、nftables表和本地DNS监听。

首版自动兼容范围是Ubuntu上的标准Docker/Podman bridge与DNAT端口发布。`macvlan`、`ipvlan`、Kubernetes CNI/IPVS/eBPF、Docker IPv6 direct-routing、多个全局VPN和多公网出口不会被假定为已兼容; MiPilot只提示已发现的隧道和多默认路由, 这些环境仍需按实际链路验证。

升级会清理旧版 `tun-bypass-ports.conf`、`mipilot-tun-bypass.service` 以及状态文件中已记录端口对应的旧规则。旧状态文件已经丢失时不会按端口盲目删除系统策略路由, 需要管理员结合实际规则手动确认。

### 订阅与节点

- 切换并更新订阅会整体替换旧订阅节点, 同时重新合并已明确保存的本机设置.
- 删除非当前订阅时, 只删除该订阅地址.
- 删除当前订阅时, 可以保留现有节点并冻结当前配置, 也可以清理所有节点并恢复安全的直连配置.
- 清理所有节点会关闭 TUN 和终端代理, 清除当前订阅标记与地区组状态, 但保留其他订阅地址.
- 配置变更会先备份和验证; 验证或服务重启失败时自动恢复原配置与相关状态.

### 配置备份

所有配置备份统一位于 `/etc/mihomo/backups`, 合计只保留最新 3 组, 权限为 `600`。每组同时包含 Mihomo 运行配置和对应的 MiPilot 持久配置, 恢复时会作为一个整体处理。旧式 `config.yaml.bak.*` 文件在接管时会迁移并按同一上限清理; 旧备份没有配套MiPilot配置时, 仍可按兼容模式仅恢复运行配置。

### 运行维护

```text
1) 验证配置并重启 Mihomo
2) 启动/停止 Mihomo
3) 查看最近日志
4) 查看内核与数据版本
5) 更新与版本回退
6) 配置备份与恢复
7) 生成脱敏诊断报告
8) 修复或重新安装
9) 切换手动/系统服务模式
10) 卸载
0) 返回
```

诊断报告会隐藏订阅完整 URL、API 密钥和节点认证信息, 仅保留版本、服务状态、配置验证结果、端口和脱敏日志。分享前仍建议自行复核报告内容。

## 更新与回退

在 `mipilot` 中依次进入“服务维护”与“更新与版本回退”:

```text
1) 在线更新全部组件
2) 在线更新 MiPilot 管理器
3) 在线更新 Mihomo 内核
4) 在线更新 Country.mmdb 和 GeoSite.dat
5) 使用本地文件更新
6) 回退最近一次更新
7) 显示手动下载说明
0) 返回
```

在线更新只跟踪 Mihomo 稳定版。下载统一使用普通 `curl`, 不主动判断或指定代理; 实际网络路径由当前TUN、代理环境变量或系统路由决定。下载和校验全部完成后才会停止服务并替换组件, 新版本验证或启动失败时会自动恢复旧组件。订阅更新会重新合并MiPilot中保存的运行模式、TUN和自定义地区分组, 并恢复新订阅中仍然存在的策略组及节点选择。

在线更新不可用时:

1. 在可联网的设备上打开 [Mihomo 最新稳定版](https://github.com/MetaCubeX/mihomo/releases/latest), 下载名称严格匹配 `mihomo-linux-amd64-v*.gz` 的资产. 手动更新和完整离线包均使用该上游原始压缩文件.
2. 打开 [meta-rules-dat 最新版](https://github.com/MetaCubeX/meta-rules-dat/releases/latest), 下载 `country.mmdb` 和 `geosite.dat`.
3. 将文件复制到任意目录. 默认可放回 `mipilot` 所在目录.
4. 在更新菜单选择“使用本地文件更新”, 使用默认当前目录或输入文件所在目录.

在线更新会使用上游提供的 SHA-256 摘要。使用本地文件更新时, 请先自行确认文件来源; 脚本仍会执行包完整性、版本、数据加载、配置和服务验证。

每类组件只保留最近一个旧版本用于人工回退, 存放在 `/var/lib/mipilot/rollback`, 72 小时后自动清理。该回退区不计入配置备份的 3 份上限, 也不会删除项目目录中由用户保存的离线包。

MiPilot管理器只在用户从菜单手动选择时检查更新, 不在启动时联网。更新固定使用本项目最新稳定Release中的 `mipilot` 和 `mipilot.sha256`, 通过SHA-256、Bash语法和稳定版本号验证后原子替换; 失败自动恢复原脚本。更新成功后需要退出当前菜单并重新执行 `mipilot`。管理器旧版本与内核、地理数据一样保留72小时用于回退。

## 卸载

从“服务维护”菜单选择“卸载”后有两种模式:

- 卸载程序并保留 `/etc/mihomo` 和 `/etc/mipilot` 配置, 方便以后恢复.
- 彻底卸载, 删除 Mihomo 内核、受管服务、配置、订阅、备份、回退区、管理器、Shell 集成和用户代理状态.

彻底卸载必须输入 `UNINSTALL` 确认。卸载不会删除当前项目目录及其中的离线包, 也不会卸载 `curl`、`jq` 等系统共享依赖。

## 安装路径

| 内容 | 路径 |
| --- | --- |
| Mihomo 内核 | `/usr/local/bin/mihomo` |
| 配置与地理数据 | `/etc/mihomo` |
| MiPilot 持久配置 | `/etc/mipilot/config.json` |
| 配置备份 | `/etc/mihomo/backups` |
| 管理器 | `/usr/local/lib/mipilot/mipilot` |
| 管理命令 | `/usr/local/bin/mipilot` |
| systemd 服务(选择服务模式时) | `/etc/systemd/system/mihomo.service` |
| 手动模式日志 | `/var/lib/mipilot/mihomo.log` |
| 手动模式 PID | `/run/mipilot/mihomo.pid` |
| 更新回退区与安装状态 | `/var/lib/mipilot` |
| 当前用户的终端代理状态 | `~/.config/mipilot` |

安装、更新、恢复和卸载使用互斥锁, 同一时间只允许一个变更操作运行。

## 开发与测试

项目布局:

```text
mipilot/
├── mipilot
├── README.md
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── .gitattributes
├── .gitignore
└── tests/
```

运行语法检查和模拟测试:

```bash
bash -n mipilot
bash tests/run-tests.sh
```

模拟测试不会写入真实系统目录。涉及TUN、Docker公网端口、nftables和systemd的行为应在受支持的Ubuntu amd64环境中验证。TUN兼容层需要 `nft` 命令, 首次安装缺失时会通过APT安装 `nftables`。实机验证前后可以执行只读网络检查:

```bash
sudo bash tests/run-network-checks.sh off
# 通过mipilot开启TUN后
sudo bash tests/run-network-checks.sh on
```

单网卡、多网卡、SSH、Docker、IPv6、防火墙和断网恢复场景见 `tests/NETWORK_TEST_MATRIX.md`。

## 许可证

本项目原创代码和文档以 [MIT License](LICENSE) 发布。Mihomo内核以及meta-rules-dat数据不属于本项目的MIT授权范围; 其来源和再分发说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。第三方资产不进入Git仓库; 完整离线Release另行附带对应源码包和GPL-3.0许可证文本。
