# WIFIPAY 使用手册

## 一、拉取

```sh
git clone https://github.com/ma304189215-a11y/wifipay.git
cd wifipay
```

压缩包方式：

```sh
wget https://github.com/ma304189215-a11y/wifipay/archive/refs/heads/main.tar.gz
tar xzf main.tar.gz && cd wifipay-main
```

装到路由器：

```sh
# 把 wifipay/files 下的内容按原路径拷到路由器根目录
scp -r wifipay/files/* root@<路由IP>:/
ssh root@<路由IP>
/etc/uci-defaults/90-wifipay    # 或手动 /etc/init.d/wifipay enable
/etc/init.d/wifipay start
```

---

## 二、三种形态的完整配置

### 形态 A：单机全包

一台机器同时做路由 + 认证 + 无线。

```sh
uci set wifipay.settings.deploy_mode='bypass'
uci set wifipay.settings.lan_if='br-lan'
uci set wifipay.settings.lan_net='192.168.2.0/24'
uci commit wifipay
wifipay stop && wifipay start
wifipay status
```

### 形态 B：弱机 + 外接 AP

N1 做网关和认证，K2P 只做 AP。**N1 必须有两个网口**（或 VLAN 单臂路由）。

K2P 侧：
- 关 DHCP
- 关路由（LAN 口当交换机用）
- LAN 口接 N1 的 LAN

N1 侧配置同形态 A。

### 形态 C：前后端分离

**后端**（另一台机器，跑 Python3）：

```sh
cd be
WP_KEY='强密钥' WP_PORT=9000 nohup python3 srv.py > srv.log 2>&1 &
```

**前端**（OpenWrt）：

```sh
uci set wifipay.settings.deploy_mode='split'
uci set wifipay.settings.backend_url='http://<后端IP>:9000'
uci set wifipay.settings.backend_key='和后端 WP_KEY 一模一样'
uci commit wifipay
wifipay stop && wifipay start
```

验证同步：

```sh
logread | grep wifipay | tail -20
curl "http://<后端IP>:9000/api/sync" -H "X-WP-Key: 你的WP_KEY"
```

---

## 三、功能配置速查

全部在 `/etc/config/wifipay`，或 LuCI → 网络 → WIFIPAY。

### 试用

```sh
uci set wifipay.settings.trial_enable='1'
uci set wifipay.settings.trial_minutes='30'    # 免费 30 分钟
uci set wifipay.settings.trial_rate='3072'     # 限速 3Mbps
uci set wifipay.settings.warn_minutes='5'      # 到期前 5 分钟提醒
```

### 套餐

```sh
uci add wifipay plan
uci set wifipay.@plan[-1].title='1 小时'
uci set wifipay.@plan[-1].price='1'
uci set wifipay.@plan[-1].minutes='60'
uci commit wifipay
```

### 限速与配额

```sh
uci set wifipay.settings.rate_down='10240'   # 下行 10Mbps（单位 Kbps）
uci set wifipay.settings.rate_up='10240'     # 上行
uci set wifipay.settings.day_quota='500'     # 日流量 500MB
```

### 防一号多人用

```sh
uci set wifipay.settings.share_enable='1'
uci set wifipay.settings.share_max_conn='150'    # 单账号最大连接数
uci set wifipay.settings.share_action='throttle' # throttle 限速 / block 断开
```

### 微信支付

需要四样东西 + 一个私钥文件：

```sh
uci set wifipay.settings.wx_appid='wx...'        # 公众号/服务商 AppID
uci set wifipay.settings.wx_mchid='16...'        # 商户号
uci set wifipay.settings.wx_serial='...'         # 证书序列号
uci set wifipay.settings.pay_mode='wx'
# 私钥放到 /etc/wifipay/apiclient_key.pem
```

`pay.sh` 会读 `/etc/wifipay/apiclient_key.pem` 签 v3 支付请求。

### 广告位

```sh
uci set wifipay.settings.ads_enable='1'
uci set wifipay.settings.ads_freq='3'    # 每 3 次认证展示一次
```

---

## 四、命令行

```sh
wifipay start | stop | restart
wifipay status         # 模式、拦截状态、在线设备数
wifipay doctor         # 环境自检（网卡、nft、dnsmasq、防火墙）
wifipay selftest       # 端到端自测
wifipay trust-online   # 放行自己（别把自己拦外面）
wifipay panic 10       # 紧急全放行 10 分钟
```

**`trust-online` 和 `panic` 是救命命令**，配错了先跑这个再去调。

---

## 五、后端运维

### 生成兑换码

```sh
curl -X POST http://<后端IP>:9000/api/admin/codes \
  -H "X-WP-Key: 你的WP_KEY" \
  -H "Content-Type: application/json" \
  -d '{"plan":"p60","count":10}'
```

返回 10 个码，一码一用。

### 查设备状态

```sh
curl "http://<后端IP>:9000/api/status?mac=aa:bb:cc:dd:ee:ff" -H "X-WP-Key: 你的WP_KEY"
```

### 开试用 / 兑换

```sh
curl "http://<后端IP>:9000/api/trial?mac=aa:bb:cc:dd:ee:ff" -H "X-WP-Key: ..."
curl "http://<后端IP>:9000/api/redeem?mac=aa:bb:cc:dd:ee:ff&code=288G9GDDR6" -H "X-WP-Key: ..."
```

---

## 六、排查顺序

按这个顺序查，基本能定位：

```sh
# 1. 环境有没有问题
wifipay doctor

# 2. 当前是什么模式、拦没拦
wifipay status

# 3. 拦截规则在不在
nft list ruleset | grep -c wifipay
dnsmasq 是否劫持：uci show wifipay | grep dns_hijack

# 4. 认证页能不能访问（在手机连上 WiFi 后）
curl -v http://192.168.2.3:8088/wifipay/index.html

# 5. 后端通不通（split 模式）
curl -v http://<后端IP>:9000/api/plans

# 6. 看日志
logread | grep wifipay | tail -30
```

| 症状 | 原因 |
|---|---|
| 切了模式没反应 | 必须 `wifipay stop && wifipay start` |
| split 模式页面 404 | 后端没起 / `backend_url` 漏了端口 |
| 同步一直空 | `backend_key` 与后端 `WP_KEY` 不一致 |
| portal 挂了还断网 | 看门狗 3 分钟自动放行 30 分钟，查 `logread` |
| 自己也被拦 | `wifipay trust-online` |
| 微信支付签名失败 | 私钥路径不对 / 证书序列号过期 |

---

## 七、安全

1. **`apiclient_key.pem` 绝不提交**。`.gitignore` 已排除 `*.pem` 和 `**/apiclient_key.pem`。
2. 后端 `WP_KEY` 必须改，默认 `changeme` 等于没保护。
3. `/api/admin/codes` 是兑换码生成接口，靠 `X-WP-Key` 保护，后端别裸奔到公网。
4. `be/data/db.json` 含兑换码和设备 MAC，已在 `.gitignore`。
5. 认证页在后端不可达时会**保留上次白名单**，不会全断——这是设计如此，别当成 bug。

---

## 八、卸载

```sh
wifipay stop
apk del luci-app-wifipay
rm -rf /etc/wifipay /etc/config/wifipay /www/wifipay
```

后端：`systemctl disable --now wifipay-backend; rm -rf /opt/backend`
