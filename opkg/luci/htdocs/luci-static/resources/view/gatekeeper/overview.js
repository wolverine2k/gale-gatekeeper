'use strict';
'require view';
'require ui';
'require rpc';
'require dom';
'require poll';

/* Gatekeeper — Overview page.
 * Status cards + live log tail with auto-refresh toggle.
 */

var callOverview = rpc.declare({
	object: 'gatekeeper',
	method: 'get_overview',
	expect: {}
});

var callTailLog = rpc.declare({
	object: 'gatekeeper',
	method: 'tail_log',
	params: [ 'lines' ],
	expect: {}
});

function fmtTimestamp(epoch) {
	if (!epoch || epoch === 0) return '—';
	var d = new Date(epoch * 1000);
	return d.toLocaleString();
}

function statusBadge(label, ok, okText, badText) {
	var cls = ok ? 'gk-badge gk-badge-ok' : 'gk-badge gk-badge-bad';
	var text = ok ? (okText || 'OK') : (badText || 'NOT OK');
	return E('span', { 'class': cls, 'title': label }, text);
}

function card(title, body) {
	return E('div', { 'class': 'gk-card' }, [
		E('div', { 'class': 'gk-card-title' }, title),
		E('div', { 'class': 'gk-card-body' }, body)
	]);
}

function countCard(title, count, sub) {
	var children = [
		E('div', { 'class': 'gk-card-title' }, title),
		E('div', { 'class': 'gk-card-count' }, String(count))
	];
	if (sub) children.push(E('div', { 'class': 'gk-card-sub' }, sub));
	return E('div', { 'class': 'gk-card gk-card-count-wrap' }, children);
}

