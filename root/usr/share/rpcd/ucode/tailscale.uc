#!/usr/bin/env ucode

'use strict';

import { access, popen, readfile, writefile } from 'fs';
import { cursor } from 'uci';

const uci = cursor();

const INSTALL_CONF = '/etc/tailscale/install.conf';
const UP_CONF = '/etc/tailscale/tailscale_up.conf';
const VERSION_FILE = '/etc/tailscale/current_version';
const LUCID_APP_VERSION_FILE = '/etc/tailscale/luci-app.version';
const LUCID_INSTALL = '/etc/tailscale/luci-install.sh';
const LUCID_INSTALL_BG = '/etc/tailscale/luci-install-bg.sh';
const CHECK_NETWORK = '/etc/tailscale/check_network.sh';
const LUCID_LOGIN = '/etc/tailscale/luci-login.sh';
const LUCID_APPLY_UP = '/etc/tailscale/luci-apply-up.sh';
const APPLY_LOG = '/tmp/tailscale_luci_apply.log';
const LUCID_UNINSTALL = '/etc/tailscale/luci-uninstall.sh';
const LUCID_LIST_PEERS = '/etc/tailscale/luci-list-peers.sh';
const STATUS_JSON_TMP = '/tmp/tailscale_luci_status.json';

const PATHS = {
	binary: '/usr/local/bin/tailscaled',
	cli: '/usr/bin/tailscale',
	install_conf: INSTALL_CONF,
	up_conf: UP_CONF,
	state_file: '/etc/config/tailscaled.state',
	version_file: VERSION_FILE,
	service: '/etc/init.d/tailscale',
	uci_config: '/etc/config/tailscale'
};

const RELEASE_CONF = '/etc/tailscale/release.conf';
const DEFAULT_RELEASE_REPO = 'YOUR_GITHUB_USER/luci-app-tailscale';

