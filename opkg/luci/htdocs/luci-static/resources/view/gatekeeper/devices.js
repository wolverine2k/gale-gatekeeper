'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

/* Gatekeeper — Devices page.
 * Active (approved_macs) + Denied (denied_macs) + Static (static_macs)
 * tables with per-row actions (Approve/Deny/Extend/Revoke).
 */

var callListActive = rpc.declare({
	object: 'gatekeeper', method: 'list_active', expect: { devices: [] }
});
var callListDenied = rpc.declare({
	object: 'gatekeeper', method: 'list_denied', expect: { devices: [] }
});
var callListStatic = rpc.declare({
	object: 'gatekeeper', method: 'list_static', expect: { devices: [] }
});
var callApprove = rpc.declare({
	object: 'gatekeeper', method: 'approve', params: ['mac'], expect: {}
});
var callDeny = rpc.declare({
	object: 'gatekeeper', method: 'deny', params: ['mac'], expect: {}
});
var callExtend = rpc.declare({
	object: 'gatekeeper', method: 'extend', params: ['mac', 'hours'], expect: {}
});
var callRevoke = rpc.declare({
	object: 'gatekeeper', method: 'revoke', params: ['mac'], expect: {}
});
var callDeniedExtend = rpc.declare({
	object: 'gatekeeper', method: 'denied_extend', params: ['mac'], expect: {}
});
var callDeniedRevokeApprove = rpc.declare({
	object: 'gatekeeper', method: 'denied_revoke_approve', params: ['mac'], expect: {}
});

function fmtDuration(secs) {
	if (!secs || secs < 0) return '—';
	if (secs < 60) return secs + 's';
	if (secs < 3600) return Math.floor(secs / 60) + 'm' + (secs % 60) + 's';
	if (secs < 86400) {
		var h = Math.floor(secs / 3600);
		var m = Math.floor((secs % 3600) / 60);
		return h + 'h' + m + 'm';
	}
	var d = Math.floor(secs / 86400);
	var h = Math.floor((secs % 86400) / 3600);
	return d + 'd' + h + 'h';
}

function fmtExpiry(epoch) {
	if (!epoch || epoch <= 0) return '—';
	var d = new Date(epoch * 1000);
	return d.toLocaleString();
}

function showSpinner(button) {
	button.disabled = true;
	button.dataset.origText = button.textContent;
	button.textContent = '…';
}
function hideSpinner(button) {
	button.disabled = false;
	if (button.dataset.origText) button.textContent = button.dataset.origText;
}

function rowAction(label, cls, fn) {
	return E('button', {
		'class': 'btn ' + (cls || ''),
		'click': function (ev) {
			showSpinner(ev.target);
			Promise.resolve(fn(ev.target)).catch(function (e) {
				ui.addNotification(null, E('p', {}, _('Action failed: ') + String(e)), 'danger');
			}).finally(function () { hideSpinner(ev.target); });
		}
	}, label);
}

function reloadPage() {
	// Re-render via window navigation to keep things simple.
	// LuCI reloads the view module on hashchange; force re-render by
	// dispatching a reload of the current location.
	if (window.location.hash) {
		var h = window.location.hash;
		window.location.hash = '';
		window.location.hash = h;
	} else {
		window.location.reload();
	}
}

function renderActiveTable(devices) {
	if (!devices || devices.length === 0) {
		return E('em', {}, _('No active devices.'));
	}
	var headers = [_('Hostname'), _('MAC'), _('Source'), _('Remaining'), _('Expires'), _('Actions')];
	var rows = devices.map(function (d) {
		var sourceLabel = d.schedule
			? E('span', { 'class': 'gk-tag gk-tag-sched', 'title': _('Approved by schedule: ') + d.schedule },
				'⏰ ' + d.schedule)
			: E('span', { 'class': 'gk-tag gk-tag-manual' }, _('Manual'));
		var actions = E('div', { 'class': 'gk-row-actions' }, [
			rowAction(_('+30m'), 'cbi-button-positive', function () {
				return callExtend(d.mac, 0).then(reloadPage);
			}),
			rowAction(_('+1h'), 'cbi-button-positive', function () {
				return callExtend(d.mac, 1).then(reloadPage);
			}),
			rowAction(_('+4h'), 'cbi-button-positive', function () {
				return callExtend(d.mac, 4).then(reloadPage);
			}),
			rowAction(_('Revoke'), 'cbi-button-negative', function () {
				return callRevoke(d.mac).then(reloadPage);
			})
		]);
		return [
			d.hostname || E('em', {}, _('Guest')),
			E('code', {}, d.mac),
			sourceLabel,
			fmtDuration(d.remaining_seconds),
			fmtExpiry(d.expiry_epoch),
			actions
		];
	});
	return makeTable(headers, rows);
}

