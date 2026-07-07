'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

/* 热部署后改此版本号，强制浏览器刷新 CSS/JS */
const UI_REV = '1.0.1 build26070704';
const CSS_REV = '20260707-1';

const SETTINGS_FIELDS = [
	['accept_routes', '接受路由', '--accept-routes', '', 'flag'],
	['advertise_routes', '宣告路由', '--advertise-routes', '例如：192.168.1.0/24', 'value'],
	['netfilter_mode', 'Netfilter 模式', '--netfilter-mode', 'nodivert', 'select', ['on', 'nodivert', 'off']],
	['advertise_exit_node', '宣告出口节点', '--advertise-exit-node', '', 'flag'],
	['exit_node', '出口节点', '--exit-node', '留空=不使用', 'value'],
	['exit_node_allow_lan_access', '出口节点允许局域网', '--exit-node-allow-lan-access', '', 'flag'],
	['shields_up', '屏蔽入站', '--shields-up', '', 'flag'],
	['ssh', 'Tailscale SSH', '--ssh', '', 'flag'],
	['hostname', '主机名', '--hostname', '', 'value'],
	['login_server', '登录服务器', '--login-server', '', 'value'],
	['auth_key', '授权密钥', '--auth-key', '', 'value']
];

const UP_KEYS = SETTINGS_FIELDS.map(function(f) { return f[0]; });

const callGetOverview = rpc.declare({ object: 'tailscale', method: 'get_overview' });
const callGetStatus = rpc.declare({ object: 'tailscale', method: 'get_status' });
const callRunInstall = rpc.declare({ object: 'tailscale', method: 'run_install', params: [ 'version' ] });
const callGetInstallProgress = rpc.declare({ object: 'tailscale', method: 'get_install_progress' });
const callRunUninstall = rpc.declare({ object: 'tailscale', method: 'run_uninstall' });
const callCheckUpdates = rpc.declare({ object: 'tailscale', method: 'check_updates', timeout: 45 });
const callRunLuciUpdate = rpc.declare({ object: 'tailscale', method: 'run_luci_update', params: [ 'tag' ] });
const callGetLuciUpdateProgress = rpc.declare({ object: 'tailscale', method: 'get_luci_update_progress' });
const callGetUpSettings = rpc.declare({ object: 'tailscale', method: 'get_up_settings' });
const callSetUpSettings = rpc.declare({ object: 'tailscale', method: 'set_up_settings', params: [ 'data' ] });
const callPreviewUpCommand = rpc.declare({ object: 'tailscale', method: 'preview_up_command', params: [ 'data' ] });
const callApplySavedUp = rpc.declare({ object: 'tailscale', method: 'apply_saved_up' });
const callApplyUpSettings = rpc.declare({ object: 'tailscale', method: 'apply_up_settings', params: [ 'data' ] });
const callStartLogin = rpc.declare({
	object: 'tailscale',
	method: 'start_login',
	timeout: 15
});
const callGetLoginProgress = rpc.declare({
	object: 'tailscale',
	method: 'get_login_progress',
	timeout: 15
});
const callDoLogout = rpc.declare({ object: 'tailscale', method: 'do_logout' });
const callSetServiceEnabled = rpc.declare({ object: 'tailscale', method: 'set_service_enabled', params: [ 'enabled' ] });

function rpcCall(promise, fallback) {
	return promise.then(function(res) {
		if (res == null || res.error)
			return fallback;
		return res;
	}).catch(function() { return fallback; });
}

function isFlagEnabled(val) {
	return val === true || val === 1 || val === '1' || val === 'true';
}

function collectUpSettings(root) {
	const settings = {};
	UP_KEYS.forEach(k => {
		const el = root.querySelector('[data-up-key="' + k + '"]');
		if (!el) return;
		if (el.type === 'checkbox')
			settings[k] = el.checked ? 'true' : 'false';
		else
			settings[k] = (el.value || '').trim();
	});
	return settings;
}

function applyUpSettingsToForm(root, settings) {
	UP_KEYS.forEach(k => {
		const el = root.querySelector('[data-up-key="' + k + '"]');
		if (!el) return;
		const val = settings[k];
		if (el.type === 'checkbox')
			el.checked = isFlagEnabled(val);
		else if (el.tagName === 'SELECT')
			el.value = (val && el.querySelector('option[value="' + val + '"]')) ? val : (el.options[0] ? el.options[0].value : '');
		else
			el.value = val || '';
	});
}

function settingsLabel(label, cli) {
	return E('div', { class: 'ts-settings-label' }, [
		E('span', {}, label),
		E('code', { class: 'ts-cli-param' }, cli)
	]);
}

function confirmApplySettings(settings) {
	const parts = [];
	if (settings.exit_node && settings.exit_node.trim())
		parts.push('出口节点：' + settings.exit_node.trim() + '（可能使本机无法从局域网访问）');
	if (settings.accept_routes === 'true')
		parts.push('接受路由：已启用（可能与本地网段/默认路由冲突）');
	if (settings.advertise_exit_node === 'true')
		parts.push('宣告出口节点：已启用');
	return parts.length ? parts.join('\n') : '';
}

function showUpCommandConfirmModal(command, warningText) {
	return new Promise(function(resolve, reject) {
		const nodes = [
			E('p', {}, '设置已保存。请确认以下命令是否正确：'),
			E('pre', { class: 'ts-install-log' }, command || '')
		];

		if (warningText)
			nodes.push(E('pre', { class: 'ts-settings-hint', style: 'margin:0.75rem 0 0' }, warningText));

		nodes.push(E('div', { class: 'ts-field-actions', style: 'padding-left:0;margin-top:0.75rem' }, [
			E('button', {
				class: 'btn cbi-button-apply important',
				click: function(ev) {
					ev.preventDefault();
					ui.hideModal();
					resolve(true);
				}
			}, '确认执行'),
			E('button', {
				class: 'btn cbi-button-neutral',
				click: function(ev) {
					ev.preventDefault();
					ui.hideModal();
					reject(new Error('已取消'));
				}
			}, '取消')
		]));

		ui.showModal('确认执行 tailscale up', nodes);
	});
}

