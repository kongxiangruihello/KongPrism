# KongPrism

macOS 菜单栏代理客户端，内核为 [sing-box](https://github.com/SagerNet/sing-box)。
名字取“棱镜”之意：一束流量进来，按规则分成几路出去。属于 kong 系列 App。

## 功能

| | |
|---|---|
| 订阅 | Clash / Mihomo YAML、sing-box JSON、Base64、节点链接；显示已用流量和到期日；定时自动更新；流量将尽 / 快到期时菜单提醒；可合并多个订阅 |
| 方便导入 | 机场网页“一键导入 Clash / sing-box”直接唤起 KongPrism；打开菜单即识别剪贴板里的订阅地址、节点或二维码截图；拖入文件/链接；从文件导入 |
| 协议 | Shadowsocks（含 2022、obfs / v2ray-plugin）、VMess、VLESS（Vision / Reality）、Trojan、Hysteria2（端口跳跃）、TUIC、AnyTLS、SOCKS5 |
| 传输 | TCP、WebSocket（含 early data）、gRPC、HTTP/2、HTTPUpgrade |
| 分流 | 规则 / 全局 / 直连；国内域名直连、国外域名走代理、未知域名按 IP 归属分流、广告拦截、自定义直连/代理域名 |
| 节点 | 自动选择最快节点；按地区自动分组；菜单里一键测速、切换 |
| 在线更新 | App 本体、sing-box 内核、规则集、订阅，全部可在 App 内更新，下载优先走自身代理 |
| 其他 | 登录时启动、局域网共享、复制终端代理命令、崩溃后自动恢复系统代理 |

## 安装

在 Mac 上把仓库克隆到本地，双击 **`构建并安装.command`**：它会下载并校验 sing-box 内核、运行单元测试
（包括用真实 sing-box 检查生成的配置）、编译并安装到“应用程序”文件夹。需要 Xcode 或 Command Line Tools。

也可以从 GitHub Actions / Releases 下载编好的 `KongPrism-x.y.z.zip`。

## 使用

添加订阅，任选一种：

- 在机场网页点 **“一键导入 Clash”或“导入到 sing-box”**，确认后即添加并连接（`clash://`、`sing-box://`、`kongprism://` 链接）。
  若点了没反应或打开了别的客户端：设置 › 订阅 › “让网页‘一键导入’打开 KongPrism”。
- **复制订阅地址**，再点菜单栏图标，最上面会出现“📋 添加剪贴板中的订阅”，点一下即可（⌥ 可忽略）。
- 网页只给了**二维码**：⌃⇧⌘4 截图到剪贴板，再打开菜单，同样会识别。
- 把 Clash / sing-box 配置文件、二维码图片或订阅链接**拖进**设置 › 订阅 的列表。

第一个订阅添加后会自动开启代理。之后在“节点”子菜单里切换节点或测速；在“出站模式”里切换规则 / 全局 / 直连。
首次开启可能要求输入管理员密码以修改系统代理。
3. 在“节点”子菜单里切换节点或测速；在“出站模式”里切换规则 / 全局 / 直连。

终端走代理：菜单 › 复制终端代理命令，粘贴到终端即可。

## 在线更新的工作方式

| 组件 | 来源 | 校验 | 频率 |
|---|---|---|---|
| KongPrism | 本仓库 GitHub Releases 中的 `latest.json` + zip | SHA-256、签名、Bundle ID | 每天检查，手动安装 |
| sing-box 内核 | SagerNet/sing-box 官方 Release | 能运行 + 用当前配置 `check` 通过才替换；保留上一个版本可回退 | 每天检查，手动安装 |
| 规则集 | SagerNet/sing-geosite、sing-geoip（GitHub → jsDelivr 备用） | 文件头 `SRS` | 每周自动 |
| 订阅 | 机场 | 能解析出节点才替换 | 6 小时 – 3 天，可选 |

**发布新版本**：把 `Resources/Info.plist` 里的 `CFBundleShortVersionString` 改成新版本号，在 `CHANGELOG.md` 写上 `## 新版本号` 一节，推送到 main。
GitHub Actions 会编译、测试、打包，并发布带 `latest.json` 的 Release（该版本已发布过则跳过），已安装的 KongPrism 随即能检测到。

> 仓库现为公开，App 更新无需令牌。若改回私有，需在 设置 › 更新 里填写 GitHub 令牌（fine-grained token，只勾选本仓库的 Contents: Read-only）。

## 省电设计

- 默认用**系统代理**而非 TUN：只有遵循系统代理的流量经过内核。
- 自动选择组设置 `idle_timeout`：分组不被使用时停止后台测速。
- 菜单只在打开时向内核取一次数据；后台没有轮询和计时器。
- 订阅、规则、更新检查交给 `NSBackgroundActivityScheduler`，由 macOS 合并唤醒、低电量时推迟。
- 内核日志级别 `warn` 并直接写文件；规则集是本地二进制文件，更新后内核自动重载，不必重启。
- 只在节点真的变化时才重启内核。

## 目录

```
Sources/KongPrismCore   订阅解析、节点链接、Clash YAML、sing-box 配置生成（纯 Foundation，有单元测试）
Sources/KongPrism       菜单栏 App：内核进程、系统代理、Clash API、设置窗口、在线更新
Resources/rules         内置规则集（geosite-cn、geosite-geolocation-!cn、广告、geoip-cn）
scripts/                download-core.sh（固定版本 + SHA-256）、build-app.sh
```

数据位于 `~/Library/Application Support/KongPrism`（订阅、规则、下载的内核、日志）。

## 许可

sing-box 以 GPL-3.0 发布，作为独立进程随 App 分发，许可证见 `LICENSE-sing-box.txt`。