function renderDeniedTable(devices) {
	if (!devices || devices.length === 0) {
		return E('em', {}, _('No denied devices.'));
	}
	var headers = [_('Hostname'), _('MAC'), _('Remaining'), _('Expires'), _('Actions')];
	var rows = devices.map(function (d) {
		var actions = E('div', { 'class': 'gk-row-actions' }, [
			rowAction(_('+30m deny'), '', function () {
				return callDeniedExtend(d.mac).then(reloadPage);
			}),
			rowAction(_('Approve'), 'cbi-button-positive', function () {
				return callDeniedRevokeApprove(d.mac).then(reloadPage);
			})
		]);
		return [
			d.hostname || E('em', {}, _('Unknown')),
			E('code', {}, d.mac),
			fmtDuration(d.remaining_seconds),
			fmtExpiry(d.expiry_epoch),
			actions
		];
	});
	return makeTable(headers, rows);
}

function renderStaticTable(devices) {
	if (!devices || devices.length === 0) {
		return E('em', {}, _('No static MAC entries.'));
	}
	var headers = [_('Hostname'), _('MAC')];
	var rows = devices.map(function (d) {
		return [
			d.hostname || E('em', {}, _('Unknown')),
			E('code', {}, d.mac)
		];
	});
	return makeTable(headers, rows);
}

function makeTable(headers, rows) {
	var tbl = E('table', { 'class': 'table cbi-section-table gk-table' }, [
		E('thead', {}, E('tr', { 'class': 'tr cbi-section-table-titles' },
			headers.map(function (h) { return E('th', { 'class': 'th cbi-section-table-cell' }, h); })))
	]);
	var tbody = E('tbody', {});
	rows.forEach(function (r) {
		tbody.appendChild(E('tr', { 'class': 'tr cbi-rowstyle-1' },
			r.map(function (c) { return E('td', { 'class': 'td cbi-section-table-cell' }, c); })));
	});
	tbl.appendChild(tbody);
	return tbl;
}

return view.extend({
	load: function () {
		return Promise.all([
			callListActive(),
			callListDenied(),
			callListStatic()
		]).catch(function (e) {
			return [[], [], []];
		});
	},

	render: function (data) {
		var active = data[0] || [];
		var denied = data[1] || [];
		var statics = data[2] || [];

		return E('div', {}, [
			E('style', {}, [
				'.gk-table { width: 100%; margin: 0.5em 0 1.5em 0; }',
				'.gk-table th { text-align: left; }',
				'.gk-table td code { background: #eee; padding: 0.1em 0.3em; border-radius: 3px; font-size: 0.85em; }',
				'.gk-row-actions { display: flex; gap: 0.3em; flex-wrap: wrap; }',
				'.gk-row-actions button { padding: 0.2em 0.6em; font-size: 0.85em; }',
				'.gk-tag { display: inline-block; padding: 0.1em 0.5em; border-radius: 3px; font-size: 0.8em; }',
				'.gk-tag-sched { background: #fff4cc; color: #663; }',
				'.gk-tag-manual { background: #e8e8e8; color: #555; }'
			].join('\n')),
			E('h2', {}, _('Devices')),
			E('p', {}, _('Live view of approved, denied, and statically-permitted MAC addresses.')),
			E('div', { 'style': 'margin: 0.5em 0;' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': function () { reloadPage(); }
				}, _('🔄 Refresh'))
			]),
			E('h3', {}, _('Active') + ' (' + active.length + ')'),
			E('p', { 'style': 'color: #666; font-size: 0.9em;' },
				_('Currently approved. ⏰ tag = pushed by an active schedule.')),
			renderActiveTable(active),
			E('h3', {}, _('Denied') + ' (' + denied.length + ')'),
			E('p', { 'style': 'color: #666; font-size: 0.9em;' },
				_('Temporarily blocked. Auto-expires after the timeout.')),
			renderDeniedTable(denied),
			E('h3', {}, _('Static') + ' (' + statics.length + ')'),
			E('p', { 'style': 'color: #666; font-size: 0.9em;' },
				_('Permanent whitelist from /etc/config/dhcp host entries.')),
			renderStaticTable(statics)
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
