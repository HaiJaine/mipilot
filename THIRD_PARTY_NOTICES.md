# Third-Party Notices

本文件说明 MiPilot 使用或可与其同目录放置的第三方组件。项目根目录的 MIT License 仅适用于本项目原创的管理脚本和文档, 不会将第三方组件重新许可为 MIT。

本项目不在 Git 仓库中提交下列第三方二进制和数据文件。用户需要从上游获取它们; 对其使用和再分发应遵守对应上游许可证。上游仓库中的许可证文本和版权声明为准。

## Mihomo

- 项目: MetaCubeX/mihomo
- 上游仓库: <https://github.com/MetaCubeX/mihomo>
- 发布页: <https://github.com/MetaCubeX/mihomo/releases>
- 完整离线包使用的资产: `mihomo-linux-amd64-v1.19.30.gz`
- MiPilot v1.0.2离线包版本: `v1.19.30`
- 上游提交: `ac017cdd246ce8bd547653d927e7bf77d7ee73d5`
- SHA-256: `cf06ce2c7d1421bdbda14ee4a5b6046672dc35ebf8eecd8e77504ec3c0ed9a84`
- 上游许可证: GNU General Public License v3.0 (GPL-3.0)
- 许可证文本: <https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE>

Mihomo 二进制是独立的第三方程序, 不属于本项目的 MIT 授权范围。

## meta-rules-dat

- 项目: MetaCubeX/meta-rules-dat
- 上游仓库: <https://github.com/MetaCubeX/meta-rules-dat>
- 发布页: <https://github.com/MetaCubeX/meta-rules-dat/releases>
- 本项目使用的资产: `country.mmdb`、`geosite.dat`
- MiPilot v1.0.2离线包上游标签: `latest`, 发布于 `2026-08-19T22:52:31Z`
- 上游提交: `4178770badecb1b349fbcd62c737e0d7a2079729`
- `country.mmdb` SHA-256: `2e81dcd2703da6efa667865a01dc73ec97304d66bc925d67a5d2ffd412291ca2`
- `geosite.dat` SHA-256: `c8d3ec5bb672288a78f8b495d3987b0472bcbdced72b20a486b7afed53b4b0d8`
- 上游许可证: GNU General Public License v3.0 (GPL-3.0)
- 许可证文本: <https://github.com/MetaCubeX/meta-rules-dat/blob/meta/LICENSE>

这些数据文件是独立的第三方资产, 不属于本项目的 MIT 授权范围。数据文件还可能包含或派生自上游声明的其他数据源; 请一并保留并遵守上游仓库提供的归属和许可证信息。

## yq

- 项目: mikefarah/yq
- 上游仓库: <https://github.com/mikefarah/yq>
- 发布页: <https://github.com/mikefarah/yq/releases/tag/v4.53.3>
- 完整离线包使用的资产: `yq_linux_amd64`
- MiPilot v1.0.2离线包版本: `v4.53.3`
- SHA-256: `fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4`
- 上游许可证: MIT License
- 许可证文本: `licenses/yq-MIT.txt`

yq安装在 `/usr/local/lib/mipilot/yq`, 仅供MiPilot内部结构化读取和修改YAML配置, 不替换系统中的同名命令。

## 再分发

如果只发布 MiPilot 源码而不附带上述资产, 请保留本文件和 `.gitignore`, 并引导用户从上游获取文件。

MiPilot v1.0.2完整离线包随附GPL-3.0和yq MIT许可证文本, Release同时提供 `mipilot-v1.0.2-third-party-sources.tar.gz`, 包含上述GPL组件的精确提交源码快照。第三方版权和许可证仍归各上游项目所有。