function read_release_repo() {
	if (!access(RELEASE_CONF))
		return DEFAULT_RELEASE_REPO;

	let content = readfile(RELEASE_CONF);
	if (content == null)
		return DEFAULT_RELEASE_REPO;

	for (let line in split(content, '\n')) {
		line = trim(line);
		if (!length(line) || match(line, /^#/))
			continue;

		let m = match(line, /^GITHUB_RELEASE_REPO=(.*)$/);
		if (m && length(trim(m[1])))
			return trim(m[1]);
	}

	return DEFAULT_RELEASE_REPO;
}

const UP_PARAMS = [
	['--accept-dns', 'flag', 'accept_dns'],
	['--accept-routes', 'flag', 'accept_routes'],
	['--advertise-exit-node', 'flag', 'advertise_exit_node'],
	['--advertise-routes', 'value', 'advertise_routes'],
	['--auth-key', 'value', 'auth_key'],
	['--exit-node', 'value', 'exit_node'],
	['--exit-node-allow-lan-access', 'flag', 'exit_node_allow_lan_access'],
	['--hostname', 'value', 'hostname'],
	['--login-server', 'value', 'login_server'],
	['--netfilter-mode', 'value', 'netfilter_mode'],
	['--shields-up', 'flag', 'shields_up'],
	['--snat-subnet-routes', 'flag', 'snat_subnet_routes'],
	['--ssh', 'flag', 'ssh']
];

/* LuCI 连接设置表单字段 */
const UP_UI_KEYS = [
	'accept_routes', 'advertise_routes', 'netfilter_mode',
	'advertise_exit_node', 'exit_node', 'exit_node_allow_lan_access',
	'shields_up', 'ssh', 'hostname', 'login_server', 'auth_key'
];

const UP_UI_FLAGS = {
	accept_routes: true,
	advertise_exit_node: true,
	exit_node_allow_lan_access: true,
	shields_up: true,
	ssh: true
};

const UP_UI_DEFAULTS = {
	accept_routes: 'false',
	netfilter_mode: 'nodivert'
};

function is_up_ui_key(name) {
	for (let i = 0; i < length(UP_UI_KEYS); i++)
		if (UP_UI_KEYS[i] == name)
			return true;
	return false;
}

function up_param_type(name) {
	for (let i = 0; i < length(UP_PARAMS); i++) {
		let def = UP_PARAMS[i];
		if (def[2] == name)
			return def[1];
	}
	return null;
}

function setting_true(val) {
	return val == true || val == 1 || val == '1' || val == 'true';
}

function valid_exit_node(val) {
	val = trim('' + (val ?? ''));
	if (!length(val))
		return false;
	if (match(val, /^[0-9]+$/))
		return false;
	return true;
}

function finalize_ui_settings(settings) {
	let out = {};
	if (settings == null)
		settings = {};

	for (let i = 0; i < length(UP_UI_KEYS); i++) {
		let name = UP_UI_KEYS[i];
		let val = settings[name];

		if (UP_UI_FLAGS[name]) {
			if (val == null || val === '' || val === false)
				val = UP_UI_DEFAULTS[name];
			out[name] = setting_true(val) ? 'true' : 'false';
		} else if (name == 'netfilter_mode') {
			val = val != null ? trim('' + val) : '';
			out[name] = length(val) ? val : (UP_UI_DEFAULTS.netfilter_mode || 'nodivert');
		} else if (name == 'exit_node' && !valid_exit_node(val))
			out[name] = '';
		else
			out[name] = (val != null && val != false && val != 0) ? trim('' + val) : '';
	}

	return out;
}

function decode_up_settings_data(raw) {
	if (raw == null)
		return finalize_ui_settings({});

	let t = type(raw);
	if (t == 'object')
		return finalize_ui_settings(raw);

	if (t == 'string') {
		let s = trim(raw);
		if (!length(s))
			return finalize_ui_settings({});
		try {
			return finalize_ui_settings(json(s));
		} catch (e) {
			return null;
		}
	}

	return finalize_ui_settings({});
}

function extract_up_settings_request(req) {
	let raw = req?.args?.data;

	if (raw == null && req?.args != null && type(req.args) == 'object') {
		for (let i = 0; i < length(UP_UI_KEYS); i++) {
			if (req.args[UP_UI_KEYS[i]] != null) {
				raw = req.args;
				break;
			}
		}
	}

	return decode_up_settings_data(raw);
}

function exec(command) {
	let stdout_lines = [];
	let p = popen(command, 'r');
	sleep(100);
	if (p == null)
		return { code: -1, stdout: [], stderr: ['exec failed'] };

	for (let line = p.read('line'); length(line); line = p.read('line'))
		push(stdout_lines, rtrim(line));

	return { code: p.close(), stdout: stdout_lines, stderr: [] };
}

function spawn(command) {
	let p = popen(`${command} >/dev/null 2>&1`, 'r');
	if (p != null)
		p.close();
}

function shell_quote(s) {
	if (s == null || s == '')
		return "''";
	return "'" + replace(s, "'", "'\\''") + "'";
}

function parse_shell_conf(path) {
	let conf = {};
	if (!access(path))
		return conf;

	let content = readfile(path);
	if (content == null)
		return conf;

	for (let line in split(content, '\n')) {
		line = trim(line);
		if (!length(line) || match(line, /^#/))
			continue;
		let m = match(line, /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
		if (m)
			conf[m[1]] = m[2];
	}
	return conf;
}

const CLI_CANDIDATES = [
	PATHS.cli,
	'/usr/sbin/tailscale',
	PATHS.binary
];

function resolve_cli() {
	for (let bin in CLI_CANDIDATES) {
		if (access(bin))
			return bin;
	}

	let r = exec('command -v tailscale 2>/dev/null');
	if (r.code == 0 && length(r.stdout) > 0 && length(trim(r.stdout[0])) > 0)
		return trim(r.stdout[0]);

	return null;
}

function is_installed() {
	if (resolve_cli())
		return true;
	if (access(PATHS.service))
		return true;
	return false;
}

function tailscale_bin() {
	return resolve_cli();
}

function tailscale_cli() {
	return resolve_cli();
}

function is_tailscale_binary_tag(tag) {
	tag = trim('' + (tag || ''));
	return length(tag) > 0 && match(tag, /^v[0-9]/);
}

function fetch_github_releases(page) {
	let repo = read_release_repo();
	let bases = [ 'https://api.github.com' ];
	let tmp = '/tmp/tailscale_releases.json';

	for (let base in bases) {
		let api = `${base}/repos/${repo}/releases?per_page=10&page=${page}`;
		let out = exec(`curl -fsSL --connect-timeout 15 -A 'luci-app-tailscale' '${api}' -o '${tmp}' && cat '${tmp}'`);
		if (out.code != 0 || !length(out.stdout))
			continue;

		try {
			let releases = json(join('', out.stdout));
			let versions = [];
			for (let r in releases)
				if (is_tailscale_binary_tag(r?.tag_name))
					push(versions, r.tag_name);
			if (length(versions) > 0)
				return { success: true, versions: versions, page: page };
		} catch (e) { /* try next */ }
	}

	return { success: false, versions: [], message: '无法获取版本列表' };
}

function normalize_version(ver) {
	ver = trim(ver || '');
	if (length(ver) > 0 && (substr(ver, 0, 1) == 'v' || substr(ver, 0, 1) == 'V'))
		ver = substr(ver, 1);
	return ver;
}

function get_installed_version() {
	if (access(VERSION_FILE)) {
		let v = trim(readfile(VERSION_FILE) || '');
		if (length(v) > 0)
			return v;
	}
	return '';
}

function get_luci_app_version() {
	if (access(LUCID_APP_VERSION_FILE)) {
		let v = trim(readfile(LUCID_APP_VERSION_FILE) || '');
		if (length(v) > 0)
			return v;
	}
	return '';
}

function get_latest_release() {
	let repo = read_release_repo();
	let tmp = '/tmp/tailscale_releases_list.json';
	let url = `https://api.github.com/repos/${repo}/releases?per_page=30`;
	let out = exec(`curl -fsSL --connect-timeout 15 -A 'luci-app-tailscale' '${url}' -o '${tmp}' && cat '${tmp}'`);

	if (out.code != 0 || !length(out.stdout))
		return null;

	try {
		let releases = json(join('', out.stdout));
		for (let r in releases) {
			let tag = r?.tag_name;
			if (is_tailscale_binary_tag(tag))
				return tag;
		}
	} catch (e) { /* ignore */ }

	return null;
}

function read_up_settings() {
	let settings = {};
	if (!access(UP_CONF))
		return settings;

	let content = readfile(UP_CONF);
	if (content == null)
		return settings;

	for (let line in split(content, '\n')) {
		line = trim(line);
		if (!length(line) || match(line, /^#/))
			continue;

		let m = match(line, /^(--[a-z0-9-]+)="(.*)"$/);
		if (!m)
			m = match(line, /^(--[a-z0-9-]+)=(.+)$/);
		if (!m)
			continue;

		let key = m[1];
		let val = trim(m[2]);

		for (let i = 0; i < length(UP_PARAMS); i++) {
			let def = UP_PARAMS[i];
			if (def[0] == key) {
				settings[def[2]] = val;
				break;
			}
		}
	}
	return settings;
}

function get_up_settings_for_ui() {
	return finalize_ui_settings(read_up_settings());
}

function write_up_settings(partial) {
	let stored = read_up_settings();
	if (partial != null) {
		for (let i = 0; i < length(UP_UI_KEYS); i++) {
			let name = UP_UI_KEYS[i];
			stored[name] = partial[name];
		}
	}

	let ui = finalize_ui_settings(stored);
	let lines = [
		'# tailscale up 参数，由 LuCI 管理',
		'# 格式: --参数名="值"'
	];

	for (let i = 0; i < length(UP_PARAMS); i++) {
		let def = UP_PARAMS[i];
		let cli_key = def[0];
		let typ = def[1];
		let name = def[2];
		let val = is_up_ui_key(name) ? ui[name] : stored[name];

		if (is_up_ui_key(name)) {
			if (typ == 'flag')
				push(lines, `${cli_key}="${val == 'true' ? 'true' : 'false'}"`);
			else if (name == 'exit_node' && !valid_exit_node(val))
				; /* 非法 exit-node（如纯数字）不写入配置，避免 tailscale up 整体失败 */
			else if (length(val))
				push(lines, `${cli_key}="${replace(val, '"', '\\"')}"`);
			continue;
		}

		if (val == null || val == '')
			continue;

		if (typ == 'flag') {
			if (val == 'true' || val == '1' || val == true)
				push(lines, `${cli_key}="true"`);
			else if (val == 'false' || val == '0' || val == false)
				push(lines, `${cli_key}="false"`);
		} else {
			push(lines, `${cli_key}="${replace(val, '"', '\\"')}"`);
		}
	}

	writefile(UP_CONF, join('\n', lines) + '\n');
}

function build_up_command(settings, opts) {
	if (!tailscale_cli())
		return null;

	/* 与 helper / tailscale_up_generator 一致：tailscale up --key=value，不加引号 */
	let parts = [ 'tailscale', 'up' ];
	if (opts?.reset)
		push(parts, '--reset');

	for (let i = 0; i < length(UP_PARAMS); i++) {
		let def = UP_PARAMS[i];
		let cli_key = def[0];
		let typ = def[1];
		let name = def[2];
		let val = settings[name];

		if (!is_up_ui_key(name))
			continue;

		if (val == null || val == '')
			continue;

		if (name == 'exit_node' && !valid_exit_node(val))
			continue;

		if (typ == 'flag') {
			if (name == 'accept_routes')
				push(parts, cli_key + '=' + (setting_true(val) ? 'true' : 'false'));
			else if (setting_true(val))
				push(parts, cli_key + '=true');
		} else {
			push(parts, cli_key + '=' + val);
		}
	}

	return join(' ', parts);
}

function extract_auth_url(text) {
	if (text == null || !length(text))
		return '';

	let m = match(text, /https:\/\/login[^\s'"]+\/a\/[^\s'"]+/);
	if (m)
		return m[0];

	m = match(text, /https:\/\/[^\s'"]+\/a\/[0-9a-zA-Z_-]+/);
	if (m)
		return m[0];

	return '';
}

function extract_suggested_up_command(text) {
	if (text == null || !length(text))
		return '';
	let m = match(text, /tailscale up --[^\n\r]+/);
	return m ? trim(m[0]) : '';
}

function build_login_command() {
	let cli = tailscale_cli();
	if (!cli)
		return null;

	let cmd = build_up_command(finalize_ui_settings(read_up_settings()), { reset: true });
	if (cmd)
		return cmd;

	return `${cli} up --reset`;
}

function wait_tailscaled_ready() {
	for (let i = 0; i < 30; i++) {
		if (is_daemon_running() && tailscale_cli())
			return true;
		sleep(1000);
	}
	return false;
}

function run_up_from_conf() {
	if (!access(LUCID_APPLY_UP))
		return { success: false, message: '应用脚本不存在: ' + LUCID_APPLY_UP };

	let dry = exec('/bin/sh ' + LUCID_APPLY_UP + ' --dry-run 2>&1');
	let cmd = (dry.code == 0 && length(dry.stdout) > 0) ? trim(dry.stdout[0]) : '';

	let out = exec('/bin/sh ' + LUCID_APPLY_UP + ' 2>&1');
	let text = join('\n', out.stdout || []);

	return {
		success: out.code == 0,
		message: text || (out.code == 0 ? '已应用连接设置' : 'tailscale up 失败'),
		command: cmd
	};
}

function preview_up_command_from_conf() {
	if (!access(LUCID_APPLY_UP))
		return { success: false, message: '应用脚本不存在: ' + LUCID_APPLY_UP };

	if (!is_installed())
		return { success: false, message: 'Tailscale 未安装' };

	let out = exec('/bin/sh ' + LUCID_APPLY_UP + ' --dry-run 2>&1');
	let cmd = length(out.stdout) > 0 ? trim(out.stdout[0]) : trim(join('\n', out.stdout || []));

	if (out.code != 0 || !length(cmd))
		return { success: false, message: join('\n', out.stdout || []) || '无法生成 tailscale up 命令' };

	return { success: true, command: cmd };
}

function apply_saved_up(settings) {
	if (!service_enabled())
		return { success: true, skipped: true, message: '服务已停用，跳过 tailscale up' };

	if (!is_installed())
		return { success: false, message: 'Tailscale 未安装' };

	if (!wait_tailscaled_ready())
		return { success: false, message: 'tailscaled 未就绪，无法应用连接设置' };

	let ui = settings ?? finalize_ui_settings(read_up_settings());
	if (settings != null)
		write_up_settings(ui);

	return run_up_from_conf();
}

function prepare_login_cmd() {
	let cmd = build_login_command();
	if (!cmd)
		return { error: 'tailscale CLI not found' };
	return { cmd: cmd };
}

const LOGIN_LOG = '/tmp/tailscale_luci_up.log';
const LOGIN_PID_FILE = '/tmp/tailscale_luci_up.pid';
const LOGIN_RC_FILE = '/tmp/tailscale_luci_up.status';
const INSTALL_LOG = '/tmp/tailscale_luci_install.log';
const INSTALL_PID_FILE = '/tmp/tailscale_luci_install.pid';
const INSTALL_RC_FILE = '/tmp/tailscale_luci_install.status';
const LOGIN_CMD_FILE = '/tmp/tailscale_luci_up.cmd';

function extract_auth_url_from_log() {
	if (!access(LOGIN_LOG))
		return '';
	return extract_auth_url(readfile(LOGIN_LOG) || '');
}

function login_up_running() {
	if (!access(LOGIN_PID_FILE))
		return false;
	let pid = trim(readfile(LOGIN_PID_FILE) || '');
	if (!length(pid))
		return false;
	return exec(`kill -0 ${pid} 2>/dev/null`).code == 0;
}

function read_login_rc() {
	if (!access(LOGIN_RC_FILE))
		return null;
	let v = trim(readfile(LOGIN_RC_FILE) || '');
	return length(v) ? int(v) : null;
}

function install_running() {
	if (access(INSTALL_RC_FILE))
		return false;
	if (!access(INSTALL_PID_FILE))
		return false;
	let pid = trim(readfile(INSTALL_PID_FILE) || '');
	if (!length(pid))
		return false;
	return exec(`kill -0 ${pid} 2>/dev/null`).code == 0;
}

function read_install_rc() {
	if (!access(INSTALL_RC_FILE))
		return null;
	let v = trim(readfile(INSTALL_RC_FILE) || '');
	return length(v) ? int(v) : null;
}

function read_install_log() {
	if (!access(INSTALL_LOG))
		return '';
	return readfile(INSTALL_LOG) || '';
}

function login_log_has_error() {
	if (!access(LOGIN_LOG))
		return false;
	let r = exec(`grep -qiE 'failed|error|illegal instruction|segmentation fault|not found|permission denied|panic' '${LOGIN_LOG}' 2>/dev/null`);
	return r.code == 0;
}

function start_login_up(cmd) {
	writefile(LOGIN_CMD_FILE, cmd + '\n');
	if (!access(LUCID_LOGIN))
		return { ok: false, message: '登录脚本不存在: ' + LUCID_LOGIN };
	spawn(LUCID_LOGIN);
	return { ok: true };
}

function service_enabled() {
	uci.load('tailscale');
	let v = uci.get('tailscale', 'settings', 'enabled');
	return v != '0';
}

function is_daemon_running() {
	let sockets = [
		'/var/run/tailscale/tailscaled.sock',
		'/tmp/tailscaled.sock'
	];

	for (let s in sockets) {
		if (access(s))
			return true;
	}

	let p = exec('/sbin/pidof tailscaled 2>/dev/null');
	if (p.code == 0 && length(p.stdout) > 0 && length(trim(p.stdout[0])) > 0)
		return true;

	p = exec('pidof tailscaled 2>/dev/null');
	if (p.code == 0 && length(p.stdout) > 0 && length(trim(p.stdout[0])) > 0)
		return true;

	p = exec('/usr/bin/pgrep -x tailscaled 2>/dev/null');
	return p.code == 0;
}

function service_running() {
	if (!service_enabled())
		return false;
	return is_daemon_running();
}

function parse_login_status(backend_state) {
	if (backend_state == 'Running')
		return 'logged_in';
	if (backend_state == 'NeedsLogin' || backend_state == 'Stopped' ||
	    backend_state == 'NoState' || backend_state == 'Starting')
		return 'needs_login';
	if (backend_state)
		return 'needs_login';
	return 'unknown';
}

function has_saved_session() {
	if (!access(PATHS.state_file))
		return false;
	let content = readfile(PATHS.state_file);
	return content != null && length(content) > 64;
}

function json_first_ip(ips) {
	if (ips == null)
		return '';

	if (ips[0] != null)
		return trim('' + ips[0]);
	if (ips['0'] != null)
		return trim('' + ips['0']);

	for (let i in ips) {
		let ip = trim('' + ips[i]);
		if (is_tailscale_ip(ip))
			return ip;
	}
	return '';
}

function tailscale_primary_ip(status_data) {
	if (status_data == null)
		return '';

	let ip = json_first_ip(status_data.Self?.TailscaleIPs);
	if (length(ip) > 0)
		return ip;

	return json_first_ip(status_data.TailscaleIPs);
}

function tailscale_secondary_ip(status_data) {
	let ips = status_data?.Self?.TailscaleIPs;
	if (ips == null)
		ips = status_data?.TailscaleIPs;
	if (ips == null)
		return null;

	if (ips[1] != null)
		return trim('' + ips[1]);
	if (ips['1'] != null)
		return trim('' + ips['1']);
	return null;
}

function is_tailscale_ip(ip) {
	ip = trim(ip || '');
	return length(ip) > 0 && match(ip, /^100\./) != null;
}

function split_first(s, delim) {
	let parts = split(s || '', delim);
	if (parts == null || length(parts) == 0)
		return '';
	if (parts[0] != null)
		return parts[0];
	return parts['0'] || '';
}

function extract_user_from_status(status_data) {
	let uid = status_data?.Self?.UserID;
	if (uid != null) {
		let profiles = status_data?.UserProfiles;
		if (profiles != null) {
			let prof = profiles[uid];
			if (prof == null)
				prof = profiles['' + uid];
			if (prof != null) {
				let name = prof.LoginName || prof.DisplayName || '';
				if (length(name) > 0)
					return name;
			}
		}
	}

	let dns = status_data?.Self?.DNSName || '';
	if (length(dns) > 0)
		return split_first(dns, '.');

	return status_data?.Self?.HostName || '';
}

function extract_tailnet_from_status(status_data) {
	let name = status_data?.CurrentTailnet?.Name || '';
	if (length(name) > 0)
		return name;

	let dns = status_data?.Self?.DNSName || '';
	if (!length(dns))
		return '';

	let parts = split(dns, '.');
	if (length(parts) >= 3) {
		if (parts[1] != null)
			return parts[1];
		return parts['1'] || '';
	}
	return '';
}

function resolve_tailscale_socket() {
	let sockets = [
		'/var/run/tailscale/tailscaled.sock',
		'/tmp/tailscaled.sock'
	];

	for (let s in sockets) {
		if (access(s))
			return s;
	}
	return null;
}

function load_tailscale_status_json_via_api() {
	let sock = resolve_tailscale_socket();
	if (!sock)
		return null;

	let out = exec(`/bin/sh -c ${shell_quote(
		`curl -fsS --max-time 10 --unix-socket ${sock} ` +
		`'http://local-tailscaled.sock/localapi/v0/status' 2>/dev/null`
	)}`);
	let raw = join('\n', out.stdout || []);
	if (!length(trim(raw))) {
		exec(`/bin/sh -c ${shell_quote(
			`curl -fsS --max-time 10 --unix-socket ${sock} ` +
			`'http://local-tailscaled.sock/localapi/v0/status' ` +
			`-o ${shell_quote(STATUS_JSON_TMP)} 2>/dev/null`
		)}`);
		if (!access(STATUS_JSON_TMP))
			return null;
		raw = readfile(STATUS_JSON_TMP) || '';
	}

	if (!length(trim(raw)))
		return null;

	writefile(STATUS_JSON_TMP, raw);

	try {
		return json(raw);
	} catch (e) {
		return null;
	}
}

function load_tailscale_status_json(cli) {
	exec(`/bin/sh -c 'rm -f ${STATUS_JSON_TMP}'`);

	let out = exec(`/bin/sh -c ${shell_quote(`${cli} status --json --peers 2>/dev/null`)}`);
	let raw = join('\n', out.stdout || []);

	if (!length(trim(raw))) {
		out = exec(`/bin/sh -c ${shell_quote(
			`${cli} status --json --peers > ${shell_quote(STATUS_JSON_TMP)} 2>/dev/null`
		)}`);
		if (access(STATUS_JSON_TMP))
			raw = readfile(STATUS_JSON_TMP) || '';
	}

	if (!length(trim(raw)))
		return load_tailscale_status_json_via_api();

	writefile(STATUS_JSON_TMP, raw);

	try {
		return json(raw);
	} catch (e) {
		return load_tailscale_status_json_via_api();
	}
}

function last_status_error(cli) {
	let out = exec(`/bin/sh -c ${shell_quote(`${cli} status 2>&1 | head -n1; true`)}`);
	if (length(out.stdout) > 0 && length(trim(out.stdout[0])) > 0)
		return trim(out.stdout[0]);
	return 'tailscale status 失败';
}

function parse_peers_from_json_file() {
	let peers = [];

	if (!access(STATUS_JSON_TMP))
		return peers;

	let out = exec(`/bin/sh ${shell_quote(LUCID_LIST_PEERS)} ${shell_quote(STATUS_JSON_TMP)} 2>/dev/null`);
	if (out.code != 0 || !length(out.stdout))
		return peers;

	for (let line in out.stdout) {
		line = trim('' + line);
		if (!length(line))
			continue;

		let cols = split(line, '|');
		if (length(cols) < 7)
			continue;

		let id = cols[0] != null ? cols[0] : cols['0'];
		if (!length(id))
			continue;

		push(peers, {
			name: (cols[1] != null ? cols[1] : cols['1']) || '',
			ip: (cols[2] != null ? cols[2] : cols['2']) || '',
			os: (cols[3] != null ? cols[3] : cols['3']) || '',
			online: (cols[4] != null ? cols[4] : cols['4']) == 'true',
			active: (cols[5] != null ? cols[5] : cols['5']) == 'true',
			lastseen: (cols[6] != null ? cols[6] : cols['6']) || '',
			self: (cols[7] != null ? cols[7] : cols['7']) == 'true',
			routes: (cols[8] != null ? cols[8] : cols['8']) || '',
			path: (cols[9] != null ? cols[9] : cols['9']) || ''
		});
	}

	return peers;
}

function query_tailscale_status_json() {
	let cli = tailscale_cli();
	if (!cli)
		return null;

	return load_tailscale_status_json(cli);
}

function is_logged_in_from_status(status_data) {
	if (!status_data)
		return false;

	let backend = trim(status_data?.BackendState || '');
	if (backend == 'NeedsLogin')
		return false;
	if (backend == 'Running' || backend == 'Starting')
		return true;

	if (is_tailscale_ip(tailscale_primary_ip(status_data)))
		return true;

	let uid = status_data?.Self?.UserID;
	if (uid != null)
		return true;

	return false;
}

function fill_status_from_json(data, status_data) {
	let backend_state = trim(status_data?.BackendState || '');
	data.version = status_data?.Version || '';
	data.hostname = status_data?.Self?.HostName || '';
	data.ipv4 = tailscale_primary_ip(status_data);
	data.ipv6 = tailscale_secondary_ip(status_data);
	data.tailnet = extract_tailnet_from_status(status_data);
	data.user = extract_user_from_status(status_data);
	data.session_saved = has_saved_session();

	data.logged_in = is_logged_in_from_status(status_data);
	if (!data.logged_in && is_tailscale_ip(data.ipv4))
		data.logged_in = true;
	data.login_status = data.logged_in ? 'logged_in' :
		parse_login_status(backend_state);
	data.status = data.logged_in ?
		(backend_state == 'Starting' ? 'Starting' : 'running') :
		(data.login_status == 'needs_login' ? 'needs_login' : (backend_state || 'unknown'));
}

function status_when_daemon_down(data) {
	data.status = 'stopped';
	data.session_saved = has_saved_session();
	data.login_status = service_enabled() ? 'service_stopped' : 'service_disabled';
	if (data.session_saved)
		data.login_status = 'session_saved';
}

function status_when_status_unavailable(data, cli) {
	data.session_saved = has_saved_session();
	data.logged_in = false;

	if (!is_daemon_running()) {
		status_when_daemon_down(data);
		return;
	}

	data.status = 'status_error';
	data.login_status = 'status_error';
	data.message = last_status_error(cli) +
		'。请重新运行 GitHub Actions 编译 Release，并在 LuCI 中重装 tailscaled + tailscale CLI。';
}

const methods = {};

methods.get_overview = {
	call: function() {
		uci.load('tailscale');
		let installed = is_installed();
		let version = get_installed_version();

		return {
			installed: installed,
			enabled: service_enabled(),
			running: service_running(),
			version: version,
			luci_version: get_luci_app_version()
		};
	}
};

methods.get_status = {
	call: function() {
		let data = {
			status: 'not_installed',
			login_status: 'not_installed',
			logged_in: false,
			session_saved: false,
			message: '',
			version: '',
			ipv4: '',
			ipv6: '',
			hostname: '',
			tailnet: '',
			user: '',
			peers: []
		};

		if (!is_installed()) {
			data.login_status = 'not_installed';
			data.session_saved = has_saved_session();
			if (data.session_saved)
				data.login_status = 'session_saved';
			return data;
		}

		let cli = tailscale_cli();
		if (!cli) {
			data.status = 'error';
			data.login_status = 'error';
			return data;
		}

		let status_data = load_tailscale_status_json(cli);
		if (status_data == null) {
			status_when_status_unavailable(data, cli);
			return data;
		}

		try {
			fill_status_from_json(data, status_data);
		} catch (e) {
			data.status = 'error';
			data.login_status = 'error';
			data.message = '' + e;
		}

		data.peers = parse_peers_from_json_file();
		return data;
	}
};

methods.list_versions = {
	args: { page: 1 },
	call: function(req) {
		let page = int(req?.args?.page) || 1;
		return fetch_github_releases(page);
	}
};

methods.check_update = {
	call: function() {
		let current = get_installed_version();
		let latest = get_latest_release();

		if (!latest)
			return { success: false, message: '无法获取最新版本，请检查网络' };

		if (!length(current))
			return { success: false, message: '未检测到已安装版本' };

		let has_update = normalize_version(current) != normalize_version(latest);

		return {
			success: true,
			current: current,
			latest: latest,
			has_update: has_update,
			message: has_update ? ('新版本：' + latest) : '已是最新版'
		};
	}
};

function parse_keyval_lines(text) {
	let out = {};
	let lines = [];

	if (text == null)
		return out;

	if (type(text) == 'array')
		lines = text;
	else {
		let s = trim('' + text);
		if (!length(s))
			return out;
		lines = split(s, '\n');
	}

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);
		if (!length(line))
			continue;
		let m = match(line, /^([^=]+)=(.*)$/);
		if (m)
			out[m[1]] = m[2];
	}
	return out;
}

methods.check_download_network = {
	call: function() {
		if (!access(CHECK_NETWORK))
			return { ok: false, message: '网络检测脚本不存在: ' + CHECK_NETWORK };

		let r = exec('/bin/sh ' + CHECK_NETWORK + ' --quick 2>&1');
		let kv = parse_keyval_lines(r.stdout);

		return {
			ok: kv.ok == '1',
			internet: kv.internet == '1',
			https: kv.https == '1',
			github: kv.github == '1',
			mirror: kv.mirror == '1',
			mirror_prefix: kv.mirror_prefix || '',
			message: kv.message || '网络检测失败'
		};
	}
};

methods.run_install = {
	args: { version: 'latest' },
	call: function(req) {
		let version = req?.args?.version || 'latest';

		if (!access(LUCID_INSTALL_BG))
			return { success: false, message: '安装脚本不存在: ' + LUCID_INSTALL_BG };

		if (install_running())
			return { success: true, started: false, running: true, message: '安装正在进行中' };

		uci.set('tailscale', 'settings', 'version', version);
		uci.set('tailscale', 'settings', 'enabled', '1');
		uci.commit('tailscale');

		spawn(`${LUCID_INSTALL_BG} false ${shell_quote(version)}`);

		return { success: true, started: true, running: true, message: '安装已启动' };
	}
};

methods.get_install_progress = {
	call: function() {
		let log_text = trim(read_install_log());
		let running = install_running();
		let rc = read_install_rc();
		let done = !running && rc != null;

		if (done) {
			return {
				running: false,
				done: true,
				success: rc == 0,
				log: log_text,
				message: rc == 0 ?
					'安装成功' :
					(log_text || ('安装失败，退出码 ' + rc))
			};
		}

		if (running)
			return {
				running: true,
				done: false,
				success: false,
				log: log_text,
				message: log_text ? '安装中...' : '正在启动安装...'
			};

		return {
			running: false,
			done: false,
			success: false,
			log: log_text,
			message: '未检测到进行中的安装'
		};
	}
};

methods.run_uninstall = {
	call: function() {
		if (!access(LUCID_UNINSTALL))
			return { success: false, message: '卸载脚本不存在: ' + LUCID_UNINSTALL };

		let out = exec(`${LUCID_UNINSTALL} 2>&1`);
		return {
			success: out.code == 0,
			message: join('\n', out.stdout || []) || (out.code == 0 ? '卸载成功' : '卸载失败')
		};
	}
};

methods.get_up_settings = {
	call: function() {
		try {
			return get_up_settings_for_ui();
		} catch (e) {
			return { error: '' + e };
		}
	}
};

methods.set_up_settings = {
	args: { data: {} },
	call: function(req) {
		let settings = extract_up_settings_request(req);
		if (settings == null)
			return { success: false, message: '无法解析连接设置数据' };

		write_up_settings(settings);
		return { success: true, settings: get_up_settings_for_ui() };
	}
};

methods.preview_up_command = {
	args: { data: {} },
	call: function(req) {
		let settings = extract_up_settings_request(req);
		if (settings == null)
			return { success: false, message: '无法解析连接设置数据' };

		write_up_settings(settings);

		let preview = preview_up_command_from_conf();
		if (!preview.success)
			return preview;

		return {
			success: true,
			command: preview.command,
			settings: get_up_settings_for_ui()
		};
	}
};

methods.apply_up_settings = {
	args: { data: {} },
	call: function(req) {
		let settings = extract_up_settings_request(req);
		if (settings == null)
			return { success: false, message: '无法解析连接设置数据' };

		write_up_settings(settings);

		let up = apply_saved_up(settings);
		let auth_url = extract_auth_url(up.message || '');

		return {
			success: up.success,
			message: up.message,
			command: up.command,
			auth_url: auth_url,
			settings: get_up_settings_for_ui()
		};
	}
};

methods.apply_saved_up = {
	call: function() {
		return apply_saved_up(null);
	}
};

methods.start_login = {
	call: function() {
		let prep = prepare_login_cmd();
		if (prep.error)
			return { success: false, message: prep.error };

		if (!login_up_running()) {
			let started = start_login_up(prep.cmd);
			if (!started.ok)
				return { success: false, message: started.message };
		}

		return { success: true, started: true, command: prep.cmd };
	}
};

methods.get_login_progress = {
	call: function() {
		let auth_url = extract_auth_url_from_log();
		let up_running = login_up_running();
		let rc = read_login_rc();

		let status_data = query_tailscale_status_json();
		if (!length(auth_url) && status_data)
			auth_url = trim(status_data?.AuthURL || '');

		let login_status = status_data ?
			(is_logged_in_from_status(status_data) ? 'logged_in' :
			 parse_login_status(status_data?.BackendState || '')) : 'unknown';

		if (login_status == 'logged_in')
			return {
				success: true,
				login_status: 'logged_in',
				logged_in: true,
				auth_url: auth_url,
				up_running: up_running,
				done: true,
				message: '登录成功'
			};

		if (login_log_has_error()) {
			let log_text = trim(readfile(LOGIN_LOG) || '');
			let suggested = extract_suggested_up_command(log_text);
			return {
				success: false,
				login_status: 'failed',
				auth_url: '',
				up_running: up_running,
				done: true,
				message: suggested ?
					('tailscale up 失败，请保存连接设置后重试。建议命令：' + suggested) :
					(log_text || 'tailscale up 执行失败')
			};
		}

		if (!up_running && rc != null && rc != 0 && !length(auth_url))
			return {
				success: false,
				login_status: 'failed',
				auth_url: '',
				up_running: false,
				done: true,
				message: trim(readfile(LOGIN_LOG) || '') || ('tailscale up 失败，退出码 ' + rc)
			};

		return {
			success: true,
			login_status: login_status,
			auth_url: auth_url,
			up_running: up_running,
			done: false,
			waiting_auth: length(auth_url) > 0
		};
	}
};

methods.do_login = {
	call: function() {
		return methods.start_login.call();
	}
};

methods.do_logout = {
	call: function() {
		let cli = tailscale_cli();
		if (!cli)
			return { success: false, message: 'tailscale CLI not found' };

		let out = exec(`${cli} logout 2>&1`);
		return {
			success: out.code == 0,
			message: join('\n', out.stdout || []) || (out.code == 0 ? 'Logged out' : 'Logout failed')
		};
	}
};

methods.set_service_enabled = {
	args: { enabled: true },
	call: function(req) {
		let enabled = req?.args?.enabled;
		let on = !(enabled == false || enabled == 'false' || enabled == '0' || enabled == 0);

		uci.set('tailscale', 'settings', 'enabled', on ? '1' : '0');
		uci.commit('tailscale');

		if (!access('/etc/init.d/tailscale'))
			return { success: false, message: '请先安装 Tailscale' };

		let action = on ? 'start' : 'stop';
		if (on)
			exec('/etc/init.d/tailscale enable 2>&1');

		let out = exec(`/etc/init.d/tailscale ${action} 2>&1`);
		return {
			success: out.code == 0,
			enabled: on,
			running: service_running(),
			message: join('\n', out.stdout || []) || (on ? '已启用' : '已停用')
		};
	}
};

return { 'tailscale': methods };
