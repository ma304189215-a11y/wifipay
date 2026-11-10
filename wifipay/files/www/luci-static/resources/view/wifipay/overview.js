'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var WP = '/usr/sbin/wifipay';

function api() {
	var a = Array.prototype.slice.call(arguments);
	return fs.exec(WP, a).then(function(r) {
		if (r.code !== 0) throw new Error((r.stderr || '').trim() || ('exit ' + r.code));
		var s = (r.stdout || '').trim();
		return s ? JSON.parse(s) : null;
	});
}
function B(t, cls, fn) { return E('button', { class: 'btn cbi-button cbi-button-' + cls, click: fn }, t); }
function R(label, node, desc) {
	var kids = [ E('label', { class: 'cbi-value-title' }, label), E('div', { class: 'cbi-value-field' }, node) ];
	if (desc) kids.push(E('div', { class: 'cbi-value-description' }, desc));
	return E('div', { class: 'cbi-value' }, kids);
}
function fmt(sec) {
	if (!(sec > 0)) return '已过期';
	var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
	return (d ? d + '天' : '') + (h ? h + '小时' : '') + m + '分';
}
function notice(msg, kind) { ui.addNotification(null, E('p', {}, msg), kind || 'info'); }

return view.extend({
	load: function() {
		return Promise.all([
			api('settings'), api('allowed'), api('ads', 'list'),
			api('orders'), api('stats'), api('rooms', 'list'), api('biz', 'get')
		]).then(function(r) {
			return {
				cfg: r[0] || {}, dev: r[1] || [], ads: r[2] || [],
				orders: r[3] || [], stats: r[4] || {},
				rooms: r[5] || [], biz: r[6] || {}
			};
		}).catch(function() { return { cfg: {}, dev: [], ads: [], orders: [], stats: {}, rooms: [], biz: {} }; });
	},

	render: function(d) {
		var self = this, c = d.cfg, BIZ = d.biz || {};
		var devTb = E('tbody'), adTb = E('tbody'), ordTb = E('tbody'), roomTb = E('tbody');
		var statBox = E('div', { class: 'cbi-section' });
		var setFields = {}, setInit = {};
		var REQUIRED = { guest_net: 1, portal_port: 1 };
		var fail = function(e) { notice(e.message || String(e), 'error'); };

		function input(key, type) {
			var v = c[key];
			var val = (v === undefined || v === null) ? '' : String(v);
			var e = E('input', { type: type || 'text', value: val, style: 'width:100%' });
			setFields[key] = e; setInit[key] = val;
			return e;
		}
		function toggle(key) {
			var e = E('input', { type: 'checkbox', checked: c[key] === 1 });
			setFields[key] = e; setInit[key] = c[key] === 1 ? '1' : '0';
			return e;
		}
		function sel(key, opts, cur) {
			return E('select', { style: 'width:100%', change: function(ev){ c[key] = ev.target.value; } },
				opts.map(function(o) {
					return E('option', { value: o[0], selected: (cur || opts[0][0]) === o[0] }, o[1]);
				}));
		}

		/* ---------- 状态 ---------- */
		function renderStatus() {
			statBox.textContent = '';
			var modeName = { gateway: '主路由', bypass: '旁路由', unknown: '未识别' };
			statBox.appendChild(E('h3', {}, '运行状态'));
			statBox.appendChild(E('p', {},
				'模式：' + (modeName[c.detected_mode] || '未识别') +
				'（' + (c.lan_if || '—') + ' ' + (c.lan_ip || '—') + '）' +
				'　拦截：' + (c.enabled === 1 ? '已启用' : '未启用') +
				'　已开通：' + d.dev.length + ' 台' +
				'　收款：¥' + (d.stats.amount || 0) + '（' + (d.stats.count || 0) + ' 笔）'));

			if (c.detected_mode === 'bypass')
				statBox.appendChild(E('p', { class: 'cbi-value-description' },
					'旁路由模式：客户端网关必须指向 ' + (c.lan_ip || '') + '，否则流量不经过本机，拦截无效。'));

			statBox.appendChild(E('div', {}, [
				B('体检', 'action', function() {
					return api('doctor').then(function(r) {
						notice(String(r || '').slice(0, 400));
					}).catch(function(){
						return fs.exec(WP, ['doctor']).then(function(r){ notice(String(r.stdout || '').slice(0, 600)); });
					});
				}),
				' ',
				B('重新加载规则', 'apply', function() {
					return api('start').then(function() { notice('规则已重新加载'); }).catch(fail);
				}),
				' ',
				B('⚠ 全部放行（PANIC）', 'reset', function() {
					if (!confirm('立即清空所有拦截规则，全部设备放行 10 分钟。确定？')) return;
					return api('panic', '10').then(function() { notice('已全放行，10 分钟后自动恢复', 'warning'); }).catch(fail);
				})
			]));
		}

		/* ---------- 设备 ---------- */
		function renderDevices(list) {
			devTb.textContent = '';
			if (!list.length) {
				devTb.appendChild(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 5 }, '暂无已开通设备')));
				return;
			}
			list.forEach(function(x) {
				devTb.appendChild(E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, x.mac),
					E('td', { class: 'td' }, x.ip || '离线'),
					E('td', { class: 'td' }, x.host || '—'),
					E('td', { class: 'td' }, x.state === 'grace'
						? E('span', { style: 'color:#e54d42' }, '欠费')
						: fmt(x.remain) + (x.note === 'trial' ? ' [试用]' : '')),
					E('td', { class: 'td' }, [
						B('+30分', 'apply', function() { return api('allow', x.mac, '30', '').then(self.refresh).catch(fail); }),
						' ',
						B('+1天', 'apply', function() { return api('allow', x.mac, '1440', '').then(self.refresh).catch(fail); }),
						' ',
						B('踢掉', 'reset', function() { return api('revoke', x.mac).then(self.refresh).catch(fail); })
					])
				]));
			});
		}

		/* ---------- 广告 ---------- */
		var adTitle = E('input', { placeholder: '商品标题', style: 'width:100%' });
		var adPlat = E('select', { style: 'width:100%' },
			[['jd','京东'],['douyin','抖店'],['pdd','拼多多'],['taobao','淘宝']].map(function(p) {
				return E('option', { value: p[0] }, p[1]);
			}));
		var adLink = E('input', { placeholder: '商品链接（必须是所选平台的域名）', style: 'width:100%' });
		var adSecs = E('input', { value: '8', style: 'width:100%' });
		var adFile = E('input', { type: 'file', accept: 'image/*' });
		var platName = { jd: '京东', douyin: '抖店', pdd: '拼多多', taobao: '淘宝' };

		function renderAds(list) {
			adTb.textContent = '';
			if (!list.length) {
				adTb.appendChild(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 7 }, '还没有商品广告')));
				return;
			}
			list.forEach(function(a) {
				adTb.appendChild(E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, a.title),
					E('td', { class: 'td' }, platName[a.plat] || a.plat),
					E('td', { class: 'td' }, a.img ? E('img', { src: a.img, style: 'max-height:36px' }) : '—'),
					E('td', { class: 'td' }, a.views + ' / ' + a.clicks),
					E('td', { class: 'td' }, a.enabled ? '投放中' : '已停用'),
					E('td', { class: 'td' }, [
						B(a.enabled ? '停用' : '启用', 'neutral', function() {
							return api('ads', 'toggle', a.id).then(self.refresh).catch(fail);
						}),
						' ',
						B('删除', 'reset', function() {
							if (!confirm('删除这条广告？')) return;
							return api('ads', 'del', a.id).then(self.refresh).catch(fail);
						})
					])
				]));
			});
		}

		function uploadAd() {
			var f = adFile.files[0];
			if (!f) { notice('请选择图片', 'warning'); return Promise.resolve(null); }
			if (f.size > 500 * 1024) { notice('图片超过 500KB', 'error'); return Promise.resolve(null); }
			return new Promise(function(res) {
				var fr = new FileReader();
				fr.onload = function() {
					var b64 = String(fr.result).split(',')[1] || '';
					res(fs.write('/tmp/wifipay-upload.b64', b64));
				};
				fr.readAsDataURL(f);
			}).then(function() {
				var name = 'ad' + Date.now() + '.jpg';
				return api('ads', 'img', name, '/tmp/wifipay-upload.b64').then(function(r) {
					if (!r || !r.ok) throw new Error((r && r.msg) || '上传失败');
					return name;
				});
			});
		}

		/* ---------- 订单 ---------- */
		function renderOrders(list) {
			ordTb.textContent = '';
			var recent = list.slice(-30).reverse();
			if (!recent.length) {
				ordTb.appendChild(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 5 }, '暂无订单')));
				return;
			}
			var st = { pending: '待支付', claimed: '待确认', granted: '已开通', revoked: '已撤销', expired: '已失效' };
			recent.forEach(function(o) {
				ordTb.appendChild(E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, o.id),
					E('td', { class: 'td' }, '¥' + o.price),
					E('td', { class: 'td' }, o.mac || '—'),
					E('td', { class: 'td' }, st[o.state] || o.state),
					E('td', { class: 'td' }, o.state === 'granted' ? '—' : [
						B('确认到账', 'apply', function() {
							if (!confirm('确认这一笔已到账并开通？')) return;
							return api('confirm', o.id).then(self.refresh).catch(fail);
						}),
						' ',
						B('撤销', 'reset', function() {
							return api('order-revoke', o.id).then(self.refresh).catch(fail);
						})
					])
				]));
			});
		}

		/* ---------- 房间 ---------- */
		var rmName = E('input', { placeholder: '房间号，如 A301', style: 'width:100%' });
		var rmSeats = E('input', { value: '1', style: 'width:100%' });

		function renderRooms(list) {
			roomTb.textContent = '';
			if (!list.length) {
				roomTb.appendChild(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 7 }, '还没有房间')));
				return;
			}
			list.forEach(function(r) {
				roomTb.appendChild(E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, r.room),
					E('td', { class: 'td' }, E('code', {}, r.code)),
					E('td', { class: 'td' }, r.seats === 0 ? '不限' : String(r.seats)),
					E('td', { class: 'td' }, r.used + (r.seats > 0 ? ' / ' + r.seats : '')),
					E('td', { class: 'td', style: r.remain > 0 ? '' : 'color:#e54d42' },
						r.remain > 0 ? fmt(r.remain) : '已到期'),
					E('td', { class: 'td' }, [
						B('+30天', 'apply', function() {
							return api('rooms', 'renew', r.room, '30').then(self.refresh).catch(fail);
						}),
						' ',
						B('重置码', 'neutral', function() {
							if (!confirm('重置后旧入住码立即失效，已绑定的设备不受影响。继续？')) return;
							return api('rooms', 'resetcode', r.room).then(function(x) {
								if (x && x.code) notice('新入住码：' + x.code);
								return self.refresh();
							}).catch(fail);
						}),
						' ',
						B('解绑全部', 'reset', function() {
							if (!confirm('解绑房间 ' + r.room + ' 的所有设备？已开通时长不退回。')) return;
							return api('rooms', 'unbindall', r.room).then(self.refresh).catch(fail);
						})
					]),
					E('td', { class: 'td' }, B('删除', 'reset', function() {
						if (!confirm('删除房间 ' + r.room + ' 并解绑所有设备？')) return;
						return api('rooms', 'del', r.room).then(self.refresh).catch(fail);
					}))
				]));
			});
		}

		/* ---------- 资质 ---------- */
		var bizType = E('select', { style: 'width:100%', change: function(ev){ BIZ.type = ev.target.value; } },
			[['company','企业/个体户'],['personal','个人']].map(function(x) {
				return E('option', { value: x[0], selected: (BIZ.type || 'company') === x[0] }, x[1]);
			}));
		var bizName = E('input', { value: BIZ.name || '', style: 'width:100%' });
		var bizCode = E('input', { value: BIZ.code || '', style: 'width:100%' });
		var bizAddr = E('input', { value: BIZ.addr || '', style: 'width:100%' });
		var bizUntil = E('input', { value: BIZ.until || '', placeholder: 'YYYY-MM-DD', style: 'width:100%' });

		/* ---------- 组装 ---------- */
		renderStatus();
		renderDevices(d.dev);
		renderAds(d.ads);
		renderOrders(d.orders);
		renderRooms(d.rooms);

		self.refresh = function() {
			return Promise.all([
				api('allowed'), api('ads', 'list'), api('orders'), api('stats'), api('rooms', 'list')
			]).then(function(r) {
				d.dev = r[0] || []; d.ads = r[1] || []; d.orders = r[2] || [];
				d.stats = r[3] || {}; d.rooms = r[4] || [];
				renderStatus(); renderDevices(d.dev); renderAds(d.ads); renderOrders(d.orders); renderRooms(d.rooms);
			}).catch(function() {});
		};
		poll.add(function() { return self.refresh(); }, 20);

		return E('div', { class: 'cbi-map' }, [
			E('h2', {}, '付费 WiFi'),
			statBox,

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '基本设置'),
				R('页面标题', input('title')),
				R('portal 端口', input('portal_port')),
				R('客人网段', input('guest_net'), '默认与 LAN 同网段；双网段部署时填客人专属网段'),
				R('运行模式', sel('mode', [['auto','自动'],['gateway','主路由'],['bypass','旁路由']], c.mode || 'auto')),
				R('默认时长(分钟)', input('default_minutes')),
				R('logo 路径', input('logo'), '把图片传到 /www/wifipay/ 下，这里填 /wifipay/xxx.png'),
				R('客服联系方式', input('contact')),
				R('启用拦截', toggle('enabled')),
				R('DNS 劫持', toggle('dns_hijack')),
				R('封堵 IPv6', toggle('ipv6_block')),

				E('h3', {}, '试用'),
				R('开启试用', toggle('trial_enable')),
				R('试用分钟数', input('trial_minutes')),
				R('试用限速(kbps)', input('trial_rate')),
				R('每日网段试用上限(0不限)', input('trial_seg_max')),
				R('到期前提醒(分钟)', input('warn_minutes'), '建议小于最短套餐时长，否则一开通就提示'),

				E('h3', {}, '限速与防共享'),
				R('下行(kbps, 0=不限)', input('rate_down')),
				R('上行(kbps)', input('rate_up')),
				R('单设备连接速率上限', input('share_max_conn')),
				R('开启防共享', toggle('share_enable')),
				R('超限处置', sel('share_action', [['throttle','丢包（限制连接）'],['log','仅记录不处置'],['block','踢下线']], c.share_action || 'throttle')),
				R('日请求配额', input('day_quota')),
				R('开启熔断', toggle('fuse_enable')),
				R('熔断并发阈值', input('fuse_conns')),

				E('h3', {}, '到期处理'),
				R('宽限天数', input('grace_days'), '宽限期内降速催缴；0 表示到期即断'),
				R('宽限期速(kbps)', input('grace_rate')),

				E('h3', {}, '广告'),
				R('开启广告位', toggle('ads_enable')),
				R('每设备每日展示次数', input('ads_freq'), '填 0 为不限；三个广告位共用这份配额'),

				E('h3', {}, '支付'),
				R('支付模式', sel('pay_mode', [['off','关闭'],['manual','人工确认'],['wxpay','微信扫码']], c.pay_mode || 'off')),
				R('收款码路径', input('pay_qr')),
				R('微信 appid', input('wx_appid')),
				R('微信商户号', input('wx_mchid')),
				R('证书序列号', input('wx_serial'), '商户私钥放 /etc/wifipay/wx/apiclient_key.pem，权限 600'),

				E('h3', {}, '资质与名额'),
				R('资质登记', toggle('biz_enable')),
				R('超额设备', sel('seat_policy', [['reject','拒绝新设备'],['replace_oldest','顶掉最久未用的']], c.seat_policy || 'reject')),

				E('div', { class: 'cbi-page-actions' },
					B('保存设置', 'save', function() {
						var jobs = [];
						Object.keys(setFields).forEach(function(k) {
							var el = setFields[k];
							var v = el.type === 'checkbox' ? (el.checked ? '1' : '0') : String(el.value || '').trim();
							var init = el.type === 'checkbox' ? (c[k] === 1 ? '1' : '0') : (setInit[k] || '');
							if (v === init) return;
							if (v === '' && REQUIRED[k]) { notice('「' + k + '」不能为空', 'error'); return; }
							jobs.push(api('set', k, v));
						});
						if (c.mode) jobs.push(api('set', 'mode', c.mode));
						if (c.pay_mode) jobs.push(api('set', 'pay_mode', c.pay_mode));
						if (c.share_action) jobs.push(api('set', 'share_action', c.share_action));
						if (c.seat_policy) jobs.push(api('set', 'seat_policy', c.seat_policy));
						if (!jobs.length) { notice('没有改动'); return; }
						return Promise.all(jobs).then(function() { notice('已保存'); return self.refresh(); }).catch(fail);
					}))
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '已开通设备'),
				E('table', { class: 'table' }, [
					E('thead', {}, E('tr', { class: 'tr' }, [
						E('th', { class: 'th' }, 'MAC'), E('th', { class: 'th' }, 'IP'),
						E('th', { class: 'th' }, '主机名'), E('th', { class: 'th' }, '剩余'), E('th', { class: 'th' }, '操作')
					])),
					devTb
				])
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '房间与名额'),
				R('房间号', rmName),
				R('名额', rmSeats, '默认 1 人 1 设备；填 0 表示不限名额'),
				E('p', { class: 'cbi-value-description' },
					'租客在认证页输入入住码即可绑定；房间到期 = 名下设备全部到期，点「+30天」会一起延期。'),
				E('div', { class: 'cbi-page-actions' },
					B('添加房间', 'add', function() {
						var n = String(rmName.value || '').trim();
						if (!n) { notice('请填房间号', 'error'); return; }
						return api('rooms', 'add', n, rmSeats.value).then(function(x) {
							if (!x || !x.ok) throw new Error((x && x.msg) || '添加失败');
							notice('已添加，入住码：' + x.code);
							rmName.value = ''; rmSeats.value = '1';
							return self.refresh();
						}).catch(fail);
					})),
				E('table', { class: 'table' }, [
					E('thead', {}, E('tr', { class: 'tr' }, [
						E('th', { class: 'th' }, '房间'), E('th', { class: 'th' }, '入住码'),
						E('th', { class: 'th' }, '名额'), E('th', { class: 'th' }, '已绑'),
						E('th', { class: 'th' }, '到期'), E('th', { class: 'th' }, '操作'), E('th', { class: 'th' }, '')
					])),
					roomTb
				])
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '商品广告'),
				R('标题', adTitle),
				R('平台', adPlat),
				R('商品链接', adLink),
				R('显示秒数', adSecs),
				R('图片（≤500KB）', adFile),
				E('div', { class: 'cbi-page-actions' },
					B('上传并添加', 'add', function() {
						return uploadAd().then(function(name) {
							if (!name) return;
							return api('ads', 'add', adTitle.value, adPlat.value, adLink.value, name, adSecs.value)
								.then(function(r) {
									if (!r || !r.ok) throw new Error((r && r.msg) || '添加失败');
									adTitle.value = ''; adLink.value = ''; adFile.value = '';
									notice('已添加');
									return self.refresh();
								});
						}).catch(fail);
					})),
				E('table', { class: 'table' }, [
					E('thead', {}, E('tr', { class: 'tr' }, [
						E('th', { class: 'th' }, '标题'), E('th', { class: 'th' }, '平台'),
						E('th', { class: 'th' }, '图'), E('th', { class: 'th' }, '曝光/点击'),
						E('th', { class: 'th' }, '状态'), E('th', { class: 'th' }, '操作'), E('th', { class: 'th' }, '')
					])),
					adTb
				])
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '订单'),
				E('table', { class: 'table' }, [
					E('thead', {}, E('tr', { class: 'tr' }, [
						E('th', { class: 'th' }, '订单号'), E('th', { class: 'th' }, '金额'),
						E('th', { class: 'th' }, '设备'), E('th', { class: 'th' }, '状态'), E('th', { class: 'th' }, '操作')
					])),
					ordTb
				])
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '资质登记'),
				R('主体类型', bizType),
				R('名称', bizName),
				R('统一社会信用代码', bizCode),
				R('经营/居住地址', bizAddr),
				R('有效期至', bizUntil),
				E('p', { class: 'cbi-value-description' },
					'个人主体只填名称和地址即可，不需要证件号；开启后认证页会公示名称与信用代码'),
				E('div', { class: 'cbi-page-actions' },
					B('保存资质', 'save', function() {
						var jobs = [];
						if (BIZ.type) jobs.push(api('biz', 'set', 'type', BIZ.type));
						[[bizName,'name'],[bizCode,'code'],[bizAddr,'addr'],[bizUntil,'until']].forEach(function(x) {
							jobs.push(api('biz', 'set', x[1], x[0].value));
						});
						return Promise.all(jobs).then(function() { notice('资质已保存'); }).catch(fail);
					}))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