return view.extend({
	load: function () {
		return Promise.all([
			callOverview(),
			callTailLog(50)
		]).catch(function (e) {
			return [{ error: String(e) }, { lines: '' }];
		});
	},

	render: function (data) {
		var overview = data[0] || {};
		var logEntry = data[1] || {};

		if (overview.error) {
			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'alert-message error' },
					_('Failed to load overview: ') + overview.error)
			]);
		}

		var counts = overview.counts || {};
		var refreshControl = E('label', { 'class': 'gk-refresh-toggle' }, [
			E('input', {
				'type': 'checkbox',
				'id': 'gk-overview-autorefresh',
				'change': function (ev) {
					if (ev.target.checked) {
						poll.add(this._poll, 5);
					} else {
						poll.remove(this._poll);
					}
				}.bind(this)
			}),
			' ', _('Auto-refresh every 5 s')
		]);

		var statusRow = E('div', { 'class': 'gk-status-row' }, [
			card(_('Bot daemon'), [
				statusBadge('tg_gatekeeper', overview.bot_running,
					_('Running'), _('Stopped')),
				E('div', { 'class': 'gk-card-sub' },
					overview.bot_running
						? _('tg_bot.sh is running')
						: _('Telegram bot is not active'))
			]),
			card(_('Firewall'), [
				statusBadge('gatekeeper_forward', overview.firewall_active,
					_('Active'), _('Disabled')),
				E('div', { 'class': 'gk-card-sub' },
					overview.firewall_active
						? _('gatekeeper_forward chain has rules')
						: _('Emergency-disabled (DISABLE flag set)'))
			]),
			card(_('System clock'), [
				statusBadge('NTP', overview.clock_synced,
					_('Synced'), _('Not synced')),
				E('div', { 'class': 'gk-card-sub' },
					overview.clock_synced
						? fmtTimestamp(overview.now_epoch)
						: _('Schedules paused until clock syncs'))
			]),
			card(_('Modes'), [
				E('div', {}, [
					statusBadge('blacklist_mode', overview.blacklist_mode,
						_('Blacklist mode ON'), _('Blacklist mode OFF'))
				]),
				E('div', { 'style': 'margin-top: 0.4em' }, [
					statusBadge('schedule_notify', overview.schedule_notify,
						_('Schedule notify ON'), _('Schedule notify OFF'))
				])
			])
		]);

		var logBox = E('pre', { 'id': 'gk-log-tail', 'class': 'gk-log-tail' },
			logEntry.lines || _('(no recent activity)'));

		this._poll = (function (logBoxRef) {
			return function () {
				return Promise.all([ callOverview(), callTailLog(50) ]).then(function (d) {
					var ov = d[0] || {};
					var lg = d[1] || {};
					// Update log
					if (logBoxRef && lg.lines !== undefined) {
						dom.content(logBoxRef, lg.lines || _('(no recent activity)'));
					}
					// Update counts (re-render is too expensive; simple text swap)
					var ids = {
						'gk-count-active': (ov.counts || {}).active,
						'gk-count-denied': (ov.counts || {}).denied,
						'gk-count-static': (ov.counts || {}).static,
						'gk-count-blacklist': (ov.counts || {}).blacklist,
						'gk-count-schedules': (ov.counts || {}).schedules
					};
					Object.keys(ids).forEach(function (id) {
						var el = document.getElementById(id);
						if (el && ids[id] !== undefined) el.textContent = String(ids[id]);
					});
				});
			};
		})(logBox);

		return E('div', {}, [
			E('style', {}, [
				'.gk-status-row, .gk-counts-row { display: flex; flex-wrap: wrap; gap: 1em; margin: 1em 0; }',
				'.gk-card { background: #fafafa; border: 1px solid #ddd; border-radius: 6px; padding: 1em; min-width: 180px; flex: 1; }',
				'.gk-card-title { font-weight: bold; margin-bottom: 0.5em; color: #333; }',
				'.gk-card-body { font-size: 0.95em; }',
				'.gk-card-count { font-size: 2em; font-weight: bold; color: #0a6; }',
				'.gk-card-sub { font-size: 0.8em; color: #666; margin-top: 0.3em; }',
				'.gk-badge { display: inline-block; padding: 0.2em 0.6em; border-radius: 3px; font-size: 0.85em; font-weight: bold; }',
				'.gk-badge-ok { background: #d4f4dd; color: #0a6; }',
				'.gk-badge-bad { background: #ffe0e0; color: #c33; }',
				'.gk-log-tail { background: #1e1e1e; color: #d4d4d4; padding: 1em; border-radius: 4px; font-family: monospace; font-size: 0.85em; max-height: 400px; overflow: auto; white-space: pre-wrap; }',
				'.gk-refresh-toggle { display: inline-block; margin: 0.5em 0; }'
			].join('\n')),
			E('h2', {}, _('Gatekeeper — Overview')),
			E('p', {}, _('Status of the Telegram-based network access control system.')),
			refreshControl,
			E('h3', {}, _('System status')),
			statusRow,
			E('h3', {}, _('Counts')),
			E('div', { 'class': 'gk-counts-row' }, [
				E('div', { 'class': 'gk-card gk-card-count-wrap' }, [
					E('div', { 'class': 'gk-card-title' }, _('Active')),
					E('div', { 'class': 'gk-card-count', 'id': 'gk-count-active' }, String(counts.active || 0)),
					E('div', { 'class': 'gk-card-sub' }, _('approved guests'))
				]),
				E('div', { 'class': 'gk-card gk-card-count-wrap' }, [
					E('div', { 'class': 'gk-card-title' }, _('Denied')),
					E('div', { 'class': 'gk-card-count', 'id': 'gk-count-denied' }, String(counts.denied || 0)),
					E('div', { 'class': 'gk-card-sub' }, _('temporarily blocked'))
				]),
				E('div', { 'class': 'gk-card gk-card-count-wrap' }, [
					E('div', { 'class': 'gk-card-title' }, _('Static')),
					E('div', { 'class': 'gk-card-count', 'id': 'gk-count-static' }, String(counts.static || 0)),
					E('div', { 'class': 'gk-card-sub' }, _('permanent whitelist'))
				]),
				E('div', { 'class': 'gk-card gk-card-count-wrap' }, [
					E('div', { 'class': 'gk-card-title' }, _('Blacklist')),
					E('div', { 'class': 'gk-card-count', 'id': 'gk-count-blacklist' }, String(counts.blacklist || 0)),
					E('div', { 'class': 'gk-card-sub' }, _('require approval'))
				]),
				E('div', { 'class': 'gk-card gk-card-count-wrap' }, [
					E('div', { 'class': 'gk-card-title' }, _('Schedules')),
					E('div', { 'class': 'gk-card-count', 'id': 'gk-count-schedules' }, String(counts.schedules || 0)),
					E('div', { 'class': 'gk-card-sub' },
						_('total') + ' · ' + (counts.active_schedules || 0) + ' ' + _('active now'))
				])
			]),
			E('h3', {}, _('Recent activity')),
			E('div', { 'style': 'margin-bottom: 0.5em;' }, [
				E('em', {}, _('Latest 50 lines of /tmp/gatekeeper.log'))
			]),
			logBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