function saveAndConfirmApplyUp(settings, settingsRoot) {
	const warningText = confirmApplySettings(settings);

	return callSetUpSettings(settings).then(function(saveRes) {
		if (!saveRes || saveRes.success === false || saveRes.error)
			throw new Error((saveRes && (saveRes.message || saveRes.error)) || '保存失败');
		applyUpSettingsToForm(settingsRoot, saveRes.settings || settings);
		return callPreviewUpCommand(settings);
	}).then(function(preview) {
		if (!preview || preview.success === false || !preview.command)
			throw new Error((preview && preview.message) || '无法生成 tailscale up 命令');
		return showUpCommandConfirmModal(preview.command, warningText);
	}).then(function() {
		return callApplySavedUp();
	}).then(function(res) {
		if (!res || res.error)
			throw new Error((res && (res.message || res.error)) || '应用失败');
		if (res.success === false || res.skipped) {
			throw new Error(res.message || '应用失败');
		}
		if (res.auth_url)
			window.open(res.auth_url, '_blank');
		const body = [
			res.command ? ('命令: ' + res.command + '\n\n') : '',
			res.message || '已应用连接设置'
		].join('');
		ui.addNotification(null, E('pre', { style: 'white-space:pre-wrap;' }, body));
		location.reload();
	});
}

function section(title, children) {
	const nodes = [E('h3', {}, title)];
	(children || []).forEach(c => {
		if (c !== '' && c != null && c !== false)
			nodes.push(c);
	});
	return E('div', { class: 'cbi-section' }, nodes);
}

function grid3Row(label, value, actions) {
	return [
		E('div', { class: 'ts-label' }, label),
		E('div', { class: 'ts-value' }, value != null ? value : ''),
		E('div', { class: 'ts-actions' }, actions != null ? actions : '')
	];
}

function grid3(rows) {
	const cells = [];
	rows.forEach(r => cells.push(...grid3Row(r[0], r[1], r[2])));
	return E('div', { class: 'ts-grid-3' }, cells);
}

function grid2Row(label, value) {
	return [
		E('div', { class: 'ts-label' }, label),
		E('div', { class: 'ts-value' }, value)
	];
}

function grid2(rows) {
	const cells = [];
	rows.forEach(r => cells.push(...grid2Row(r[0], r[1])));
	return E('div', { class: 'ts-grid-2' }, cells);
}

function settingsControl(key, placeholder, upSettings, type, options) {
	const val = upSettings[key];
	if (type === 'flag') {
		return E('input', {
			type: 'checkbox',
			'data-up-key': key,
			/* LuCI E()：false 会变成 checked="false" 仍显示勾选，须用 null */
			checked: isFlagEnabled(val) ? '' : null
		});
	}
	if (type === 'select') {
		const opts = options || [];
		const current = (val && opts.indexOf(val) >= 0) ? val : (placeholder || opts[0] || '');
		return E('select', {
			class: 'cbi-input-select ts-input',
			'data-up-key': key
		}, opts.map(function(o) {
			return E('option', {
				value: o,
				selected: (o === current) ? 'selected' : null
			}, o);
		}));
	}
	return E('input', {
		class: 'cbi-input-text ts-input',
		type: 'text',
		'data-up-key': key,
		value: val || '',
		placeholder: placeholder || ''
	});
}

function isServiceEnabled(overview) {
	return overview.enabled !== false && overview.enabled !== 0 && overview.enabled !== '0';
}

function runtimeLabel(installed, overview, status) {
	if (!installed) return E('span', { class: 'label' }, '不可用');
	if (!isServiceEnabled(overview))
		return E('span', { class: 'label' }, '已停用');
	if (overview.running && status.status === 'Starting')
		return E('span', { class: 'label warning' }, '连接中');
	if (overview.running) return E('span', { class: 'label success' }, '运行中');
	if (status.status === 'needs_login')
		return E('span', { class: 'label warning' }, '已启用（待登录）');
	return E('span', { class: 'label' }, '已停止');
}

function isLoggedInStatus(status) {
	if (status.login_status === 'logged_in')
		return true;
	if (status.logged_in === true || status.logged_in === 1)
		return true;
	if (status.login_status === 'status_error')
		return false;
	return false;
}

function statusErrorInfo(status) {
	return E('span', {}, [
		E('span', { class: 'label warning' }, '状态读取失败'),
		E('span', { class: 'ts-hint' }, status.message || '无法执行 tailscale status，请更新 tailscaled 后刷新')
	]);
}

function extractPeerPath(peer) {
	if (peer.path !== undefined && peer.path !== null && String(peer.path).length > 0)
		return String(peer.path);
	if (peer.self)
		return '';

	const online = peer.online === true || peer.online === 1 || peer.Online === true;
	if (!online)
		return '';

	const active = peer.active === true || peer.active === 1 || peer.Active === true;
	if (!active)
		return '';

	const cur = peer.CurAddr || peer.cur_addr || peer.curAddr || '';
	const relay = peer.Relay || peer.relay || '';
	const peerRelay = peer.PeerRelay || peer.peer_relay || peer.peerRelay || '';
	const tx = Number(peer.TxBytes || peer.tx_bytes || peer.tx || 0);
	const rx = Number(peer.RxBytes || peer.rx_bytes || peer.rx || 0);

	if (peerRelay)
		return 'peer_relay#' + peerRelay;
	if (cur)
		return 'direct#' + cur;
	if (active && relay)
		return 'relay#' + relay;
	return 'none';
}

