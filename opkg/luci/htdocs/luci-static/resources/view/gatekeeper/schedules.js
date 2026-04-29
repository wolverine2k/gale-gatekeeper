'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

/* Gatekeeper — Schedules page.
 * Table + modal CRUD for time-window auto-approval rules.
 */

var callSchedList = rpc.declare({
	object: 'gatekeeper', method: 'sched_list', params: ['mac'], expect: { schedules: [] }
});
var callSchedAdd = rpc.declare({
	object: 'gatekeeper', method: 'sched_add',
	params: ['mac', 'days', 'start', 'stop', 'name', 'label'],
	expect: {}
});
var callSchedRemove = rpc.declare({
	object: 'gatekeeper', method: 'sched_remove', params: ['name'], expect: {}
});
var callSchedSetEnabled = rpc.declare({
	object: 'gatekeeper', method: 'sched_set_enabled',
	params: ['name', 'enabled'], expect: {}
});

var MAC_RE = /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/;
var HHMM_RE = /^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$/;
var NAME_RE = /^[a-z0-9_]{1,32}$/;
var DAYS_KEYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
var DAYS_LABELS = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' };

function reloadPage() {
	if (window.location.hash) {
		var h = window.location.hash;
		window.location.hash = '';
		window.location.hash = h;
	} else { window.location.reload(); }
}

function fmtExpiry(epoch) {
	if (!epoch || epoch <= 0) return '';
	var d = new Date(epoch * 1000);
	var hh = String(d.getHours()).padStart(2, '0');
	var mm = String(d.getMinutes()).padStart(2, '0');
	return hh + ':' + mm;
}

function expandDays(s) {
	if (!s) return [];
	switch (s) {
		case 'daily':    return DAYS_KEYS.slice();
		case 'weekdays': return ['mon','tue','wed','thu','fri'];
		case 'weekends': return ['sat','sun'];
		default: return s.split(',').map(function (x) { return x.trim(); });
	}
}

function compactDays(arr) {
	if (!arr || arr.length === 0) return '';
	if (arr.length === 7) return 'daily';
	var weekdays = ['mon','tue','wed','thu','fri'];
	var weekends = ['sat','sun'];
	var sorted = arr.slice().sort();
	if (sorted.length === 5 && weekdays.every(function (d) { return sorted.indexOf(d) >= 0; })) return 'weekdays';
	if (sorted.length === 2 && weekends.every(function (d) { return sorted.indexOf(d) >= 0; })) return 'weekends';
	// Maintain canonical order.
	return DAYS_KEYS.filter(function (d) { return sorted.indexOf(d) >= 0; }).join(',');
}

function showModal(opts) {
	// opts: { title, body, onConfirm, confirmLabel }
	var modal = ui.showModal(opts.title, [
		opts.body,
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'click': ui.hideModal
			}, _('Cancel')),
			' ',
			E('button', {
				'class': 'btn cbi-button-positive',
				'click': function () {
					var maybe = opts.onConfirm();
					if (maybe && typeof maybe.then === 'function') {
						maybe.then(ui.hideModal).catch(function (e) {
							ui.addNotification(null, E('p', {}, _('Failed: ') + String(e)), 'danger');
						});
					} else {
						ui.hideModal();
					}
				}
			}, opts.confirmLabel || _('Save'))
		])
	]);
	return modal;
}

