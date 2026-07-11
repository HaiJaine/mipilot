# Third-Party Notices

本文件说明 MiPilot 使用或可与其同目录放置的第三方组件。项目根目录的 MIT License 仅适用于本项目原创的管理脚本和文档, 不会将第三方组件重新许可为 MIT。

本项目不在 Git 仓库中提交下列第三方二进制和数据文件。用户需要从上游获取它们; 对其使用和再分发应遵守对应上游许可证。上游仓库中的许可证文本和版权声明为准。

## Mihomo

- 项目: MetaCubeX/mihomo
- 上游仓库: <https://github.com/MetaCubeX/mihomo>
- 发布页: <https://github.com/MetaCubeX/mihomo/releases>
- 本项目使用的资产: `mihomo-linux-amd64-v*.gz`
- MiPilot v1.0.0离线包版本: `v1.19.28`
- 上游提交: `cbd11db1e13a75d8e680e0fe7742c95be4cba2be`
- SHA-256: `d5967e079d9f793515a5a8193aabda455f7e012427eccd567dbc4f2f15498204`
- 上游许可证: GNU General Public License v3.0 (GPL-3.0)
- 许可证文本: <https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE>

Mihomo 二进制是独立的第三方程序, 不属于本项目的 MIT 授权范围。

## meta-rules-dat

- 项目: MetaCubeX/meta-rules-dat
- 上游仓库: <https://github.com/MetaCubeX/meta-rules-dat>
- 发布页: <https://github.com/MetaCubeX/meta-rules-dat/releases>
- 本项目使用的资产: `country.mmdb`、`geosite.dat`
- MiPilot v1.0.0离线包上游标签: `latest`, 发布于 `2026-07-10T23:28:50Z`
- 上游提交: `4178770badecb1b349fbcd62c737e0d7a2079729`
- `country.mmdb` SHA-256: `3256b2ba2d8f75778fab6fe4e0e1c77ccffbd8774aab8e577251f3803ad95b49`
- `geosite.dat` SHA-256: `cb77421b5ebe0b786d4bce7cb100c532b28ffc0e7b46d7181cd63139433f4526`
- 上游许可证: GNU General Public License v3.0 (GPL-3.0)
- 许可证文本: <https://github.com/MetaCubeX/meta-rules-dat/blob/meta/LICENSE>

这些数据文件是独立的第三方资产, 不属于本项目的 MIT 授权范围。数据文件还可能包含或派生自上游声明的其他数据源; 请一并保留并遵守上游仓库提供的归属和许可证信息。

## 再分发

如果只发布 MiPilot 源码而不附带上述资产, 请保留本文件和 `.gitignore`, 并引导用户从上游获取文件。

MiPilot v1.0.0完整离线包随附GPL-3.0许可证文本, Release同时提供 `mipilot-v1.0.0-third-party-sources.tar.gz`, 包含上述两个精确提交的源码快照。第三方版权和许可证仍归各上游项目所有。
