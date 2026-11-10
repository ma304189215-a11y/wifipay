# WIFIPAY 后端

前后端分离模式（deploy_mode=split）专用的认证后端。

## 启动

```sh
cd backend
WP_KEY=你的密钥 WP_PORT=9000 nohup python3 srv.py > srv.log 2>&1 &
```

## 接口

GET  /api/sync                白名单同步（需要 X-WP-Key 头）
GET  /api/plans               套餐列表
GET  /api/status?mac=xx       查剩余时长
GET  /api/trial?mac=xx        开试用
GET  /api/redeem?mac=xx&code= 兑换
POST /api/admin/codes         生成兑换码 {"plan":"p60","count":10}

## 数据

data/db.json  套餐、兑换码、设备、订单，首次启动自动生成
