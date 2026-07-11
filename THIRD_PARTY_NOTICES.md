# Third-Party Notices

本文件说明 MiPilot 使用或可与其同目录放置的第三方组件。项目根目录的 MIT License 仅适用于本项目原创的管理脚本和文档, 不会将第三方组件重新许可为 MIT。

本项目不在 Git 仓库中提交下列第三方二进制和数据文件。用户需要从上游获取它们; 对其使用和再分发应遵守对应上游许可证。上游仓库中的许可证文本和版权声明为准。

## Mihomo

- 项目: MetaCubeX/mihomo
- 上游仓库: <https://github.com/MetaCubeX/mihomo>
- 发布页: <https://github.com/MetaCubeX/mihomo/releases>
- 本项目使用的资产: `mihomo-linux-amd64-v*.gz`
- 上游许可证: GNU General Public License v3.0 (GPL-3.0)
- 许可证文本: <https://github.com/MetaCubeX/mihomo/blob/Meta/LICENSE>

Mihomo 二进制是独立的第三方程序, 不属于本项目的 MIT 授权范围。

## meta-rules-dat

- 项目: MetaCubeX/meta-rules-dat
- 上游仓库: <https://github.com/MetaCubeX/meta-rules-dat>
- 发布页: <https://github.com/MetaCubeX/meta-rules-dat/releases>
- 本项目使用的资产: `country.mmdb`、`geosite.dat`
- 上游许可证: GNU General Public License v3.0 (GPL-3.0)
- 许可证文本: <https://github.com/MetaCubeX/meta-rules-dat/blob/meta/LICENSE>

这些数据文件是独立的第三方资产, 不属于本项目的 MIT 授权范围。数据文件还可能包含或派生自上游声明的其他数据源; 请一并保留并遵守上游仓库提供的归属和许可证信息。

## 再分发

如果只发布 MiPilot 源码而不附带上述资产, 请保留本文件和 `.gitignore`, 并引导用户从上游获取文件。

如果在源码包、安装包或 Release 中附带 Mihomo 二进制或 meta-rules-dat 数据, 发布者需要自行履行 GPL-3.0 及上游声明的全部再分发义务, 包括保留版权和许可证声明, 随分发物提供对应许可证文本, 并按许可证要求提供相应源码。具体义务以分发时的上游版本和许可证为准。