function formatPathDetail(detail) {
	if (!detail)
		return '';
	return String(detail).replace(/^\[([^\]]+)\](:\d+)?$/, '$1$2');
}

function formatConnectionCell(p) {
	if (p.self)
		return E('span', { class: 'label' }, '本机');

	if (!peerIsConnected(p))
		return '-';

	const path = p.path || 'none';
	if (path === 'none' || path === '')
		return E('span', { class: 'ts-hint' }, '未建立');

	const bar = path.indexOf('#');
	const kind = bar >= 0 ? path.slice(0, bar) : path;
	const detail = bar >= 0 ? path.slice(bar + 1) : '';
	const hint = formatPathDetail(detail);

	if (kind === 'direct') {
		const attrs = { class: 'ts-path-direct-wrap' };
		if (hint)
			attrs['data-detail'] = hint;
		return E('span', attrs, E('span', { class: 'label success' }, '直连'));
	}
	if (kind === 'relay') {
		return E('span', {}, [
			E('span', { class: 'label warning' }, '中继'),
			hint ? E('span', { class: 'ts-hint ts-peer-path-detail' }, ' ' + hint) : ''
		]);
	}
	if (kind === 'peer_relay') {
		return E('span', {}, [
			E('span', { class: 'label' }, '节点中继'),
			hint ? E('span', { class: 'ts-hint ts-peer-path-detail' }, ' ' + hint) : ''
		]);
	}
	return '-';
}

function extractSubnetRoutes(peer) {
	if (peer.routes)
		return String(peer.routes).replace(/,/g, ', ');
	const allowed = peer.AllowedIPs || peer.allowedIPs;
	if (!Array.isArray(allowed))
		return '';
	const routes = allowed.filter(function(cidr) {
		return cidr && !/\/32$/.test(cidr) && !/\/128$/.test(cidr);
	});
	return routes.length ? routes.join(', ') : '';
}

function isZeroTailscaleTime(iso) {
	if (!iso)
		return true;
	return String(iso).indexOf('0001-01-01') === 0;
}

function parsePeerTime(iso) {
	if (isZeroTailscaleTime(iso))
		return NaN;
	const t = Date.parse(iso);
	return isNaN(t) ? NaN : t;
}

function peerIsConnected(p) {
	if (p.self)
		return true;
	return p.online === true || p.online === 1;
}

function formatRelativeAgo(iso) {
	if (!iso)
		return '';
	const t = Date.parse(iso);
	if (isNaN(t))
		return '';
	const sec = Math.max(0, Math.floor((Date.now() - t) / 1000));
	if (sec < 60)
		return '刚刚';
	const min = Math.floor(sec / 60);
	if (min < 60)
		return min + ' 分钟';
	const hr = Math.floor(min / 60);
	if (hr < 24)
		return hr + ' 小时';
	return Math.floor(hr / 24) + ' 天';
}

function formatPeerLastSeen(p) {
	if (!isZeroTailscaleTime(p.lastseen)) {
		const t = parsePeerTime(p.lastseen);
		if (!isNaN(t)) {
			const d = new Date(t);
			const hh = String(d.getHours()).padStart(2, '0');
			const mm = String(d.getMinutes()).padStart(2, '0');
			return hh + ':' + mm;
		}
	}
	const hint = p.status_hint || '';
	const m = hint.match(/last seen (.+)$/i);
	if (m)
		return m[1];
	return '';
}

function formatPeerStatus(p) {
	if (peerIsConnected(p))
		return '在线';
	const when = formatPeerLastSeen(p);
	return when ? ('离线，' + when) : '离线';
}

function peerStatusLabel(p) {
	if (peerIsConnected(p))
		return E('span', { class: 'label success' }, formatPeerStatus(p));
	return E('span', { class: 'label' }, formatPeerStatus(p));
}

function normalizePeers(peers) {
	if (!peers)
		return [];
	if (Array.isArray(peers))
		return peers.map(function(p) {
			return {
				name: p.name || '-',
				ip: p.ip || '-',
				os: p.os || '-',
				online: p.online === true || p.online === 1,
				active: p.active === true || p.active === 1,
				lastseen: p.lastseen || '',
				lasthandshake: p.lasthandshake || '',
				lastwrite: p.lastwrite || '',
				status_hint: p.status_hint || '',
				self: p.self === true || p.self === 1,
				routes: extractSubnetRoutes(p) || (p.routes ? String(p.routes).replace(/,/g, ', ') : ''),
				path: p.self ? '' : (p.path || extractPeerPath(p))
			};
		});
	if (typeof peers !== 'object')
		return [];

	return Object.keys(peers).map(function(id) {
		const p = peers[id] || {};
		const ip = p.ip || (Array.isArray(p.TailscaleIPs) ? p.TailscaleIPs[0] : (p.TailscaleIPs || ''));
		const name = p.name || p.hostname ||
			(p.DNSName ? String(p.DNSName).split('.')[0] : '') ||
			p.HostName || id;
		const routes = p.routes || extractSubnetRoutes(p) ||
			(Array.isArray(p.PrimaryRoutes) ? p.PrimaryRoutes.join(', ') : '');
		return {
			name: name,
			ip: String(ip).replace(/<br>/g, ', '),
			os: p.os || p.ostype || p.OS || '-',
			online: p.online === true || p.online === 1 || p.Online === true,
			active: p.active === true || p.active === 1 || p.Active === true,
			lastseen: p.lastseen || p.LastSeen || '',
			lasthandshake: p.lasthandshake || p.LastHandshake || '',
			lastwrite: p.lastwrite || p.LastWrite || '',
			status_hint: p.status_hint || '',
			self: p.self === true || p.self === 1,
			routes: routes,
			path: (p.self === true || p.self === 1) ? '' : extractPeerPath(p)
		};
	});
}

