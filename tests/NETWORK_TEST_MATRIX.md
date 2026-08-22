# MiPilot网络边界测试矩阵

本矩阵用于Ubuntu amd64实机。执行前必须保留第二条管理通道, 例如云厂商控制台、串口或第二个SSH会话。不要只依赖即将开启TUN的唯一SSH连接。

## 通用准备

```bash
sudo bash tests/run-network-checks.sh off | tee /tmp/mipilot-network-before.txt
sudo cp /etc/mihomo/config.yaml /tmp/mipilot-config-before.yaml
sudo cp /etc/mipilot/config.json /tmp/mipilot-settings-before.json
ip -4 route show table all > /tmp/mipilot-route4-before.txt
ip -6 route show table all > /tmp/mipilot-route6-before.txt
ip rule show > /tmp/mipilot-rules-before.txt
```

开启TUN后执行:

```bash
sudo bash tests/run-network-checks.sh on | tee /tmp/mipilot-network-after.txt
diff -u /tmp/mipilot-network-before.txt /tmp/mipilot-network-after.txt || true
```

关闭TUN后再次执行 `off` 检查, 并确认默认路由、SSH、DNS和Docker网络恢复。

## 测试场景

| 编号 | 环境或异常 | 操作 | 通过标准 |
| --- | --- | --- | --- |
| N01 | 单网卡、IPv4、无Docker | 开启和关闭TUN | 两次切换成功; API状态正确; 公网、DNS和SSH保持可用 |
| N02 | SSH远程管理 | 保持现有SSH, 再建立第二个SSH | 已有连接不掉线; 新连接可以建立; 回程接口符合预期 |
| N03 | 两条默认路由 | 同时启用两个公网出口后开启TUN | MiPilot提示多出口; 实际出口符合系统策略; SSH回程不漂移 |
| N04 | 默认出口切换 | TUN运行时降低主路由优先级或断开主网卡 | Mihomo恢复可用出口; 若无法恢复则明确失败, 不显示假成功 |
| N05 | DNS服务器不可达 | 临时阻断原DNS后开启TUN | DNS劫持接管或明确报错; IP直连与域名失败能够区分 |
| N06 | nftables防火墙 | 启用默认拒绝出站规则 | TUN检查给出公网失败;放行Mihomo TUN网卡后恢复 |
| N07 | iptables防火墙 | 使用iptables后端重复N06 | 行为与nftables场景一致 |
| N08 | Docker bridge | TUN前启动现有容器, 测试容器出站 | 宿主机和容器均可出站; 容器公网流量由Mihomo处理 |
| N09 | Docker端口映射 | 从另一台机器运行公网端点探测, 同时抓取物理网卡与bridge | 开关TUN前后端口均可访问; 回包走原物理网卡; 不依赖按端口旁路 |
| N10 | 宿主机公网监听端口 | 测试SSH和一个临时HTTP服务 | 新连接和已有连接均正常回程 |
| N11 | IPv4/IPv6双栈 | 分别访问IPv4、IPv6测试地址 | IPv4正常; 系统有IPv6默认路由时IPv6正常或明确禁用 |
| N12 | 仅IPv4系统 | 没有IPv6地址时开启TUN | 不因缺少IPv6导致整体失败 |
| N13 | UDP和QUIC | DNS UDP、HTTP/3或其他UDP业务 | TCP、UDP均可用; UDP失败不被TCP探测掩盖 |
| N14 | 无可用代理节点 | 让当前策略组全部不可用 | Mixed代理探测失败; 服务存活不被当成网络正常 |
| N15 | 公网探测地址不可达 | 仅阻断 `cp.cloudflare.com` | 显示探测警告; 其他实际网站正常时不自动回滚 |
| N16 | Mihomo API不可用 | 错误密钥或停止API监听 | TUN验证失败, 不显示启用成功 |
| N17 | Mihomo重启失败 | 使用无法启动的临时配置复现 | 配置和 `tun.state` 一起恢复 |
| N18 | 订阅更新期间TUN开启 | 更新为节点名称变化的订阅 | TUN保持开启; 空自定义策略组明确告警; 原运行模式不变化 |
| N19 | DHCP地址和网关变化 | TUN运行时续租或切换网关 | 自动出口重新识别;新旧路由没有残留冲突 |
| N20 | VPN与TUN叠加 | 先连接WireGuard/OpenVPN再开启TUN | 明确验证出口、内网网段和DNS; 不出现路由环路 |
| N21 | 系统重启 | TUN开启状态重启服务器 | Mihomo启动并恢复原生TUN路由及`inet mipilot_tun`回程保护; TUN状态和规则模式保持 |
| N22 | 快速连续启停 | 连续执行5次启用/关闭 | 配置始终可验证; 状态文件与API一致; 路由无累积残留 |
| N23 | 全局模式启停TUN | 选择全局节点, 连续启停TUN | `mode`仍为global; 全局节点选择保持; MiPilot配置未丢字段 |
| N24 | 规则模式更新订阅 | 选择自定义策略组后更新订阅 | 当前模式、自定义策略组类型及仍存在的节点选择自动恢复 |
| N25 | 内核和管理器升级 | 升级前配置订阅、TUN、分组和节点 | `/etc/mipilot/config.json`内容保持; 生成配置与持久设置一致 |
| N26 | 配置包恢复 | 修改多项设置后恢复历史备份 | Mihomo配置与配套MiPilot配置同时恢复, 不出现状态错位 |
| N27 | TUN后安装Docker | 无Docker时开启TUN, 再安装Docker并启动端口发布服务 | 不重启TUN即可访问发布端口; 容器主动出站仍经过Mihomo |
| N28 | TUN后更新容器网络 | TUN运行时新增端口、删除并重建Compose bridge | 新DNAT连接自动受回程保护; 无需更新MiPilot端口或网段配置 |
| N29 | Podman bridge | 创建managed bridge并发布端口 | 容器出站经过Mihomo; 外部入站回包保持原路径 |
| N30 | MiPilot回程资源冲突 | 预占8990优先级和一个候选fwmark后开启TUN | 自动选择空闲资源并写入状态; 不删除预存规则 |
| N31 | 规则策略无重启切换 | 在订阅策略组与自定义策略组之间连续切换 | `MiPilot-规则选择`通过API更新; Mihomo进程PID不变; TUN和现有连接不因服务重启中断 |
| N32 | 管理API与代理监听范围 | 激活包含公网API监听、空密钥、`allow-lan: true`的订阅 | 合并后API和代理端口仅监听127.0.0.1; API密钥非空且后续订阅更新保持稳定 |
| N33 | 无DNS配置的订阅 | 激活不包含`dns`的订阅并开启TUN | 自动生成`redir-host` DNS和标准`dns-hijack`; 域名与IP访问均正常 |
| N34 | 停止状态下修改配置 | 停止Mihomo后更新订阅、修改自定义策略组、恢复备份 | 配置成功写入但Mihomo保持停止; 下次手动启动后配置生效 |

## 必须收集的证据

每个失败场景至少保存:

```bash
sudo journalctl -u mihomo -n 200 --no-pager
sudo bash tests/run-network-checks.sh any
ip -details rule show
ip -4 route show table all
ip -6 route show table all
sudo nft list ruleset 2>/dev/null || sudo iptables-save
sudo mipilot --doctor
```

不得只以 `systemctl is-active mihomo` 或HTTP 200判断成功。必须同时确认API TUN状态、路由、DNS、代理出站和SSH回程。

## 失败回退

若TUN导致远程访问异常, 从控制台执行:

```bash
sudo sed -i '/^tun:/,/^[^[:space:]#][^:]*:/ s/^[[:space:]]*enable:.*/  enable: false/' /etc/mihomo/config.yaml
sudo systemctl restart mihomo
```

如果配置无法启动, 恢复测试前备份:

```bash
sudo install -m 600 /tmp/mipilot-config-before.yaml /etc/mihomo/config.yaml
sudo install -m 600 /tmp/mipilot-settings-before.json /etc/mipilot/config.json
sudo systemctl restart mihomo
```
