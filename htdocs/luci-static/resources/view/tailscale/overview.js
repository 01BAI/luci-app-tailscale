'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

const SETTINGS_FIELDS = [
	['accept_routes', '接受路由', '--accept-routes', '', 'flag'],
	['advertise_routes', '宣告路由', '--advertise-routes', '192.168.1.0/24', 'value'],
	['netfilter_mode', 'Netfilter 模式', '--netfilter-mode', 'on', 'select', ['on', 'nodivert', 'off']],
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
const callCheckUpdate = rpc.declare({ object: 'tailscale', method: 'check_update' });
const callGetUpSettings = rpc.declare({ object: 'tailscale', method: 'get_up_settings' });
const callSetUpSettings = rpc.declare({ object: 'tailscale', method: 'set_up_settings', params: [ 'data' ] });
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

function riskySettingsWarning(settings) {
	const parts = [];
	if (settings.exit_node && settings.exit_node.trim())
		parts.push('出口节点：' + settings.exit_node.trim() + '（可能使本机无法从局域网访问）');
	if (settings.accept_routes === 'true')
		parts.push('接受路由：已启用（可能与本地网段/默认路由冲突）');
	if (settings.advertise_exit_node === 'true')
		parts.push('宣告出口节点：已启用');
	return parts.length ? parts.join('\n') : '';
}

function confirmApplySettings(settings) {
	const warn = riskySettingsWarning(settings);
	if (!warn)
		return true;
	return confirm(
		'以下设置可能影响路由器本机网络，错误配置会导致 LuCI/SSH 无法访问：\n\n' +
		warn + '\n\n仍要立即应用吗？'
	);
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

function runtimeLabel(installed, overview, status) {
	if (!installed) return E('span', { class: 'label' }, '不可用');
	if (overview.running && status.status === 'Starting')
		return E('span', { class: 'label warning' }, '连接中');
	if (overview.running) return E('span', { class: 'label success' }, '运行中');
	if (status.status === 'needs_login' && overview.enabled)
		return E('span', { class: 'label warning' }, '已启用（待登录）');
	if (overview.enabled === false)
		return E('span', { class: 'label' }, '已停用');
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

function loggedInUserInfo(status) {
	const display = status.tailnet || status.user || '-';
	return E('span', {}, display);
}

function normalizePeers(peers) {
	if (!peers)
		return [];
	if (Array.isArray(peers))
		return peers;
	if (typeof peers !== 'object')
		return [];

	return Object.keys(peers).map(function(id) {
		const p = peers[id] || {};
		const ip = p.ip || (Array.isArray(p.TailscaleIPs) ? p.TailscaleIPs[0] : (p.TailscaleIPs || ''));
		const name = p.name || p.hostname ||
			(p.DNSName ? String(p.DNSName).split('.')[0] : '') ||
			p.HostName || id;
		return {
			name: name,
			ip: String(ip).replace(/<br>/g, ', '),
			os: p.os || p.ostype || p.OS || '-',
			online: p.online === true || p.online === 1 || p.Online === true,
			active: p.active === true || p.active === 1 || p.Active === true,
			lastseen: p.lastseen || p.LastSeen || '',
			self: p.self === true || p.self === 1
		};
	});
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

function formatPeerStatus(p) {
	if (p.online || p.active)
		return '在线';
	if (p.lastseen) {
		const ago = formatRelativeAgo(p.lastseen);
		return ago ? ('离线，' + ago + '前活跃') : '离线';
	}
	return '离线';
}

function peersTable(peers) {
	return E('table', { class: 'table ts-peers-table' }, [
		E('tr', { class: 'tr table-titles' }, [
			E('th', { class: 'th' }, 'IP'),
			E('th', { class: 'th' }, '名称'),
			E('th', { class: 'th' }, '系统'),
			E('th', { class: 'th' }, '状态')
		]),
		...peers.map(p => E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, p.ip || '-'),
			E('td', { class: 'td' }, p.name || '-'),
			E('td', { class: 'td' }, p.os || '-'),
			E('td', { class: 'td' }, (p.online || p.active)
				? E('span', { class: 'label success' }, formatPeerStatus(p))
				: E('span', { class: 'label' }, formatPeerStatus(p)))
		]))
	]);
}

function renderPeersContent(peers) {
	if (peers && peers.length)
		return peersTable(peers);
	return E('span', { class: 'label' }, '-');
}

function connectionGrid(rows, peers, showPeersRow) {
	const cells = [];
	rows.forEach(r => cells.push(...grid3Row(r[0], r[1], r[2])));
	if (showPeersRow) {
		cells.push(
			E('div', { class: 'ts-label' }, '节点信息'),
			E('div', { class: 'ts-peers-value', 'data-ts-peers': '1' }, renderPeersContent(peers))
		);
	}
	return E('div', { class: 'ts-grid-3' }, cells);
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
const STATUS_POLL_INTERVAL = 10;

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
		let pendingLatest = null;
		const self = this;

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
		const hintEl = E('span', { class: 'ts-hint' });
		let versionRows;

		if (!installed) {
			versionRows = [[
				'当前版本',
				E('button', {
					class: 'btn cbi-button-apply important',
					click: ui.createHandlerFn(self, function() {
						return doInstallOrUpdate('latest');
					})
				}, '安装 Tailscale'),
				''
			]];
		} else {
			const actionBtn = E('button', { class: 'btn cbi-button-action' }, '检测更新');
			actionBtn.addEventListener('click', function(ev) {
				ev.preventDefault();
				if (pendingLatest) {
					doInstallOrUpdate(pendingLatest);
					return;
				}
				actionBtn.disabled = true;
				actionBtn.textContent = '检测中...';
				hintEl.textContent = '';
				callCheckUpdate().then(res => {
					actionBtn.disabled = false;
					if (!res.success) {
						hintEl.textContent = res.message || '检测失败';
						actionBtn.textContent = '检测更新';
						return;
					}
					hintEl.textContent = res.message || '';
					if (res.has_update) {
						pendingLatest = res.latest;
						actionBtn.textContent = '更新';
						actionBtn.className = 'btn cbi-button-apply important';
					} else {
						pendingLatest = null;
						actionBtn.textContent = '检测更新';
						actionBtn.className = 'btn cbi-button-action';
					}
				});
			});
			versionRows = [[
				'当前版本',
				E('span', {}, [
					E('span', {}, overview.version || status.version || '-'),
					hintEl
				]),
				[
					actionBtn,
					E('button', {
						class: 'btn cbi-button-negative',
						click: ui.createHandlerFn(self, function() {
							return doUninstall();
						})
					}, '卸载')
				]
			]];
		}

		const versionModule = section('版本信息', [
			rpcFailed ? E('div', { class: 'alert-message error' }, '无法连接后端，请执行 /etc/init.d/rpcd restart 后刷新') : '',
			grid3(versionRows)
		]);

		/* 2. 运行状态 — 3 列 */
		const runtimeAction = installed ? E('button', {
			class: overview.running ? 'btn cbi-button-negative' : 'btn cbi-button-apply important',
			click: ui.createHandlerFn(self, function() {
				return callSetServiceEnabled(!overview.running).then(res => {
					ui.addNotification(null, E('p', {}, res.message || ''));
					location.reload();
				});
			})
		}, overview.running ? '停用' : '启用') : '';

		const runtimeModule = section('运行状态', [
			grid3([[
				'状态',
				runtimeLabel(installed, overview, status),
				runtimeAction
			]])
		]);

		/* 3. 连接状态 — 3 列 */
		const canConnect = installed && overview.enabled && overview.running;
		const isLoggedIn = isLoggedInStatus(status);
		const statusReadFailed = status.login_status === 'status_error';
		const sessionSaved = status.session_saved === true || status.session_saved === 1 ||
			status.login_status === 'session_saved';

		const loginBtn = E('button', {
			class: 'btn cbi-button-action important',
			click: ui.createHandlerFn(self, function() {
				return runTailscaleLogin();
			})
		}, '登录');

		const logoutBtn = E('button', {
			class: 'btn cbi-button-negative',
			click: ui.createHandlerFn(self, function() {
				return callDoLogout().then(res => {
					ui.addNotification(null, E('p', {}, res.message || ''));
					location.reload();
				});
			})
		}, '登出');

		let tailnetValue;
		let tailnetAction = '';

		if (!installed) {
			tailnetValue = sessionSaved ? sessionSavedInfo() :
				E('span', { class: 'label' }, '未安装');
		} else if (statusReadFailed) {
			tailnetValue = statusErrorInfo(status);
		} else if (canConnect && isLoggedIn) {
			tailnetValue = loggedInUserInfo(status);
			tailnetAction = logoutBtn;
		} else if (canConnect) {
			tailnetValue = loginBtn;
		} else if (sessionSaved) {
			tailnetValue = sessionSavedInfo();
		} else {
			tailnetValue = E('span', { class: 'label' }, '服务未运行');
		}

		const showTailscaleIp = canConnect && isLoggedIn && status.ipv4;

		const peers = normalizePeers(status.peers);
		const showPeersRow = installed && canConnect && isLoggedIn;

		const connectionModule = section('连接状态', [
			connectionGrid([
				['Tailnet', tailnetValue, tailnetAction],
				['Tailscale IP', showTailscaleIp ? status.ipv4 : '-', '']
			], peers, showPeersRow)
		]);

		if (showPeersRow) {
			self._refreshPeers = function() {
				const wrap = document.querySelector('.tailscale-overview [data-ts-peers="1"]');
				if (!wrap)
					return Promise.resolve();
				return rpcCall(callGetStatus(), {}).then(function(st) {
					dom.content(wrap, renderPeersContent(normalizePeers(st.peers)));
				});
			};
			poll.add(self._refreshPeers, STATUS_POLL_INTERVAL);
		}

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
							if (!confirmApplySettings(settings))
								return;
							return callApplyUpSettings(settings).then(function(res) {
								if (!res || res.error)
									throw new Error((res && (res.message || res.error)) || '应用失败');
								if (res.success === false) {
									ui.addNotification(null, E('pre', { class: 'alert-message error' }, [
										res.command ? ('命令: ' + res.command + '\n\n') : '',
										res.message || '应用失败'
									].join('')));
									return;
								}
								if (res.auth_url) window.open(res.auth_url, '_blank');
								ui.addNotification(null, E('pre', {}, [
									res.command ? ('命令: ' + res.command + '\n\n') : '',
									res.message || '已应用连接设置'
								].join('')));
								location.reload();
							}).catch(function(err) {
								ui.addNotification(null, E('p', { class: 'alert-message error' },
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
			E('link', { rel: 'stylesheet', href: L.resource('view/tailscale/overview.css') }),
			versionModule,
			runtimeModule,
			connectionModule,
			settingsModule
		];

		return E('div', { class: 'tailscale-overview' }, modules);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleRemove: function() {
		if (this._refreshPeers)
			poll.remove(this._refreshPeers);
	}
});
