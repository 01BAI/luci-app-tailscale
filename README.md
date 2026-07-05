# luci-app-tailscale

OpenWrt / iStoreOS 上的 **Tailscale LuCI 图形界面插件**。在路由器 Web 界面完成 Tailscale 安装、登录、连接设置与状态查看，无需 SSH 手工敲命令。

本仓库独立维护：`tailscaled` 由 GitHub Actions 从 [Tailscale 官方源码](https://github.com/tailscale/tailscale) 交叉编译，发布到**本仓库 Releases**；LuCI 页面从 Release 下载安装，不依赖第三方 Tailscale 打包项目。

---

## 功能概览

| 能力 | 说明 |
|------|------|
| 图形化安装 | 页面一键安装 / 重装 / 卸载 `tailscaled` |
| 登录与状态 | 登录链接、Tailnet IP、节点列表、启停总开关 |
| 连接设置 | 接受路由、宣告子网、Netfilter 模式、出口节点等，保存到 `tailscale_up.conf` |
| LAN 子网访问 | 可选 UCI NAT 规则，让 LAN 内无 Tailscale 客户端的设备访问远端子网 |
| 中文界面 | 文案内置，无需单独语言包 |

安装 LuCI 插件后，打开 **VPN → Tailscale**：

1. 点击「安装 / 重装」下载并启动 `tailscaled`
2. 点击「登录」完成 Tailscale 认证
3. 配置连接参数，点「保存并应用」
4. 用右上角「启用 / 停用」控制服务

> 登录后**不会**自动应用连接设置（避免出口节点等导致 LAN 失联），需手动点「保存并应用」。

---

## 安装

在路由器 **SSH** 中执行一行命令即可：

```sh
curl -fsSL https://raw.githubusercontent.com/01BAI/luci-app-tailscale/main/scripts/install-luci-app.sh | sh
```

脚本会自动：更新软件源 → 安装依赖 → 从 GitHub Release 下载**正式版** ipk（`luci-v1.0.0`）→ 安装 `luci-app-tailscale`。

> 一行命令默认安装正式版，非 `luci-latest` 开发版。维护者测试开发版可加参数：`… | sh -s -- --tag=luci-latest`

安装完成后浏览器打开 LuCI：**VPN → Tailscale**，在页面里安装 Tailscale 二进制并登录。

**首次使用前**，维护者需在 GitHub 运行一次 Actions：**Actions → Build tailscaled for OpenWrt → Run workflow**，生成 Release 后路由器才能下载 `tailscaled` 二进制。

---

## 常见问题

**LuCI 安装 tailscaled 失败 / 网络差**

- 安装时会依次尝试 GitHub 镜像与直连，下载超时已放宽至 3 分钟
- 若在线解析版本失败，在 `/etc/tailscale/release.conf` 设置固定版本，例如：
  ```sh
  DEFAULT_RELEASE_VERSION=v1.98.8
  ```
- 路由器本机有 HTTP 代理时，创建 `/etc/tailscale/proxy.env`：
  ```sh
  HTTP_PROXY=http://127.0.0.1:7890
  HTTPS_PROXY=http://127.0.0.1:7890
  ```
- 可编辑 `/etc/tailscale/proxies.txt` 增删 GitHub 镜像前缀

**界面显示「网络检测失败」或安装超时**

- 确认 GitHub Release 中已有对应架构的 `tailscaled-linux-*` 资产
- 路由器需能访问 GitHub；若直连失败，可编辑 `/etc/tailscale/proxies.txt` 配置镜像

**LAN 设备无法访问 Tailscale 子网**

- 在子网路由器上宣告路由，其他节点开启「接受路由」
- 本插件启用服务时会写入 UCI NAT 规则（`TailscaleLAN`），可在 **网络 → 防火墙 → NAT** 查看

**与官方 `opkg install tailscale` 的区别**

| 项目 | 本插件 | 官方 opkg |
|------|--------|-----------|
| 二进制来源 | 本仓库 GitHub Release（自编译） | OpenWrt feeds |
| 配置入口 | LuCI + `tailscale_up.conf` | `/etc/config/tailscale` + CLI |
| 界面 | 完整 LuCI 向导 | 无 / 需 CLI |

---

## 相关链接

- [GitHub Releases](https://github.com/01BAI/luci-app-tailscale/releases) — ipk 与 `tailscaled` 二进制
- [Tailscale 官方文档](https://tailscale.com/kb/)
- [tailscale/tailscale](https://github.com/tailscale/tailscale) — 官方源码
- [Tokisaki-Galaxy/luci-app-tailscale-community](https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community) — LuCI 界面参考（官方 LuCI 已合并社区版）

---

# 开发者文档

以下内容面向维护者与贡献者。

## 架构

```mermaid
flowchart LR
    A[GitHub Actions] -->|交叉编译| B[本仓库 Release]
    B -->|tailscaled-linux-arch| C[fetch_and_install.sh]
    C --> D[/usr/local/bin/tailscaled]
    E[LuCI 页面] -->|ubus rpcd| F[tailscale.uc]
    F --> G[luci-install.sh / luci-apply-up.sh 等]
    G --> C
    G --> H[/etc/init.d/tailscale]
```

### tailscaled 二进制

| 项目 | 说明 |
|------|------|
| 编译 | `.github/workflows/build-tailscaled.yml`，`go build -tags ts_include_cli`，UPX 压缩 |
| 发布 | Release 资产 `tailscaled-linux-<arch>`，附 `SHA256SUMS.txt` |
| 配置 | `/etc/tailscale/release.conf` → `GITHUB_RELEASE_REPO`（默认 `01BAI/luci-app-tailscale`） |
| 安装 | `fetch_and_install.sh` 下载并软链为 `tailscale` / `tailscaled` |

**重要**：LuCI 依赖 `tailscale status --json`，必须使用带 **`ts_include_cli`** 编译的二进制。旧版若用不含 CLI 的 tailscaled 冒充，会出现 `Access denied: status access denied`。

---

## 目录结构

```
luci-app-tailscale/
├── .github/workflows/
│   ├── build-luci-app.yml      # 编译 ipk → Release
│   └── build-tailscaled.yml    # 交叉编译 tailscaled → Release
├── Makefile
├── VERSION                     # LuCI 插件版本（单一来源）
├── htdocs/luci-static/resources/view/tailscale/
│   ├── overview.js
│   └── overview.css
├── root/
│   ├── etc/config/tailscale
│   └── etc/tailscale/          # 安装脚本与配置
└── scripts/
    ├── install-luci-app.sh     # 路由器一键安装 ipk
    ├── deploy-to-router.sh     # 热部署（macOS 开发推荐）
    ├── dev-setup.sh            # Linux SDK 环境
    └── sync-version.sh         # 同步 VERSION → 各文件
```

---

## 本地开发

### 热部署（macOS 推荐）

改完代码直接同步到路由器，无需编译 ipk：

```sh
./scripts/deploy-to-router.sh root@192.168.1.1
```

部署时会以 `TS_REGEN_ONLY=1` 重新生成 `/etc/init.d/tailscale`（不重启服务），并重启 `rpcd` / Web 服务。

### OpenWrt SDK 编译 ipk（Linux）

```sh
OPENWRT_VERSION=24.10.3 TARGET_PATH=x86/64 ./scripts/dev-setup.sh
cd openwrt-sdk
make menuconfig   # LuCI -> Applications -> luci-app-tailscale
make package/luci-app-tailscale/compile V=s
```

### GitHub Actions

| Workflow | 触发 | 产物 |
|----------|------|------|
| **Build luci-app-tailscale** | push `main` / tag `luci-v*` | ipk → Releases |
| **Build tailscaled for OpenWrt** | 手动 Run workflow | `tailscaled-linux-*` |

---

## 版本与发布

**LuCI 插件版本**由根目录 [`VERSION`](VERSION) 统一管理：

```sh
echo "1.0.0" > VERSION && ./scripts/sync-version.sh
git commit -am "release: luci v1.0.0"
git tag luci-v1.0.0
git push origin main --tags
```

| 类型 | Git 标签 | ipk |
|------|----------|-----|
| 正式版 | `luci-v1.0.0` | `PKG_VERSION=1.0.0` |
| 开发版 | push `main` → `luci-latest` | `YYYY.MM.DD-<run>.git-<sha>` |

**Tailscale 二进制版本**独立于插件，跟随官方 Release（页面显示 `/etc/tailscale/current_version`）。

---

## `/etc/tailscale/` 脚本

| 文件 | 功能 |
|------|------|
| `release.conf` | Release 仓库、版本策略 |
| `tools.sh` | 公共库：架构探测、GitHub 下载、日志 |
| `fetch_and_install.sh` | 从 Release 下载 `tailscaled-linux-$arch` |
| `setup_service.sh` | 生成 `/etc/init.d/tailscale`（procd） |
| `setup-firewall-lan.sh` | UCI NAT：LAN → tailscale0 |
| `luci-install.sh` | LuCI 非交互安装 |
| `luci-uninstall.sh` | LuCI 卸载 |
| `luci-apply-up.sh` | 应用 `tailscale up` / `tailscale set` |
| `luci-login.sh` | 登录流程 |
| `autoupdate.sh` | 可选版本更新（默认不在启动时运行） |

---

## 关键路径

| 用途 | 路径 |
|------|------|
| 二进制 | `/usr/local/bin/tailscaled` |
| CLI 软链接 | `/usr/bin/tailscale` |
| Release 配置 | `/etc/tailscale/release.conf` |
| tailscale up 配置 | `/etc/tailscale/tailscale_up.conf` |
| 守护进程状态 | `/etc/config/tailscaled.state` |
| Tailscale 版本 | `/etc/tailscale/current_version` |
| LuCI 插件版本 | `/etc/tailscale/luci-app.version` |
| 启动脚本 | `/etc/init.d/tailscale` |
| LuCI UCI | `/etc/config/tailscale` |

---

## RPC 与前端

- **ubus / rpcd**：`root/usr/share/rpcd/ucode/tailscale.uc`
- **ACL**：`root/usr/share/rpcd/acl.d/luci-app-tailscale.json`
- **页面**：`htdocs/luci-static/resources/view/tailscale/overview.js`

调试示例：

```sh
ubus call tailscale get_overview
ubus call tailscale get_status
```