function peersTable(peers) {
	return E('table', { class: 'table ts-peers-table' }, [
		E('tr', { class: 'tr table-titles' }, [
			E('th', { class: 'th' }, 'IP'),
			E('th', { class: 'th' }, '名称'),
			E('th', { class: 'th' }, '系统'),
			E('th', { class: 'th' }, '子网路由'),
			E('th', { class: 'th' }, '连接方式'),
			E('th', { class: 'th' }, '状态')
		]),
		...peers.map(p => E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, p.ip || '-'),
			E('td', { class: 'td' }, p.name || '-'),
			E('td', { class: 'td' }, p.os || '-'),
			E('td', { class: 'td ts-peer-routes' }, p.routes || '-'),
			E('td', { class: 'td ts-peer-path' }, formatConnectionCell(p)),
			E('td', { class: 'td' }, peerStatusLabel(p))
		]))
	]);
}

function renderPeersContent(peers) {
	if (peers && peers.length)
		return peersTable(peers);
	return E('span', { class: 'label' }, '-');
}

function sessionSavedInfo() {
	return E('span', {}, [
		E('span', {}, '已绑定 Tailnet'),
		E('span', { class: 'ts-hint' }, '启用服务后自动恢复，无需重新登录')
	]);
}

const LOGIN_POLL_INTERVAL = 2000;
const LOGIN_POLL_MAX = 150;
const INSTALL_POLL_INTERVAL = 1500;
const INSTALL_POLL_MAX = 600;
const CONNECTION_POLL_INTERVAL = 2;

function loggedInUserInfo(status) {
	if (!status.ipv4 && (status.status === 'Starting' || status.status === 'running'))
		return E('span', { class: 'label warning' }, '连接中...');
	const display = status.tailnet || status.user || '-';
	return E('span', {}, display);
}

function tailscaleIpDisplay(status, canConnect, isLoggedIn) {
	if (canConnect && isLoggedIn && status.ipv4)
		return status.ipv4;
	if (canConnect && isLoggedIn && (status.status === 'Starting' || !status.ipv4))
		return E('span', { class: 'label warning' }, '连接中...');
	return '-';
}

function buildTailnetCell(installed, canConnect, isLoggedIn, statusReadFailed, sessionSaved, status) {
	if (!installed) {
		return sessionSaved ? sessionSavedInfo() :
			E('span', { class: 'label' }, '未安装');
	}
	if (statusReadFailed)
		return statusErrorInfo(status);
	if (canConnect && isLoggedIn)
		return loggedInUserInfo(status);
	if (canConnect)
		return E('button', {
			class: 'btn cbi-button-action important',
			click: ui.createHandlerFn(null, function() {
				return runTailscaleLogin();
			})
		}, '登录');
	if (sessionSaved)
		return sessionSavedInfo();
	return E('span', { class: 'label' }, '服务未运行');
}

function buildTailnetAction(installed, canConnect, isLoggedIn, statusReadFailed) {
	if (!installed || statusReadFailed || !canConnect || !isLoggedIn)
		return '';
	return E('button', {
		class: 'btn cbi-button-negative',
		click: ui.createHandlerFn(null, function() {
			return callDoLogout().then(res => {
				ui.addNotification(null, E('p', {}, res.message || ''));
				location.reload();
			});
		})
	}, '登出');
}

function overviewNeedsPoll(overview, status, installed) {
	if (!installed || !isServiceEnabled(overview))
		return false;
	if (!overview.running)
		return true;
	return connectionNeedsPoll(overview, status, installed);
}

function connectionNeedsPoll(overview, status, installed) {
	if (!installed || !overview.enabled || !overview.running)
		return false;
	if (status.login_status === 'status_error')
		return false;
	if (isLoggedInStatus(status))
		return !status.ipv4 || status.status === 'Starting' || !status.tailnet;
	return status.session_saved === true || status.session_saved === 1 ||
		status.login_status === 'session_saved';
}

function connectionGrid(rows, peers, showPeersSection) {
	const cells = [];
	rows.forEach(function(r) {
		const valueAttr = r[0] === 'Tailnet' ? { 'data-ts-connection': 'tailnet' } :
			r[0] === 'Tailscale IP' ? { 'data-ts-connection': 'tsip' } : {};
		const actionsAttr = r[0] === 'Tailnet' ? { 'data-ts-connection': 'tailnet-actions' } : {};
		cells.push(
			E('div', { class: 'ts-label' }, r[0]),
			E('div', Object.assign({ class: 'ts-value' }, valueAttr), r[1] != null ? r[1] : ''),
			E('div', Object.assign({ class: 'ts-actions' }, actionsAttr), r[2] != null ? r[2] : '')
		);
	});
	if (showPeersSection) {
		cells.push(
			E('div', { class: 'ts-label' }, '节点信息'),
			E('div', { class: 'ts-peers-value', 'data-ts-peers': '1' }, renderPeersContent(peers))
		);
	}
	return E('div', { class: 'ts-grid-3' }, cells);
}

