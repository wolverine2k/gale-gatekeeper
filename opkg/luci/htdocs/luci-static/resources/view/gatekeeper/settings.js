'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

/* Gatekeeper — Settings page.
 * Edit gatekeeper.main config + test-bot diagnostic.
 */

var callSettingsGet = rpc.declare({
	object: 'gatekeeper', method: 'settings_get', expect: {}
});
var callSettingsSet = rpc.declare({
	object: 'gatekeeper', method: 'settings_set',
	params: ['token', 'chat_id', 'blacklist_mode', 'schedule_notify', 'disabled'],
	expect: {}
});
var callTestBot = rpc.declare({
	object: 'gatekeeper', method: 'test_bot', expect: {}
});
var callSync = rpc.declare({
	object: 'gatekeeper', method: 'sync', expect: {}
});
var callClearLogs = rpc.declare({
	object: 'gatekeeper', method: 'clear_logs', expect: {}
});

return view.extend({
	load: function () {
		return callSettingsGet().catch(function () { return {}; });
	},

	render: function (s) {
		s = s || {};

		// Token field — masked by default with "Show" toggle.
		var tokenInput = E('input', {
			'type': 'password', 'class': 'cbi-input-text', 'style': 'width: 360px;',
			'value': s.token || '',
			'placeholder': '1234567890:AAHe…'
		});
		var tokenShowBtn = E('button', {
			'class': 'btn',
			'style': 'margin-left: 0.5em;',
			'click': function (ev) {
				ev.preventDefault();
				if (tokenInput.type === 'password') {
					tokenInput.type = 'text';
					ev.target.textContent = _('Hide');
				} else {
					tokenInput.type = 'password';
					ev.target.textContent = _('Show');
				}
			}
		}, _('Show'));

		var chatIdInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width: 200px;',
			'value': s.chat_id || '',
			'placeholder': '123456789'
		});

		function makeToggle(id, checked, label) {
			return E('label', { 'class': 'gk-toggle-row' }, [
				E('label', { 'class': 'gk-switch' }, [
					E('input', { 'type': 'checkbox', 'id': id,
						'checked': checked ? 'checked' : null }),
					E('span', { 'class': 'gk-slider' })
				]),
				E('span', { 'style': 'margin-left: 0.5em;' }, label)
			]);
		}

		var blMode = makeToggle('gk-set-bl', s.blacklist_mode,
			_('Blacklist mode (only blacklisted MACs require approval; others auto-approved 24h)'));
		var schedNotify = makeToggle('gk-set-sn', s.schedule_notify,
			_('Schedule notifications (info message on each schedule auto-approve)'));
		var disabledFlag = makeToggle('gk-set-disabled', s.disabled,
			_('Emergency disabled (flushes the gatekeeper_forward chain — all traffic passes!)'));

		var saveStatus = E('span', { 'id': 'gk-set-save-status',
			'style': 'margin-left: 1em; color: #666;' });

		var saveBtn = E('button', {
			'class': 'btn cbi-button-save',
			'click': function (ev) {
				ev.target.disabled = true;
				saveStatus.textContent = _('Saving…');
				callSettingsSet(
					tokenInput.value,
					chatIdInput.value,
					document.getElementById('gk-set-bl').checked,
					document.getElementById('gk-set-sn').checked,
					document.getElementById('gk-set-disabled').checked
				).then(function (resp) {
					if (resp.error) throw new Error(resp.error);
					saveStatus.textContent = _('Saved.') +
						(resp.bot_restart ? ' ' + _('Bot will restart to pick up new credentials.') : '');
					ui.addNotification(null, E('p', {}, '✅ ' + _('Settings saved.')), 'info');
				}).catch(function (e) {
					saveStatus.textContent = _('Failed: ') + String(e);
					ui.addNotification(null, E('p', {}, _('Save failed: ') + String(e)), 'danger');
				}).finally(function () {
					ev.target.disabled = false;
				});
			}
		}, _('Save settings'));

		// Test bot connection
		var testStatus = E('div', { 'id': 'gk-test-status', 'style': 'margin-top: 0.5em;' });
		var testBtn = E('button', {
			'class': 'btn',
			'click': function (ev) {
				ev.target.disabled = true;
				dom.content(testStatus, E('em', {}, _('Testing…')));
				callTestBot().then(function (resp) {
					if (resp.error) {
						dom.content(testStatus, E('div', {
							'class': 'alert-message error',
							'style': 'margin-top: 0.5em;'
						}, '❌ ' + _('Bot test failed: ') + resp.error));
					} else {
						dom.content(testStatus, E('div', {
							'class': 'alert-message info',
							'style': 'margin-top: 0.5em;'
						}, [
							E('strong', {}, '✅ ' + _('Bot reachable')),
							E('div', {}, _('Username: @') + (resp.username || '?')),
							E('div', {}, _('First name: ') + (resp.first_name || '?'))
						]));
					}
				}).catch(function (e) {
					dom.content(testStatus, E('div', {
						'class': 'alert-message error',
						'style': 'margin-top: 0.5em;'
					}, '❌ ' + _('Test failed: ') + String(e)));
				}).finally(function () {
					ev.target.disabled = false;
				});
			}
		}, _('Test bot connection'));

		// Maintenance buttons
		var syncBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function (ev) {
				ev.target.disabled = true;
				ev.target.textContent = '…';
				callSync().then(function () {
					ui.addNotification(null, E('p', {}, '✅ ' + _('Static + blacklist MACs re-synced.')), 'info');
				}).catch(function (e) {
					ui.addNotification(null, E('p', {}, _('Sync failed: ') + String(e)), 'danger');
				}).finally(function () {
					ev.target.disabled = false;
					ev.target.textContent = _('Sync MAC sets');
				});
			}
		}, _('Sync MAC sets'));
		var clearBtn = E('button', {
			'class': 'btn',
			'style': 'margin-left: 0.5em;',
			'click': function (ev) {
				if (!confirm(_('Clear /tmp/gatekeeper.log and the hostname cache? This cannot be undone.'))) return;
				ev.target.disabled = true;
				callClearLogs().then(function () {
					ui.addNotification(null, E('p', {}, '✅ ' + _('Logs and hostname cache cleared.')), 'info');
				}).catch(function (e) {
					ui.addNotification(null, E('p', {}, _('Clear failed: ') + String(e)), 'danger');
				}).finally(function () {
					ev.target.disabled = false;
				});
			}
		}, _('Clear logs'));

		return E('div', {}, [
			E('style', {}, [
				'.gk-section { background: #fafafa; border: 1px solid #ddd; border-radius: 6px; padding: 1em; margin: 1em 0; }',
				'.gk-section h3 { margin-top: 0; }',
				'.gk-toggle-row { display: flex; align-items: center; margin: 0.5em 0; }',
				'.gk-switch { position: relative; display: inline-block; width: 50px; height: 24px; flex-shrink: 0; }',
				'.gk-switch input { opacity: 0; width: 0; height: 0; }',
				'.gk-slider { position: absolute; cursor: pointer; top: 0; left: 0; right: 0; bottom: 0; background: #ccc; transition: 0.2s; border-radius: 24px; }',
				'.gk-slider:before { position: absolute; content: ""; height: 18px; width: 18px; left: 3px; bottom: 3px; background: white; transition: 0.2s; border-radius: 50%; }',
				'.gk-switch input:checked + .gk-slider { background: #0a6; }',
				'.gk-switch input:checked + .gk-slider:before { transform: translateX(26px); }',
				'.gk-cbi-row { display: flex; align-items: center; margin: 0.5em 0; gap: 0.5em; flex-wrap: wrap; }',
				'.gk-cbi-row label { min-width: 140px; font-weight: bold; }'
			].join('\n')),
			E('h2', {}, _('Settings')),
			E('p', {}, _('Edit the gatekeeper.main UCI section and verify Telegram credentials.')),

			E('div', { 'class': 'gk-section' }, [
				E('h3', {}, _('Telegram credentials')),
				E('div', { 'class': 'gk-cbi-row' }, [
					E('label', {}, _('Bot token')),
					tokenInput, tokenShowBtn
				]),
				E('div', { 'class': 'gk-cbi-row' }, [
					E('label', {}, _('Chat ID')),
					chatIdInput
				]),
				E('div', { 'style': 'margin-top: 0.5em; font-size: 0.85em; color: #666;' },
					_('Get a token from @BotFather; get your chat ID from @userinfobot. Token is hidden by default.')),
				E('div', { 'style': 'margin-top: 1em;' }, [ testBtn, testStatus ])
			]),

			E('div', { 'class': 'gk-section' }, [
				E('h3', {}, _('Modes')),
				blMode,
				schedNotify,
				disabledFlag
			]),

			E('div', { 'class': 'gk-section' }, [
				E('h3', {}, _('Save')),
				saveBtn, saveStatus,
				E('div', { 'style': 'margin-top: 0.5em; font-size: 0.85em; color: #666;' },
					_('Changing the bot token or chat ID restarts the tg_gatekeeper service so the bot picks up the new value.'))
			]),

			E('div', { 'class': 'gk-section' }, [
				E('h3', {}, _('Maintenance')),
				syncBtn, clearBtn,
				E('div', { 'style': 'margin-top: 0.5em; font-size: 0.85em; color: #666;' },
					_('Sync re-imports static DHCP leases and the blacklist into the firewall sets. Clear wipes /tmp/gatekeeper.log and the hostname cache.'))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