function buildAddDialog() {
	var macInput = E('input', { 'type': 'text', 'class': 'cbi-input-text',
		'placeholder': 'aa:bb:cc:dd:ee:ff', 'style': 'width: 100%;' });
	var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text',
		'placeholder': _('(auto-generated if empty)'), 'style': 'width: 100%;' });
	var labelInput = E('input', { 'type': 'text', 'class': 'cbi-input-text',
		'placeholder': _('(optional friendly label)'), 'style': 'width: 100%;' });
	var startInput = E('input', { 'type': 'time', 'class': 'cbi-input-text', 'value': '16:00' });
	var stopInput = E('input', { 'type': 'time', 'class': 'cbi-input-text', 'value': '20:00' });

	var dayPreset = E('select', { 'class': 'cbi-input-select', 'change': function (ev) {
		var v = ev.target.value;
		if (v === 'custom') return;
		var days = expandDays(v);
		DAYS_KEYS.forEach(function (k) {
			var cb = document.getElementById('gk-sched-day-' + k);
			if (cb) cb.checked = days.indexOf(k) >= 0;
		});
	}}, [
		E('option', { 'value': 'daily' }, _('Daily')),
		E('option', { 'value': 'weekdays', 'selected': 'selected' }, _('Weekdays (Mon–Fri)')),
		E('option', { 'value': 'weekends' }, _('Weekends (Sat–Sun)')),
		E('option', { 'value': 'custom' }, _('Custom (use checkboxes)'))
	]);

	var dayCheckboxes = E('div', { 'class': 'gk-day-checks' });
	DAYS_KEYS.forEach(function (k) {
		var label = E('label', { 'class': 'gk-day-check' }, [
			E('input', { 'type': 'checkbox', 'id': 'gk-sched-day-' + k,
				'checked': (k !== 'sat' && k !== 'sun') ? 'checked' : null }),
			' ', DAYS_LABELS[k]
		]);
		dayCheckboxes.appendChild(label);
	});

	var errorBox = E('div', { 'style': 'color: #c33; margin-top: 0.5em;', 'id': 'gk-sched-add-error' });

	var body = E('div', { 'class': 'cbi-section' }, [
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('MAC address')),
			E('div', { 'class': 'cbi-value-field' }, [ macInput,
				E('div', { 'class': 'cbi-value-description' },
					_('Lowercase MAC, e.g. b0:6b:11:19:5d:06'))
			])
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Days')),
			E('div', { 'class': 'cbi-value-field' }, [ dayPreset, dayCheckboxes ])
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Window')),
			E('div', { 'class': 'cbi-value-field gk-time-row' }, [
				startInput, ' – ', stopInput,
				E('div', { 'class': 'cbi-value-description' },
					_('24-hour, router local TZ. If stop ≤ start, the window crosses midnight.'))
			])
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Name')),
			E('div', { 'class': 'cbi-value-field' }, [ nameInput,
				E('div', { 'class': 'cbi-value-description' },
					_('1–32 chars of [a-z0-9_]. Auto-generated if empty. Hyphens not allowed.'))
			])
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Label')),
			E('div', { 'class': 'cbi-value-field' }, [ labelInput,
				E('div', { 'class': 'cbi-value-description' },
					_('Optional human-readable label (display only).'))
			])
		]),
		errorBox
	]);

	function validate() {
		errorBox.textContent = '';
		var mac = macInput.value.trim().toLowerCase();
		if (!MAC_RE.test(mac)) { errorBox.textContent = _('Invalid MAC.'); return null; }
		var days = DAYS_KEYS.filter(function (k) {
			var cb = document.getElementById('gk-sched-day-' + k);
			return cb && cb.checked;
		});
		if (days.length === 0) { errorBox.textContent = _('Select at least one day.'); return null; }
		var daysVal = compactDays(days);
		var start = startInput.value, stop = stopInput.value;
		if (!HHMM_RE.test(start)) { errorBox.textContent = _('Invalid start (HH:MM).'); return null; }
		if (!HHMM_RE.test(stop)) { errorBox.textContent = _('Invalid stop (HH:MM).'); return null; }
		if (start === stop) { errorBox.textContent = _('Start and stop must differ.'); return null; }
		var name = nameInput.value.trim().toLowerCase();
		if (name && !NAME_RE.test(name)) {
			// Try the hyphen-to-underscore correction.
			var fix = name.replace(/-/g, '_');
			if (NAME_RE.test(fix)) {
				errorBox.textContent = _('UCI section names disallow hyphens. Try: ') + fix;
			} else {
				errorBox.textContent = _('Invalid name (1–32 chars of [a-z0-9_]).');
			}
			return null;
		}
		var label = labelInput.value.trim();
		return { mac: mac, days: daysVal, start: start, stop: stop, name: name, label: label };
	}

	return { body: body, validate: validate };
}