function updateConnectionSection(overview, status, installed) {
	const canConnect = installed && overview.enabled && overview.running;
	const isLoggedIn = isLoggedInStatus(status);
	const statusReadFailed = status.login_status === 'status_error';
	const sessionSaved = status.session_saved === true || status.session_saved === 1 ||
		status.login_status === 'session_saved';

	const tailnetEl = document.querySelector('.tailscale-overview [data-ts-connection="tailnet"]');
	const tsipEl = document.querySelector('.tailscale-overview [data-ts-connection="tsip"]');
	const actionsEl = document.querySelector('.tailscale-overview [data-ts-connection="tailnet-actions"]');
	const peersEl = document.querySelector('.tailscale-overview [data-ts-peers="1"]');

	if (tailnetEl) {
		dom.content(tailnetEl, buildTailnetCell(
			installed, canConnect, isLoggedIn, statusReadFailed, sessionSaved, status));
	}
	if (tsipEl) {
		dom.content(tsipEl, tailscaleIpDisplay(status, canConnect, isLoggedIn));
	}
	if (actionsEl) {
		dom.content(actionsEl, buildTailnetAction(installed, canConnect, isLoggedIn, statusReadFailed));
	}
	if (peersEl) {
		const peers = (canConnect && isLoggedIn) ? normalizePeers(status.peers) : [];
		dom.content(peersEl, renderPeersContent(peers));
	}
}

function manageConnectionPolling(self, overview, status, installed) {
	if (self._refreshConnection)
		poll.remove(self._refreshConnection);
	if (self._refreshPeers)
		poll.remove(self._refreshPeers);
	self._peerPollActive = false;

	const canConnect = installed && overview.enabled && overview.running;
	const isLoggedIn = isLoggedInStatus(status);

	if (overviewNeedsPoll(overview, status, installed)) {
		poll.add(self._refreshConnection, CONNECTION_POLL_INTERVAL);
	} else if (canConnect && isLoggedIn) {
		self._peerPollActive = true;
		poll.add(self._refreshPeers, 10);
	}
}

function buildRuntimeToggleButton(self, overview) {
	const on = isServiceEnabled(overview);
	return E('button', {
		class: on ? 'btn cbi-button-negative' : 'btn cbi-button-apply important',
		click: ui.createHandlerFn(self, function() {
			return self._toggleService();
		})
	}, on ? '停用' : '启用');
}

function updateRuntimeSection(self, overview, status, installed) {
	const statusEl = document.querySelector('.tailscale-overview [data-ts-runtime="status"]');
	const actionEl = document.querySelector('.tailscale-overview [data-ts-runtime="action"]');

	if (statusEl)
		dom.content(statusEl, runtimeLabel(installed, overview, status));
	if (actionEl)
		dom.content(actionEl, installed ? buildRuntimeToggleButton(self, overview) : '');
}

function formatReleaseVersion(tagOrVer) {
	if (!tagOrVer)
		return '';
	const s = String(tagOrVer);
	if (s.indexOf('luci-v') === 0)
		return 'v' + s.slice(6);
	if (/^v/i.test(s))
		return s;
	if (s.indexOf(' build') > 0)
		return 'v' + s;
	return 'v' + s;
}

function buildNewVersionButton(version, clickFn) {
	return E('button', {
		class: 'btn cbi-button-apply important ts-new-version-btn',
		click: clickFn
	}, '发现新版本 ' + formatReleaseVersion(version) + '，点击更新');
}

function applyVersionUpdateHints(self, res, installed) {
	if (!res)
		return;

	const luciSlot = document.querySelector('.tailscale-overview [data-ts-luci-update="1"]');
	const tsSlot = document.querySelector('.tailscale-overview [data-ts-tailscale-update="1"]');

	if (res.plugin && (res.plugin.has_update === 1 || res.plugin.has_update === true) && luciSlot) {
		const tag = res.plugin.latest_tag || res.plugin.latest;
		const label = res.plugin.latest || tag;
		dom.content(luciSlot, buildNewVersionButton(label, ui.createHandlerFn(self, function() {
			return runLuciAppUpdate(tag);
		})));
	}

	if (installed && res.tailscale && (res.tailscale.has_update === 1 || res.tailscale.has_update === true) && tsSlot) {
		dom.content(tsSlot, buildNewVersionButton(res.tailscale.latest, ui.createHandlerFn(self, function() {
			return runTailscaleInstall(res.tailscale.latest, false);
		})));
	}
}

function runLuciAppUpdate(tag) {
	let pollTimer = null;
	let pollAttempts = 0;
	let finishedSuccess = false;
	const statusEl = E('p', { class: 'spinning' }, '正在启动插件更新...');
	const logEl = E('pre', { class: 'ts-install-log' }, '');
	const closeBtn = E('button', {
		class: 'btn cbi-button-action important',
		style: 'display:none; margin-top:0.75rem;',
		click: function(ev) {
			ev.preventDefault();
			stopPoll();
			ui.hideModal();
			if (finishedSuccess)
				location.reload();
		}
	}, '关闭');

	ui.showModal('更新插件', [ statusEl, logEl, closeBtn ]);

	function stopPoll() {
		if (pollTimer) {
			clearInterval(pollTimer);
			pollTimer = null;
		}
	}

	function updateLog(text) {
		if (text == null)
			return;
		logEl.textContent = text;
		logEl.scrollTop = logEl.scrollHeight;
	}

	function finishUpdate(success, message) {
		stopPoll();
		statusEl.className = success ? 'label success' : 'alert-message error';
		finishedSuccess = success;
		statusEl.textContent = message || (success ? '插件更新完成' : '插件更新失败');
		closeBtn.textContent = success ? '关闭并刷新页面' : '关闭';
		closeBtn.style.display = '';
	}

	function pollProgress() {
		pollAttempts++;
		return callGetLuciUpdateProgress().then(function(p) {
			if (!p)
				throw new Error('无法读取更新进度（RPC 无响应）');

			updateLog(p.log || '');

			if (p.running) {
				statusEl.className = 'spinning';
				statusEl.textContent = '正在更新插件，请稍候...';
				return;
			}
			if (p.done) {
				finishUpdate(!!p.success, p.success ? '插件更新完成' : (p.message || '插件更新失败'));
				return;
			}

			statusEl.className = 'spinning';
			statusEl.textContent = p.message || '正在启动插件更新...';

			if (pollAttempts >= INSTALL_POLL_MAX)
				finishUpdate(false, '更新超时（已等待约 ' +
					Math.round(INSTALL_POLL_MAX * INSTALL_POLL_INTERVAL / 60000) +
					' 分钟），请查看日志或刷新页面后重试');
		}).catch(function(err) {
			stopPoll();
			finishUpdate(false, (err && err.message) || '读取更新进度失败');
		});
	}

	return callRunLuciUpdate(tag).then(function(res) {
		if (!res || res.success === false)
			throw new Error((res && res.message) || '无法启动更新');
		pollTimer = setInterval(pollProgress, INSTALL_POLL_INTERVAL);
		return pollProgress();
	}).catch(function(err) {
		stopPoll();
		ui.hideModal();
		ui.addNotification(null, E('p', { class: 'alert-message error' },
			(err && err.message) || '插件更新失败'));
	});
}

