# luci-app-tailscale

OpenWrt / iStoreOS 上的 Tailscale LuCI 图形界面插件。在路由器 Web 界面完成安装、登录、连接设置与状态查看，无需 SSH 手工操作。

本仓库**独立维护**：`tailscaled` 二进制由本仓库 GitHub Actions 从 [Tailscale 官方源码](https://github.com/tailscale/tailscale) 交叉编译并发布到 **本仓库 Releases**，安装脚本从该 Release 下载，不依赖任何第三方 Tailscale 打包项目。

## 架构概览

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

### tailscaled 二进制来源

| 项目 | 说明 |
|------|------|
| 编译 | `.github/workflows/build-tailscaled.yml`，支持 amd64 / 386 / arm / arm64 / mips 等 8 种架构 |
| 发布 | 本仓库 GitHub Release，资产命名 `tailscaled-linux-<arch>`，附 `SHA256SUMS.txt` / `MD5SUMS.txt` |
| 配置 | `/etc/tailscale/release.conf` 中的 `GITHUB_RELEASE_REPO`（默认 `01BAI/luci-app-tailscale`） |
| 安装 | `fetch_and_install.sh` 下载、校验并安装到 `/usr/local/bin/tailscaled` |

**首次使用前**，需在 GitHub 网页运行一次 Actions：**Actions → Build tailscaled for OpenWrt → Run workflow**（版本留空则自动取官方 latest）。Release 生成后，路由器才能从 LuCI 安装 Tailscale。

---

## 安装 LuCI 插件（其他用户）

ipk 包架构为 **all**，各平台 OpenWrt 路由器通用。从 [GitHub Releases](https://github.com/01BAI/luci-app-tailscale/releases) 下载后手动安装即可。

| Release | 说明 |
|---------|------|
| **luci-v***（如 `luci-v1.0.0`） | 正式版 |
| **luci-latest** | main 分支自动编译的开发版（预发布） |

### 路由器上安装

1. 在 Release 页面下载两个 ipk：
   - `luci-app-tailscale_*.ipk`
   - `luci-i18n-tailscale-zh-cn_*.ipk`（中文界面，可选）

2. 上传到路由器并安装（首次使用 Tailscale 前，请先安装运行依赖）：

```sh
# 路由器上（如尚未安装）
opkg update
opkg install curl ca-bundle kmod-tun

# 本机上传（把 IP 换成你的路由器地址）
scp luci-app-tailscale_*.ipk luci-i18n-tailscale-zh-cn_*.ipk root@192.168.1.1:/tmp/

# 路由器上安装 LuCI 插件
opkg install /tmp/luci-app-tailscale_*.ipk
opkg install /tmp/luci-i18n-tailscale-zh-cn_*.ipk
```

或在 LuCI：**系统 → 软件包 → 上传软件包**，先装主包再装语言包。

安装后在 LuCI：**VPN → Tailscale**。插件会从 `release.conf` 配置的 Release 仓库下载 `tailscaled` 二进制。

### 发布正式版（维护者）

打 tag `luci-v1.0.0` 会触发编译，并在 GitHub Release 附上 ipk（与 tailscaled 的 `v1.98.8` 等 tag 互不冲突）。

```sh
git tag luci-v1.0.0
git push origin luci-v1.0.0
```

### 安装流程（LuCI）

1. 安装本 LuCI 包（ipk 或热部署，见下文）
2. 打开 **VPN → Tailscale**，点击「安装 / 重装」
3. 调用 `/etc/tailscale/luci-install.sh`：检测架构 → 从 Release 下载二进制 → 生成 init 脚本 → 启动服务
4. 直连 GitHub 失败时会自动重试（可配置 `/etc/tailscale/proxies.txt` 自定义代理列表）

### `/etc/tailscale/` 核心脚本

| 文件 | 功能 |
|------|------|
| `release.conf` | 指定 Release 仓库（`GITHUB_RELEASE_REPO=用户/仓库`） |
| `tools.sh` | 公共库：架构探测、GitHub 下载、日志 |
| `fetch_and_install.sh` | 从 Release 下载 `tailscaled-linux-$arch` 并校验安装 |
| `setup_service.sh` | 生成 `/etc/init.d/tailscale`（procd 管理 tailscaled） |
| `luci-install.sh` | LuCI 非交互安装（本地模式） |
| `luci-uninstall.sh` | LuCI 卸载 |
| `luci-apply-up.sh` | 应用 `tailscale up` 连接设置 |
| `luci-login.sh` | 登录流程辅助 |
| `luci-setup-cron.sh` / `autoupdate.sh` | 自动更新 |

### 与官方 opkg tailscale 的区别

| 项目 | 本插件 | 官方 opkg |
|------|--------|-----------|
| 二进制来源 | 本仓库 GitHub Release（自编译） | OpenWrt feeds |
| 配置入口 | LuCI + `/etc/tailscale/tailscale_up.conf` | `/etc/config/tailscale` + CLI |
| 版本更新 | Actions 手动触发 + LuCI 检测更新 | opkg upgrade |

---

## 开发环境

### 目录结构

```
luci-app-tailscale/
├── .github/workflows/
│   ├── build-luci-app.yml                   # 编译 ipk 并发布到 GitHub Release
│   └── build-tailscaled.yml                 # 交叉编译 tailscaled 并发布 Release
├── Makefile
├── htdocs/luci-static/resources/view/tailscale/
│   ├── overview.js
│   └── overview.css
├── root/
│   ├── etc/
│   │   ├── config/tailscale
│   │   └── tailscale/                       # 安装脚本与 release.conf
│   └── usr/share/
│       ├── luci/menu.d/luci-app-tailscale.json
│       └── rpcd/
│           ├── acl.d/luci-app-tailscale.json
│           └── ucode/tailscale.uc
├── po/zh_Hans/tailscale.po
└── scripts/
    ├── dev-setup.sh          # Linux 下下载 SDK 并链接本包
    └── deploy-to-router.sh   # 热部署到路由器（推荐 macOS 开发）
```

### 方式一：路由器热部署（macOS 推荐）

无需编译 ipk，改完代码直接同步到路由器：

```sh
chmod +x scripts/deploy-to-router.sh
./scripts/deploy-to-router.sh root@192.168.1.1
```

LuCI 路径：**VPN → Tailscale**

修改 Release 仓库时，编辑路由器上的 `/etc/tailscale/release.conf` 即可，无需重新编译。

### 方式二：OpenWrt SDK 编译 ipk（Linux）

```sh
chmod +x scripts/dev-setup.sh
OPENWRT_VERSION=24.10.3 TARGET_PATH=x86/64 ./scripts/dev-setup.sh

cd openwrt-sdk
make menuconfig   # LuCI -> Applications -> luci-app-tailscale
make package/luci-app-tailscale/compile V=s

# 安装到路由器
scp bin/packages/*/luci/luci-app-tailscale_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install --force-overwrite /tmp/luci-app-tailscale_*.ipk"
```

### 方式三：GitHub Actions 自动编译

| Workflow | 触发 | 产物 |
|----------|------|------|
| **Build luci-app-tailscale** | push main / tag `luci-v*` | ipk → [GitHub Releases](https://github.com/01BAI/luci-app-tailscale/releases) |
| **Build tailscaled for OpenWrt** | 手动 Run workflow | `tailscaled-linux-*` 二进制 Release |

```sh
# luci 插件：push 到 main 即自动编译；正式版打 tag luci-v1.0.0
# tailscaled：Actions → Build tailscaled for OpenWrt → Run workflow
```

---

## 当前插件能力

### 页面结构

1. **状态区**
   - 总开关（`/etc/init.d/tailscale` 启停）
   - 运行状态、登录状态、版本信息
   - 登录 / 登出（含登录链接轮询）
   - 节点列表

2. **安装 / 重装 / 卸载**
   - 从本仓库 Release 安装 `tailscaled`
   - 检测并提示新版本

3. **连接设置**
   - 接受路由、宣告路由、Netfilter 模式、出口节点等 `tailscale up` 参数
   - 保存到 `/etc/tailscale/tailscale_up.conf`
   - 「保存并应用」执行 `tailscale up --reset`
   - 登录后**不会**自动应用连接设置（避免出口节点/接受路由导致 LAN 失联，需手动点「保存并应用」）

### 文件路径

| 用途 | 路径 |
|------|------|
| 二进制 | `/usr/local/bin/tailscaled` |
| CLI 软链接 | `/usr/bin/tailscale` |
| Release 仓库配置 | `/etc/tailscale/release.conf` |
| 安装配置 | `/etc/tailscale/install.conf` |
| tailscale up 配置 | `/etc/tailscale/tailscale_up.conf` |
| 守护进程状态 | `/etc/config/tailscaled.state` |
| 版本记录 | `/etc/tailscale/current_version` |
| 启动脚本 | `/etc/init.d/tailscale` |
| LuCI UCI | `/etc/config/tailscale` |

## 参考

- [tailscale/tailscale](https://github.com/tailscale/tailscale)（官方源码）
- [Tokisaki-Galaxy/luci-app-tailscale-community](https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community)（LuCI 界面参考，官方 LuCI 已合并社区版）
