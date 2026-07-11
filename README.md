# MiPilot

当前版本: `1.0.0-dev`。项目仍处于首个正式版本发布前的开发和验收阶段, 尚未发布稳定版。

MiPilot 取意于“Mihomo + Pilot”, 是面向 Ubuntu 的 Mihomo 一键安装与维护工具。首次执行时可完全使用本地的 Mihomo 内核和地理数据完成安装; 安装完成后通过 `mipilot` 管理订阅、节点、TUN、终端代理、服务、更新、备份和卸载。

## 开发版安装

```bash
git clone https://github.com/HaiJaine/mipilot.git
cd mipilot
```

从可信设备下载以下 3 个文件, 再复制到 `mipilot` 项目根目录:

```text
country.mmdb
geosite.dat
mihomo-linux-amd64-v1.19.28.gz
```

确认 3 个文件与脚本位于同一目录:

```bash
ls -lh mipilot country.mmdb geosite.dat mihomo-linux-amd64-v1.19.28.gz
bash ./mipilot
```

Git 仓库不会提交这 3 个第三方大文件。它们可以从 [Mihomo v1.19.28](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.28) 和 [meta-rules-dat Releases](https://github.com/MetaCubeX/meta-rules-dat/releases) 获取; GitHub 无法访问时也可以在其他设备下载后传入服务器。

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

将以下 4 个文件放在同一个目录:

```text
mipilot
country.mmdb
geosite.dat
mihomo-linux-amd64-v1.19.28.gz
```

文件用途:

| 文件 | 安装位置 | 来源 |
| --- | --- | --- |
| `mihomo-linux-amd64-v1.19.28.gz` | `/usr/local/bin/mihomo` | [MetaCubeX/mihomo Releases](https://github.com/MetaCubeX/mihomo/releases) |
| `country.mmdb` | `/etc/mihomo/Country.mmdb` | [MetaCubeX/meta-rules-dat Releases](https://github.com/MetaCubeX/meta-rules-dat/releases) |
| `geosite.dat` | `/etc/mihomo/GeoSite.dat` | [MetaCubeX/meta-rules-dat Releases](https://github.com/MetaCubeX/meta-rules-dat/releases) |

以普通用户执行脚本, 并按提示授权 `sudo`:

```bash
bash ./mipilot
```

安装向导会依次完成:

1. 检查 Ubuntu 版本、amd64 架构、Bash、systemd 和 sudo.
2. 检查所需系统命令. 缺少依赖时, 经确认后尝试使用 APT 安装.
3. 校验本地 gzip、临时内核版本、地理数据和生成配置.
4. 安装 Mihomo、地理数据、安全的初始直连配置和 systemd 服务.
5. 安装管理脚本与 `mipilot`, 并写入受管的 Bash 集成区块.
6. 可选添加首个订阅. 跳过或订阅下载失败时, Mihomo 仍以直连配置完成安装.

完成后在当前终端执行:

```bash
source ~/.bashrc
mipilot
```

初始配置关闭 TUN, 控制 API 仅监听本机, 且不包含代理节点。

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

下载、测速、配置验证、TUN切换、服务操作和更新等耗时任务会显示动态进度与等待时间。可安全取消的阶段支持Esc; 配置替换、服务重启、路由修改和回滚阶段会明确显示“不可中断”。

### TUN与公网服务兼容

开启TUN时, MiPilot使用 `auto-route: true` 和服务器兼容性更好的 `auto-redirect: false`, 并自动扫描Docker公开端口以及监听在所有地址上的TCP/UDP服务端口, 为这些端口的返回流量添加优先于Mihomo TUN的主路由规则。例如Docker公开 `8080` 后会生成 `ipproto tcp sport 8080 lookup main`, 防止外部请求从公网网卡进入、返回包却被TUN接管。普通外连使用随机源端口, 仍按Mihomo规则经过TUN。

端口列表保存于 `/etc/mihomo/tun-bypass-ports.conf`, 系统启动时由 `mipilot-tun-bypass.service` 恢复。每次开启TUN或进入MiPilot菜单时会重新扫描, 关闭TUN和卸载时会删除对应策略规则。

### 订阅与节点

- 切换并更新订阅会整体替换旧订阅节点, 同时重新合并已明确保存的本机设置.
- 删除非当前订阅时, 只删除该订阅地址.
- 删除当前订阅时, 可以保留现有节点并冻结当前配置, 也可以清理所有节点并恢复安全的直连配置.
- 清理所有节点会关闭 TUN 和终端代理, 清除当前订阅标记与地区组状态, 但保留其他订阅地址.
- 配置变更会先备份和验证; 验证或服务重启失败时自动恢复原配置与相关状态.

### 配置备份

所有配置备份统一位于 `/etc/mihomo/backups`, 合计只保留最新 3 份, 权限为 `600`。备份管理可以查看时间和原因, 并恢复指定版本。旧式 `config.yaml.bak.*` 文件在接管时会迁移并按同一上限清理。

### 服务维护

```text
1) 验证配置并重启服务
2) 启动/停止服务
3) 查看服务日志
4) 查看内核与数据版本
5) 更新与版本回退
6) 配置备份与恢复
7) 生成脱敏诊断报告
8) 修复或重新安装
9) 卸载
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

在线更新只跟踪 Mihomo 稳定版。下载统一使用普通 `curl`, 不主动判断或指定代理; 实际网络路径由当前TUN、代理环境变量或系统路由决定。下载和校验全部完成后才会停止服务并替换组件, 新版本验证或启动失败时会自动恢复旧组件。

在线更新不可用时:

1. 在可联网的设备上打开 [Mihomo 最新稳定版](https://github.com/MetaCubeX/mihomo/releases/latest), 下载名称严格匹配 `mihomo-linux-amd64-v*.gz` 的资产.
2. 打开 [meta-rules-dat 最新版](https://github.com/MetaCubeX/meta-rules-dat/releases/latest), 下载 `country.mmdb` 和 `geosite.dat`.
3. 将文件复制到任意目录. 默认可放回 `mipilot` 所在目录.
4. 在更新菜单选择“使用本地文件更新”, 使用默认当前目录或输入文件所在目录.

在线更新会使用上游提供的 SHA-256 摘要。使用本地文件更新时, 请先自行确认文件来源; 脚本仍会执行包完整性、版本、数据加载、配置和服务验证。

每类组件只保留最近一个旧版本用于人工回退, 存放在 `/var/lib/mipilot/rollback`, 72 小时后自动清理。该回退区不计入配置备份的 3 份上限, 也不会删除项目目录中由用户保存的离线包。

MiPilot管理器只在用户从菜单手动选择时检查更新, 不在启动时联网。更新固定使用本项目最新稳定Release中的 `mipilot` 和 `mipilot.sha256`, 通过SHA-256、Bash语法和稳定版本号验证后原子替换; 失败自动恢复原脚本。更新成功后需要退出当前菜单并重新执行 `mipilot`。管理器旧版本与内核、地理数据一样保留72小时用于回退。

## 卸载

从“服务维护”菜单选择“卸载”后有两种模式:

- 卸载程序并保留 `/etc/mihomo` 配置, 方便以后恢复.
- 彻底卸载, 删除 Mihomo 内核、受管服务、配置、订阅、备份、回退区、管理器、Shell 集成和用户代理状态.

彻底卸载必须输入 `UNINSTALL` 确认。卸载不会删除当前项目目录及其中的离线包, 也不会卸载 `curl`、`jq` 等系统共享依赖。

## 安装路径

| 内容 | 路径 |
| --- | --- |
| Mihomo 内核 | `/usr/local/bin/mihomo` |
| 配置与地理数据 | `/etc/mihomo` |
| 配置备份 | `/etc/mihomo/backups` |
| 管理器 | `/usr/local/lib/mipilot/mipilot` |
| 管理命令 | `/usr/local/bin/mipilot` |
| systemd 服务 | `/etc/systemd/system/mihomo.service` |
| TUN公网服务保护 | `/etc/systemd/system/mipilot-tun-bypass.service` |
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
├── .gitignore
└── tests/
```

运行语法检查和模拟测试:

```bash
bash -n mipilot
bash tests/run-tests.sh
```

模拟测试不会写入真实系统目录。正式发布前仍应在 Ubuntu amd64 虚拟机中完成离线安装、订阅、TUN、更新回退和彻底卸载验收。

## 许可证

本项目原创代码和文档以 [MIT License](LICENSE) 发布。Mihomo 内核以及 meta-rules-dat 数据不属于本项目的 MIT 授权范围; 其来源和再分发说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。第三方资产由使用者自行下载, 且已被 `.gitignore` 排除。