function runTailscaleInstall(version, isInstall) {
	let pollTimer = null;
	let pollAttempts = 0;
	let finishedSuccess = false;
	const statusEl = E('p', { class: 'spinning' }, isInstall ? '正在启动安装...' : '正在启动更新...');
	const logEl = E('pre', { class: 'ts-install-log' }, '');
	const closeBtn = E('button', {
		class: 'btn cbi-button-action important',
		style: 'display:none; margin-top:0.75rem;',
		click: function(ev) {
			ev.preventDefault();
			stopPoll();
			ui.hideModal();
			if (finishedSuccess)
				location.reload();
		}
	}, '关闭');

	ui.showModal(isInstall ? '安装 Tailscale' : '更新 Tailscale', [
		statusEl,
		logEl,
		closeBtn
	]);

	function stopPoll() {
		if (pollTimer) {
			clearInterval(pollTimer);
			pollTimer = null;
		}
	}

	function showCloseButton(label) {
		closeBtn.textContent = label || '关闭';
		closeBtn.style.display = '';
	}

	function closeFlow(err) {
		stopPoll();
		ui.hideModal();
		if (err)
			ui.addNotification(null, E('pre', { style: 'white-space:pre-wrap;' }, err.message || String(err)));
	}

	function updateLog(text) {
		if (text == null)
			return;
		logEl.textContent = text;
		logEl.scrollTop = logEl.scrollHeight;
	}

	function finishInstall(success) {
		stopPoll();
		statusEl.className = success ? 'label success' : 'alert-message error';
		if (success) {
			finishedSuccess = true;
			statusEl.textContent = isInstall ? '安装完成' : '更新完成';
			showCloseButton('关闭并刷新页面');
		} else {
			finishedSuccess = false;
			statusEl.textContent = isInstall ? '安装失败' : '更新失败';
			showCloseButton('关闭');
		}
	}

	function pollProgress() {
		pollAttempts++;
		return callGetInstallProgress().then(function(p) {
			updateLog(p.log || '');
			if (p.running) {
				statusEl.className = 'spinning';
				statusEl.textContent = isInstall ? '正在安装，请稍候...' : '正在更新，请稍候...';
				return;
			}
			if (p.done) {
				finishInstall(!!p.success);
				return;
			}
			if (pollAttempts >= INSTALL_POLL_MAX)
				closeFlow(new Error('安装超时（已等待约 ' + Math.round(INSTALL_POLL_MAX * INSTALL_POLL_INTERVAL / 60000) + ' 分钟），请查看日志或刷新页面后重试'));
		}).catch(function(err) {
			if (pollAttempts >= INSTALL_POLL_MAX)
				closeFlow(new Error((err && err.message) || '无法获取安装进度'));
		});
	}

	/*
	 * 不再前置同步调用 check_download_network：它会阻塞 ~40s 导致 XHR 超时，
	 * 且日志被丢弃看不到过程。网络检测已在后台安装脚本(luci-install.sh)内执行，
	 * 其逐步日志会写入安装日志并由 pollProgress 实时显示。
	 */
	statusEl.className = 'spinning';
	statusEl.textContent = isInstall ? '正在启动安装...' : '正在启动更新...';
	return callRunInstall(version || 'latest').then(function(res) {
		if (!res || res.success === false)
			throw new Error((res && res.message) || '无法启动安装');
		updateLog('');
		return pollProgress();
	}).then(function() {
		pollTimer = setInterval(pollProgress, INSTALL_POLL_INTERVAL);
	}).catch(function(err) {
		closeFlow(err);
	});
}

