'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

/* Gatekeeper — Blacklist page.
 * Toggle blacklist_mode + editable MAC list with online indicators.
 */

var callBlGetMode = rpc.declare({
	object: 'gatekeeper', method: 'bl_get_mode', expect: { enabled: false }
});
var callBlSetMode = rpc.declare({
	object: 'gatekeeper', method: 'bl_set_mode', params: ['enabled'], expect: {}
});
var callBlList = rpc.declare({
	object: 'gatekeeper', method: 'bl_list', expect: { macs: [] }
});
var callBlAdd = rpc.declare({
	object: 'gatekeeper', method: 'bl_add', params: ['mac'], expect: {}
});
var callBlRemove = rpc.declare({
	object: 'gatekeeper', method: 'bl_remove', params: ['mac'], expect: {}
});
var callBlClear = rpc.declare({
	object: 'gatekeeper', method: 'bl_clear', expect: {}
});

var MAC_RE = /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/;

function reloadPage() {
	if (window.location.hash) {
		var h = window.location.hash;
		window.location.hash = '';
		window.location.hash = h;
	} else { window.location.reload(); }
}

return view.extend({
	load: function () {
		return Promise.all([ callBlGetMode(), callBlList() ])
			.catch(function () { return [false, []]; });
	},

	render: function (data) {
		var enabled = !!data[0];
		var macs = data[1] || [];

		var modeToggle = E('div', { 'class': 'gk-mode-toggle' }, [
			E('label', { 'class': 'gk-switch' }, [
				E('input', {
					'type': 'checkbox',
					'id': 'gk-bl-mode',
					'checked': enabled ? 'checked' : null,
					'change': function (ev) {
						var newVal = ev.target.checked;
						return callBlSetMode(newVal).then(function () {
							ui.addNotification(null,
								E('p', {}, newVal
									? _('Blacklist mode enabled — only blacklisted MACs require approval, others auto-approved 24h.')
									: _('Blacklist mode disabled — all new devices require approval.')),
								'info');
							var statusText = document.getElementById('gk-bl-mode-status');
							if (statusText) {
								statusText.textContent = newVal ? _('ON') : _('OFF');
								statusText.className = 'gk-tag ' + (newVal ? 'gk-tag-on' : 'gk-tag-off');
							}
						}).catch(function (e) {
							ev.target.checked = !newVal;
							ui.addNotification(null, E('p', {}, _('Failed: ') + String(e)), 'danger');
						});
					}
				}),
				E('span', { 'class': 'gk-slider' })
			]),
			E('div', {}, [
				E('strong', {}, _('Blacklist mode: ')),
				E('span', {
					'id': 'gk-bl-mode-status',
					'class': 'gk-tag ' + (enabled ? 'gk-tag-on' : 'gk-tag-off')
				}, enabled ? _('ON') : _('OFF'))
			])
		]);

		var addInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': 'aa:bb:cc:dd:ee:ff',
			'id': 'gk-bl-add-input',
			'style': 'width: 220px; margin-right: 0.5em;',
			'keyup': function (ev) {
				if (ev.key === 'Enter') document.getElementById('gk-bl-add-btn').click();
			}
		});
		var addError = E('span', {
			'id': 'gk-bl-add-error',
			'style': 'color: #c33; margin-left: 0.5em; display: none;'
		});
		var addButton = E('button', {
			'class': 'btn cbi-button-positive',
			'id': 'gk-bl-add-btn',
			'click': function () {
				var v = addInput.value.trim();
				addError.style.display = 'none';
				if (!MAC_RE.test(v)) {
					addError.textContent = _('Invalid MAC. Use aa:bb:cc:dd:ee:ff.');
					addError.style.display = 'inline';
					return;
				}
				addButton.disabled = true;
				callBlAdd(v).then(function () {
					addInput.value = '';
					reloadPage();
				}).catch(function (e) {
					addError.textContent = _('Failed: ') + String(e);
					addError.style.display = 'inline';
				}).finally(function () { addButton.disabled = false; });
			}
		}, _('Add MAC'));

		var addRow = E('div', { 'style': 'margin: 1em 0; display: flex; align-items: center;' },
			[ addInput, addButton, addError ]);

		var listEl;
		if (macs.length === 0) {
			listEl = E('em', {}, _('No MACs in blacklist.'));
		} else {
			var headers = [_('MAC'), _('Hostname'), _('Online'), _('Action')];
			var tbl = E('table', { 'class': 'table cbi-section-table gk-table' },
				E('thead', {}, E('tr', { 'class': 'tr cbi-section-table-titles' },
					headers.map(function (h) {
						return E('th', { 'class': 'th cbi-section-table-cell' }, h);
					})))
			);
			var tbody = E('tbody', {});
			macs.forEach(function (m) {
				var onlineCell = m.online
					? E('span', { 'class': 'gk-tag gk-tag-on' }, '● ' + _('online'))
					: E('span', { 'class': 'gk-tag gk-tag-off' }, _('offline'));
				var removeBtn = E('button', {
					'class': 'btn cbi-button-negative',
					'click': function (ev) {
						var b = ev.target;
						b.disabled = true;
						b.textContent = '…';
						callBlRemove(m.mac).then(reloadPage).catch(function (e) {
							b.disabled = false;
							b.textContent = _('Remove');
							ui.addNotification(null, E('p', {}, _('Failed: ') + String(e)), 'danger');
						});
					}
				}, _('Remove'));
				tbody.appendChild(E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td cbi-section-table-cell' }, E('code', {}, m.mac)),
					E('td', { 'class': 'td cbi-section-table-cell' },
						m.hostname || E('em', {}, _('Unknown'))),
					E('td', { 'class': 'td cbi-section-table-cell' }, onlineCell),
					E('td', { 'class': 'td cbi-section-table-cell' }, removeBtn)
				]));
			});
			tbl.appendChild(tbody);
			listEl = tbl;
		}

		var clearBtn = E('button', {
			'class': 'btn cbi-button-negative',
			'style': 'margin-top: 1em;',
			'click': function (ev) {
				if (!confirm(_('Remove ALL MACs from the blacklist? This cannot be undone.'))) return;
				ev.target.disabled = true;
				ev.target.textContent = '…';
				callBlClear().then(reloadPage).catch(function (e) {
					ev.target.disabled = false;
					ev.target.textContent = _('Clear all');
					ui.addNotification(null, E('p', {}, _('Failed: ') + String(e)), 'danger');
				});
			}
		}, _('Clear all'));

		return E('div', {}, [
			E('style', {}, [
				'.gk-table { width: 100%; margin: 0.5em 0; }',
				'.gk-table th { text-align: left; }',
				'.gk-table td code { background: #eee; padding: 0.1em 0.3em; border-radius: 3px; }',
				'.gk-tag { display: inline-block; padding: 0.15em 0.6em; border-radius: 3px; font-size: 0.85em; font-weight: bold; }',
				'.gk-tag-on { background: #d4f4dd; color: #0a6; }',
				'.gk-tag-off { background: #e8e8e8; color: #888; }',
				'.gk-mode-toggle { display: flex; align-items: center; gap: 1em; margin: 1em 0; padding: 1em; background: #fafafa; border: 1px solid #ddd; border-radius: 6px; }',
				'.gk-switch { position: relative; display: inline-block; width: 50px; height: 24px; }',
				'.gk-switch input { opacity: 0; width: 0; height: 0; }',
				'.gk-slider { position: absolute; cursor: pointer; top: 0; left: 0; right: 0; bottom: 0; background: #ccc; transition: 0.2s; border-radius: 24px; }',
				'.gk-slider:before { position: absolute; content: ""; height: 18px; width: 18px; left: 3px; bottom: 3px; background: white; transition: 0.2s; border-radius: 50%; }',
				'.gk-switch input:checked + .gk-slider { background: #0a6; }',
				'.gk-switch input:checked + .gk-slider:before { transform: translateX(26px); }'
			].join('\n')),
			E('h2', {}, _('Blacklist')),
			E('p', {}, _('When blacklist mode is ON, only MACs in this list require approval. All other devices are auto-approved for 24 hours.')),
			modeToggle,
			E('h3', {}, _('Add MAC')),
			addRow,
			E('h3', {}, _('Current entries') + ' (' + macs.length + ')'),
			listEl,
			(macs.length > 0 ? clearBtn : E('span'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