return view.extend({
	load: function () {
		return callSchedList('').catch(function () { return []; });
	},

	render: function (schedules) {
		schedules = schedules || [];

		var addBtn = E('button', {
			'class': 'btn cbi-button-positive',
			'click': function () {
				var dlg = buildAddDialog();
				showModal({
					title: _('Add schedule'),
					body: dlg.body,
					confirmLabel: _('Add'),
					onConfirm: function () {
						var args = dlg.validate();
						if (!args) return Promise.reject(new Error('validation failed'));
						return callSchedAdd(args.mac, args.days, args.start, args.stop, args.name, args.label)
							.then(reloadPage);
					}
				});
			}
		}, _('+ Add schedule'));

		var listEl;
		if (schedules.length === 0) {
			listEl = E('div', { 'style': 'margin: 1em 0;' }, [
				E('em', {}, _('No schedules defined.')),
				E('div', { 'style': 'color: #666; font-size: 0.9em; margin-top: 0.5em;' },
					_('Click "+ Add schedule" above to create one.'))
			]);
		} else {
			var headers = [_('Name'), _('Device'), _('Days'), _('Window'), _('State'), _('Actions')];
			var tbl = E('table', { 'class': 'table cbi-section-table gk-table' },
				E('thead', {}, E('tr', { 'class': 'tr cbi-section-table-titles' },
					headers.map(function (h) {
						return E('th', { 'class': 'th cbi-section-table-cell' }, h);
					})))
			);
			var tbody = E('tbody', {});
			schedules.forEach(function (s) {
				var deviceCell = E('div', {}, [
					E('code', {}, s.mac),
					E('br'),
					E('span', { 'style': 'color: #666; font-size: 0.85em;' },
						s.hostname ? s.hostname : _('(no hostname)'))
				]);
				var stateCell;
				if (!s.enabled) {
					stateCell = E('span', { 'class': 'gk-tag gk-tag-paused' }, _('paused'));
				} else if (s.active) {
					stateCell = E('span', { 'class': 'gk-tag gk-tag-active' },
						'⏰ ' + _('active until ') + fmtExpiry(s.end_epoch));
				} else {
					stateCell = E('span', { 'class': 'gk-tag gk-tag-idle' }, _('idle'));
				}
				var actions = E('div', { 'class': 'gk-row-actions' }, [
					E('button', {
						'class': 'btn',
						'click': function (ev) {
							ev.target.disabled = true;
							callSchedSetEnabled(s.name, !s.enabled).then(reloadPage)
								.catch(function (e) {
									ev.target.disabled = false;
									ui.addNotification(null, E('p', {}, _('Failed: ') + String(e)), 'danger');
								});
						}
					}, s.enabled ? _('Pause') : _('Resume')),
					E('button', {
						'class': 'btn cbi-button-negative',
						'click': function (ev) {
							if (!confirm(_('Delete schedule "') + s.name + '"?')) return;
							ev.target.disabled = true;
							callSchedRemove(s.name).then(reloadPage)
								.catch(function (e) {
									ev.target.disabled = false;
									ui.addNotification(null, E('p', {}, _('Failed: ') + String(e)), 'danger');
								});
						}
					}, _('Delete'))
				]);
				var nameCell = E('div', {}, [
					E('strong', {}, s.name),
					s.label ? E('div', { 'style': 'color: #666; font-size: 0.85em;' }, s.label) : null
				]);
				var daysCell = E('span', { 'class': 'gk-days-tag' }, s.days);
				var windowCell = E('span', { 'class': 'gk-window-tag' }, s.start + '–' + s.stop);
				tbody.appendChild(E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td cbi-section-table-cell' }, nameCell),
					E('td', { 'class': 'td cbi-section-table-cell' }, deviceCell),
					E('td', { 'class': 'td cbi-section-table-cell' }, daysCell),
					E('td', { 'class': 'td cbi-section-table-cell' }, windowCell),
					E('td', { 'class': 'td cbi-section-table-cell' }, stateCell),
					E('td', { 'class': 'td cbi-section-table-cell' }, actions)
				]));
			});
			tbl.appendChild(tbody);
			listEl = tbl;
		}

		return E('div', {}, [
			E('style', {}, [
				'.gk-table { width: 100%; margin: 0.5em 0; }',
				'.gk-table th { text-align: left; }',
				'.gk-table td code { background: #eee; padding: 0.1em 0.3em; border-radius: 3px; }',
				'.gk-tag { display: inline-block; padding: 0.15em 0.5em; border-radius: 3px; font-size: 0.85em; }',
				'.gk-tag-active { background: #fff4cc; color: #663; font-weight: bold; }',
				'.gk-tag-paused { background: #e8e8e8; color: #888; }',
				'.gk-tag-idle { background: #d4f4dd; color: #0a6; }',
				'.gk-days-tag { font-family: monospace; }',
				'.gk-window-tag { font-family: monospace; background: #f0f0f0; padding: 0.1em 0.4em; border-radius: 3px; }',
				'.gk-row-actions { display: flex; gap: 0.3em; flex-wrap: wrap; }',
				'.gk-row-actions button { padding: 0.2em 0.6em; font-size: 0.85em; }',
				'.gk-day-checks { display: flex; gap: 0.5em; flex-wrap: wrap; margin-top: 0.5em; }',
				'.gk-day-check { display: inline-block; padding: 0.2em 0.5em; background: #f5f5f5; border-radius: 3px; cursor: pointer; }',
				'.gk-time-row input { width: 100px; }'
			].join('\n')),
			E('h2', {}, _('Schedules')),
			E('p', {}, _('Time-window auto-approval rules. During an active window, the configured MAC is silently approved. Multiple schedules per MAC are supported; cross-midnight windows (stop ≤ start) work too.')),
			E('p', { 'style': 'color: #666; font-size: 0.9em;' }, _('Note: schedule changes can take up to 30 seconds to take effect. New or modified active-window schedules become enforced on the next reconciliation tick.')),
			E('div', { 'style': 'margin: 1em 0;' }, [
				addBtn,
				E('button', {
					'class': 'btn cbi-button',
					'style': 'margin-left: 0.5em;',
					'click': reloadPage
				}, _('🔄 Refresh'))
			]),
			listEl
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
