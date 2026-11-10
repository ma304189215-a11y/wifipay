'use strict';
'require view';
'require form';
'require uci';
'require fs';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wifipay').then(function() {
				return {
					mode: uci.get('wifipay', 'settings', 'deploy_mode') || 'full',
					enabled: uci.get('wifipay', 'settings', 'enabled') || '0'
				};
			}),
			fs.exec('/usr/sbin/nft', ['list', 'table', 'inet', 'wifipay'])
				.then(function(r) { return r.code === 0; })
				.catch(function() { return false; })
		]).then(function(r) { return { cfg: r[0], rules: r[1] }; });
	},

	render: function(d) {
		var c = (d && d.cfg) || {}, hasRules = !!(d && d.rules);
		var m, s, o;

		m = new form.Map('wifipay', '部署形态',
			'这个插件跑在哪类机器上，决定认证页由谁提供');

		s = m.section(form.NamedSection, 'settings', 'wifipay', '形态选择');
		s.anonymous = false;

		o = s.option(form.ListValue, 'deploy_mode', '部署形态');
		o.value('full', '单机全包 — 本机跑全部功能');
		o.value('ap', '弱机 + AP — 本机做网关，无线交给外接 AP');
		o.value('split', '前后端分离 — 本机只拦截，认证在后端');
		o.default = 'full';
		o.rmempty = false;
		o.description = '切换后点「重新加载规则」生效';

		s = m.section(form.NamedSection, 'settings', 'wifipay', '三种形态说明');
		s.anonymous = true;
		o = s.option(form.DummyValue, '_explain', ' ');
		o.cfgvalue = function() {
			return E('div', { style: 'line-height:1.9;color:#555' }, [
				E('div', {}, E('b', {}, '单机全包：'), '一台性能足够的机器（软路由/N100/J4125），装上就是完整系统，套餐、兑换码、广告、订单都在本机。'),
				E('div', {}, E('b', {}, '弱机 + AP：'), '本机（N1 这类）做网关和认证，外接 K2P 只当无线接入点——把 K2P 的 DHCP 关掉、LAN 口接到本机 LAN，本机拨号或接上级。'),
				E('div', {}, E('b', {}, '前后端分离：'), '本机只做 nft 拦截并把 HTTP 转给后端，认证页、兑换码、订单全在后端机器（PVE 容器）上跑。')
			]);
		};

		s = m.section(form.NamedSection, 'settings', 'wifipay', '后端（仅前后端分离需要）');
		s.anonymous = false;

		o = s.option(form.Value, 'backend_url', '后端地址');
		o.placeholder = 'http://192.168.2.99:9000';
		o.depends('deploy_mode', 'split');

		o = s.option(form.Value, 'backend_key', '同步密钥');
		o.password = true;
		o.depends('deploy_mode', 'split');

		o = s.option(form.Value, 'sync_interval', '同步间隔（秒）');
		o.datatype = 'uinteger';
		o.default = '60';
		o.depends('deploy_mode', 'split');

		s = m.section(form.NamedSection, 'settings', 'wifipay', '当前状态');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_m', '部署形态');
		o.cfgvalue = function() {
			return { full: '单机全包', ap: '弱机 + AP', split: '前后端分离' }[c.mode] || c.mode;
		};

		o = s.option(form.DummyValue, '_e', '拦截开关');
		o.cfgvalue = function() { return c.enabled == '1' ? '已启用' : '未启用'; };

		o = s.option(form.DummyValue, '_r', '规则状态');
		o.cfgvalue = function() { return hasRules ? '已加载' : '未加载'; };

		return m.render();
	}
});