function runTailscaleLogin() {
	let pollTimer = null;
	let pollAttempts = 0;
	const statusEl = E('p', { class: 'spinning' }, '正在执行 tailscale up，生成登录链接...');
	const urlBox = E('div', { class: 'ts-login-url' });

	ui.showModal('登录 Tailscale', [
		statusEl,
		urlBox
	]);

	function stopPoll() {
		if (pollTimer) {
			clearInterval(pollTimer);
			pollTimer = null;
		}
	}

	function closeFlow(err) {
		stopPoll();
		ui.hideModal();
		if (err)
			ui.addNotification(null, E('p', {}, err.message || String(err)));
	}

	function showAuthUrl(url) {
		if (!url || urlBox.dataset.url === url)
			return;
		urlBox.dataset.url = url;
		urlBox.replaceChildren(
			E('p', {}, '请访问以下链接完成登录（可手动复制）：'),
			E('p', {
				class: 'ts-login-url-text',
				style: 'word-break:break-all; margin:0.5rem 0;'
			}, E('a', { href: url, target: '_blank', rel: 'noopener' }, url)),
			E('button', {
				class: 'btn cbi-button-action important',
				click: function(ev) {
					ev.preventDefault();
					window.open(url, '_blank');
				}
			}, '在浏览器中打开')
		);
		statusEl.textContent = '等待登录完成...';
	}

	function finishLoginSuccess() {
		stopPoll();
		ui.hideModal();
		ui.addNotification(null, E('p', {}, '登录成功。请在「连接设置」中确认参数后，手动点击「保存并应用」生效（与 helper 菜单 3 按 g 相同）。'));
		location.reload();
	}

	function pollProgress() {
		pollAttempts++;
		return callGetLoginProgress().then(function(p) {
			if (p.auth_url)
				showAuthUrl(p.auth_url);
			if (p.login_status === 'logged_in' || p.logged_in === true || p.logged_in === 1) {
				finishLoginSuccess();
				return;
			}
			if (p.done && !p.success) {
				closeFlow(new Error(p.message || '登录失败'));
				return;
			}
			if (pollAttempts >= LOGIN_POLL_MAX)
				closeFlow(new Error('登录超时，请完成浏览器认证后重试'));
		}).catch(function(err) {
			if (pollAttempts >= LOGIN_POLL_MAX) {
				closeFlow(new Error((err && err.message) || '无法获取登录状态'));
			}
		});
	}

	return callStartLogin().then(function(res) {
		if (res.already_logged_in) {
			finishLoginSuccess();
			return;
		}
		if (!res.success) {
			closeFlow(new Error(res.message || '启动登录失败'));
			return;
		}

		pollTimer = setInterval(function() {
			pollProgress();
		}, LOGIN_POLL_INTERVAL);
		return pollProgress();
	}).catch(function(err) {
		closeFlow(err);
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			rpcCall(callGetOverview(), { _rpc_failed: true }),
			rpcCall(callGetStatus(), {}),
			rpcCall(callGetUpSettings(), {})
		]);
	},

	render: function(data) {
		const overview = data[0] || {};
		const status = data[1] || {};
		const upSettings = data[2] || {};
		const rpcFailed = overview._rpc_failed === true;
		const installed = !rpcFailed && !!overview.installed;

		const settingsRoot = E('div', { id: 'tailscale-up-settings' });
		const self = this;

		self._liveOverview = overview;
		self._liveStatus = status;

		self._refreshPeers = function() {
			const peersEl = document.querySelector('.tailscale-overview [data-ts-peers="1"]');
			if (!peersEl)
				return Promise.resolve();
			return rpcCall(callGetStatus(), {}).then(function(st) {
				dom.content(peersEl, renderPeersContent(normalizePeers(st.peers)));
			});
		};

		self._refreshConnection = function() {
			return Promise.all([
				rpcCall(callGetOverview(), {}),
				rpcCall(callGetStatus(), {})
			]).then(function(res) {
				self._liveOverview = res[0] || {};
				self._liveStatus = res[1] || {};
				const inst = !!self._liveOverview.installed;
				updateRuntimeSection(self, self._liveOverview, self._liveStatus, inst);
				updateConnectionSection(self._liveOverview, self._liveStatus, inst);

				if (!overviewNeedsPoll(self._liveOverview, self._liveStatus, inst)) {
					poll.remove(self._refreshConnection);
					const canConnect = inst && self._liveOverview.enabled && self._liveOverview.running;
					const isLoggedIn = isLoggedInStatus(self._liveStatus);
					if (canConnect && isLoggedIn && !self._peerPollActive) {
						self._peerPollActive = true;
						poll.add(self._refreshPeers, 10);
					}
				}
			});
		};

		self._toggleService = function() {
			const ov = self._liveOverview || {};
			const enabling = !isServiceEnabled(ov);
			const actionWrap = document.querySelector('.tailscale-overview [data-ts-runtime="action"]');
			const statusEl = document.querySelector('.tailscale-overview [data-ts-runtime="status"]');
			const btn = actionWrap ? actionWrap.querySelector('button') : null;

			if (btn)
				btn.disabled = true;
			if (statusEl)
				dom.content(statusEl, E('span', { class: 'spinning' }, enabling ? '正在启用...' : '正在停用...'));

			return callSetServiceEnabled(enabling).then(function(res) {
				if (res && res.success === false)
					throw new Error(res.message || '操作失败');
				self._liveOverview = Object.assign({}, self._liveOverview || ov, {
					enabled: enabling,
					running: res && res.running === true
				});
				return Promise.all([
					rpcCall(callGetOverview(), {}),
					rpcCall(callGetStatus(), {})
				]);
			}).then(function(res) {
				self._liveOverview = res[0] || self._liveOverview || {};
				self._liveStatus = res[1] || {};
				const inst = !!self._liveOverview.installed;
				updateRuntimeSection(self, self._liveOverview, self._liveStatus, inst);
				updateConnectionSection(self._liveOverview, self._liveStatus, inst);
				manageConnectionPolling(self, self._liveOverview, self._liveStatus, inst);
			}).catch(function(err) {
				ui.addNotification(null, E('p', { class: 'alert-message error' },
					(err && err.message) || '操作失败'));
				updateRuntimeSection(self, self._liveOverview || ov, self._liveStatus || status, installed);
			}).finally(function() {
				const b = actionWrap ? actionWrap.querySelector('button') : null;
				if (b)
					b.disabled = false;
			});
		};

		function doInstallOrUpdate(version) {
			return runTailscaleInstall(version || 'latest', !installed);
		}

		function doUninstall() {
			if (!confirm('确定要卸载 Tailscale 吗？')) return;
			ui.showModal('正在卸载', [E('p', { class: 'spinning' }, '请稍候...')]);
			return callRunUninstall().then(res => {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, res.message || ''));
				if (res.success) location.reload();
			});
		}

		/* 1. 版本信息 — 3 列 */
		const luciVer = formatReleaseVersion(overview.luci_version || UI_REV);
		const luciUpdateSlot = E('span', { 'data-ts-luci-update': '1' });
		const tsUpdateSlot = E('span', { 'data-ts-tailscale-update': '1' });
		let versionRows;

		if (!installed) {
			versionRows = [
				['插件版本', luciVer, luciUpdateSlot],
				['Tailscale', E('button', {
					class: 'btn cbi-button-apply important',
					click: ui.createHandlerFn(self, function() {
						return doInstallOrUpdate('latest');
					})
				}, '安装 Tailscale'), '']
			];
		} else {
			versionRows = [
				['插件版本', luciVer, luciUpdateSlot],
				['Tailscale', E('span', {}, overview.version || status.version || '-'), [
					tsUpdateSlot,
					E('button', {
						class: 'btn cbi-button-negative',
						click: ui.createHandlerFn(self, function() {
							return doUninstall();
						})
					}, '卸载')
				]]
			];
		}

		const versionModule = section('版本信息', [
			rpcFailed ? E('div', { class: 'alert-message error' }, '无法连接后端，请执行 /etc/init.d/rpcd restart 后刷新') : '',
			grid3(versionRows)
		]);

		/* 2. 运行状态 — 3 列 */
		const runtimeAction = installed ? buildRuntimeToggleButton(self, overview) : '';

		const runtimeModule = section('运行状态', [
			E('div', { class: 'ts-grid-3' }, [
				E('div', { class: 'ts-label' }, '状态'),
				E('div', { class: 'ts-value', 'data-ts-runtime': 'status' },
					runtimeLabel(installed, overview, status)),
				E('div', { class: 'ts-actions', 'data-ts-runtime': 'action' }, runtimeAction)
			])
		]);

		/* 3. 连接状态 — 3 列 */
		const canConnect = installed && overview.enabled && overview.running;
		const isLoggedIn = isLoggedInStatus(status);
		const statusReadFailed = status.login_status === 'status_error';
		const sessionSaved = status.session_saved === true || status.session_saved === 1 ||
			status.login_status === 'session_saved';

		const tailnetValue = buildTailnetCell(
			installed, canConnect, isLoggedIn, statusReadFailed, sessionSaved, status);
		const tailnetAction = buildTailnetAction(
			installed, canConnect, isLoggedIn, statusReadFailed);

		const peers = normalizePeers(status.peers);

		const connectionModule = section('连接状态', [
			connectionGrid([
				['Tailnet', tailnetValue, tailnetAction],
				['Tailscale IP', tailscaleIpDisplay(status, canConnect, isLoggedIn), '']
			], peers, installed)
		]);

		manageConnectionPolling(self, overview, status, installed);

		/* 4. 连接设置 — 2 列，与上面前两列对齐 */
		let settingsModule;
		if (installed) {
			const settingsRows = SETTINGS_FIELDS.map(f =>
				[settingsLabel(f[1], f[2]), settingsControl(f[0], f[3], upSettings, f[4], f[5])]
			);
			settingsRoot.appendChild(grid2(settingsRows));
			settingsModule = section('连接设置 (tailscale up)', [
				settingsRoot,
				E('div', { class: 'ts-field-actions' }, [
					E('button', {
						class: 'btn cbi-button-save',
						click: ui.createHandlerFn(self, function() {
							const settings = collectUpSettings(settingsRoot);
							return callSetUpSettings(settings).then(function(res) {
								if (!res || res.success === false || res.error)
									throw new Error((res && (res.message || res.error)) || '保存失败');
								applyUpSettingsToForm(settingsRoot, res.settings || settings);
								ui.addNotification(null, E('p', {}, '设置已保存。'));
							}).catch(function(err) {
								ui.addNotification(null, E('p', { class: 'alert-message error' },
									(err && err.message) || '保存失败'));
							});
						})
					}, '保存'),
					E('button', {
						class: 'btn cbi-button-apply important',
						click: ui.createHandlerFn(self, function() {
							const settings = collectUpSettings(settingsRoot);
							return saveAndConfirmApplyUp(settings, settingsRoot).catch(function(err) {
								if ((err && err.message) === '已取消')
									return;
								ui.addNotification(null, E('pre', { class: 'alert-message error', style: 'white-space:pre-wrap;' },
									(err && err.message) || '应用失败'));
							});
						})
					}, '保存并应用')
				])
			]);
		} else {
			settingsModule = section('连接设置 (tailscale up)', [
				grid2([['说明', '安装 Tailscale 后可配置。']])
			]);
		}

		const modules = [
			E('link', { rel: 'stylesheet', href: L.resource('view/tailscale/overview.css') + '?v=' + CSS_REV }),
			versionModule,
			runtimeModule,
			connectionModule,
			settingsModule
		];

		if (!rpcFailed) {
			setTimeout(function() {
				rpcCall(callCheckUpdates(), {}).then(function(res) {
					applyVersionUpdateHints(self, res, installed);
				});
			}, 0);
		}

		return E('div', { class: 'tailscale-overview' }, modules);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleRemove: function() {
		if (this._refreshConnection)
			poll.remove(this._refreshConnection);
		if (this._refreshPeers)
			poll.remove(this._refreshPeers);
	}
});
