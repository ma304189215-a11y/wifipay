# WIFIPAY —— 付费 WiFi 认证计费插件

<!-- series-nav -->
> **自建服务器小工具集** · [nopass](https://github.com/ma304189215-a11y/nopass)（内网服务免密） · [ipv6-push](https://github.com/ma304189215-a11y/ipv6-push)（IPv6 变化推送） · **wifipay**（付费 WiFi 认证）
>
> 都在自己家里跑了一段时间、确实在用的东西。零第三方依赖，装完就能用。
<!-- series-nav -->

OpenWrt 插件形式的**商业 WiFi 认证系统**。设备连上 WiFi 后先跳认证页，试用 / 兑换码 / 套餐 / 付费任选，认证通过才放行上网。

一个包支持三种部署形态，在管理页面切换。

---

## 拉取

```sh
git clone https://github.com/ma304189215-a11y/wifipay.git
cd wifipay
```

只取压缩包：

```sh
wget https://github.com/ma304189215-a11y/wifipay/archive/refs/heads/main.tar.gz
tar xzf main.tar.gz && cd wifipay-main
```

---

## 三种形态怎么选

| | 谁跑插件 | 谁做路由 | 无线谁发 | 认证在哪 | 适用 |
|---|---|---|---|---|---|
| **A 单机全包** | 一台好机器 | 同一台 | 自带或外接 AP | 本机 | 软路由、N100、J4125、商用机 |
| **B 弱机 + AP** | N1 这类弱机 | N1 | **外接 K2P 等做 AP** | 本机 | 只有单核弱机 |
| **C 前后端分离** | N1 只拦截 | N1 或主路由 | 外接 | **后端机器** | 几十上百人同时认证 |

选型细节和拓扑图见 [`wifipay/docs/部署说明.md`](wifipay/docs/部署说明.md)。

---

## 安装（形态 A / B）

把 `wifipay/` 目录推到路由器上装：

```sh
# 在路由器上
apk update
# 把 wifipay/files 下所有内容按原路径放好，然后：
uci-defaults/90-wifipay      # 初始化默认配置
/etc/init.d/wifipay enable
/etc/init.d/wifipay start
```

或者打包成 ipk 安装（需要 OpenWrt SDK，见部署说明）。

管理入口在 LuCI 菜单里：

```
网络 → WIFIPAY
```

---

## 安装（形态 C：前后端分离）

**后端**（任一台能跑 Python3 的机器）：

```sh
cd be
WP_KEY='设一个强密钥' WP_PORT=9000 nohup python3 srv.py > srv.log 2>&1 &
```

零第三方依赖，只用标准库。

**前端**（OpenWrt 路由）：

```sh
uci set wifipay.settings.deploy_mode='split'
uci set wifipay.settings.backend_url='http://<后端IP>:9000'
uci set wifipay.settings.backend_key='和后端 WP_KEY 一致'
uci commit wifipay
wifipay stop && wifipay start
```

> `backend_key` 和后端 `WP_KEY` 必须一致，否则同步会一直空。

---

## 主要功能

| 功能 | 配置项 | 说明 |
|---|---|---|
| **试用** | `trial_enable` / `trial_minutes` / `trial_rate` | 首次连上给 N 分钟免费，限速可设 |
| **套餐** | `config plan 'xxx'` | 时长 + 价格，页面可改 |
| **兑换码** | 后端 `POST /api/admin/codes` | 批量生成，一码一用 |
| **微信支付** | `wx_appid` / `wx_mchid` / `wx_serial` / 私钥 | 需放 `apiclient_key.pem` |
| **广告位** | `ads_enable` / `ads_freq` | 认证页轮播 |
| **分享限制** | `share_enable` / `share_max_conn` | 防一号多人用 |
| **限速** | `rate_down` / `rate_up` | 单位 Kbps |
| **日流量限额** | `day_quota` | 单位 MB |
| **熔断** | `fuse_enable` / `fuse_conns` | 连接数超阈值自动处置 |

配置在 `/etc/config/wifipay`，也可以在 LuCI 页面里改。

---

## 常用命令

```sh
wifipay start / stop / restart
wifipay status                  # 看当前模式与拦截状态
wifipay doctor                  # 自检
wifipay selftest                # 端到端自测
wifipay trust-online            # 把自己放行（别把自己拦在外面）
wifipay panic 10                # 紧急放行 10 分钟
```

---

## 后端的运维

```sh
# 生成 10 个 1 小时套餐的兑换码
curl -X POST http://<后端IP>:9000/api/admin/codes \
  -H "X-WP-Key: 你的WP_KEY" \
  -d '{"plan":"p60","count":10}'

# 查某设备剩余时长
curl "http://<后端IP>:9000/api/status?mac=aa:bb:cc:dd:ee:ff" -H "X-WP-Key: 你的WP_KEY"
```

数据存在 `be/data/db.json`（套餐、兑换码、设备、订单），首次启动自动生成。

---

## 常见问题

**切换 `deploy_mode` 后没反应**
→ 必须 `wifipay stop && wifipay start`

**split 模式设备打开页面 404**
→ 后端没起来，或 `backend_url` 写错（**要带端口**）

**同步一直是空的**
→ `backend_key` 和后端 `WP_KEY` 不一致

**主路由模式下 portal 挂了**
→ 看门狗 3 分钟自动放行 30 分钟，看 `logread | grep wifipay`

**自己也被拦了**
→ `wifipay trust-online` 或 `wifipay panic 10`

---

## 卸载

```sh
wifipay stop
apk del luci-app-wifipay
rm -rf /etc/wifipay /etc/config/wifipay /www/wifipay
```

后端：`rm -rf /opt/backend`

---

## 安全说明

- **微信支付私钥**（`apiclient_key.pem`）不入库，已被 `.gitignore` 排除。自己放，别提交。
- 后端 `WP_KEY` 必须改，别用默认的 `changeme`。
- 兑换码生成接口在 `/api/admin/codes`，靠 `X-WP-Key` 保护，别把后端裸露到公网。

---

## 目录结构

```
wifipay/          OpenWrt 插件本体
  docs/           部署说明（含三种形态的详细拓扑）
  files/
    usr/lib/wifipay/    核心脚本
      net.sh      拦截（nftables / dnsmasq / 限速）
      plan.sh     套餐与计时
      pay.sh      微信支付
      ad.sh       广告轮播
      room.sh     座位策略
      biz.sh      商业套餐
      loop.sh     主循环与看门狗
      cfg.sh      配置读写
      sec.sh      安全
      env.sh      环境探测
      doctor.sh   自检
      selftest.sh 端到端自测
    usr/sbin/wifipay    CLI 入口
    www/           认证页（index/pay/ok）+ cgi
    etc/           默认配置与 init 脚本

be/               前后端分离模式的后端
  srv.py          单文件后端（标准库）
  www/            认证页副本
  data/db.json    数据（已 gitignore）

backend/          后端部署说明
```
