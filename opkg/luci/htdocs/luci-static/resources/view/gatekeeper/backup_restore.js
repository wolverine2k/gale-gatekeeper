'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

/* Gatekeeper — Backup & Restore page.
 * Browser download/upload of UCI snapshots, with preview-then-apply.
 */

var callBackup = rpc.declare({
	object: 'gatekeeper', method: 'backup', params: ['nosecrets'], expect: {}
});
var callRestoreDryrun = rpc.declare({
	object: 'gatekeeper', method: 'restore_dryrun', params: ['content_b64'], expect: {}
});
var callRestoreApply = rpc.declare({
	object: 'gatekeeper', method: 'restore_apply', expect: {}
});

function downloadBlob(filename, content) {
	var blob = new Blob([content], { type: 'text/plain' });
	var url = URL.createObjectURL(blob);
	var a = document.createElement('a');
	a.href = url;
	a.download = filename;
	document.body.appendChild(a);
	a.click();
	document.body.removeChild(a);
	URL.revokeObjectURL(url);
}

function b64decode(b64) {
	// atob handles base64; output is binary string. We treat content as UTF-8.
	try {
		var bin = atob(b64);
		// Convert binary string to UTF-8 string.
		var bytes = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
		return new TextDecoder('utf-8').decode(bytes);
	} catch (e) {
		return null;
	}
}

function fileToB64(file) {
	return new Promise(function (resolve, reject) {
		var reader = new FileReader();
		reader.onload = function () {
			var s = reader.result;
			// reader.result is "data:...;base64,XXXX"
			var m = s.match(/^data:[^;]*;base64,(.*)$/);
			if (m) resolve(m[1]);
			else reject(new Error('Failed to read file'));
		};
		reader.onerror = function () { reject(new Error('Failed to read file')); };
		reader.readAsDataURL(file);
	});
}

function performBackup(nosecrets, button) {
	button.disabled = true;
	var orig = button.textContent;
	button.textContent = '…';
	return callBackup(nosecrets).then(function (resp) {
		if (resp && resp.error) {
			throw new Error(resp.error);
		}
		var content = b64decode(resp.content_b64 || '');
		if (content === null) throw new Error('Invalid base64 content from server');
		downloadBlob(resp.filename || 'gatekeeper-backup.txt', content);
		ui.addNotification(null, E('p', {},
			_('Backup downloaded: ') + (resp.filename || '') +
			' (' + resp.size + ' bytes, ' +
			(resp.includes_secrets ? _('includes secrets') : _('NO secrets')) + ')'
		), 'info');
	}).catch(function (e) {
		ui.addNotification(null, E('p', {}, _('Backup failed: ') + String(e)), 'danger');
	}).finally(function () {
		button.disabled = false;
		button.textContent = orig;
	});
}

return view.extend({
	load: function () { return Promise.resolve(); },

	render: function () {
		var fileInput = E('input', {
			'type': 'file', 'accept': '.txt,text/plain', 'id': 'gk-restore-file',
			'change': function (ev) {
				var f = ev.target.files[0];
				var label = document.getElementById('gk-restore-file-label');
				if (label) label.textContent = f ? f.name : _('No file chosen');
				var btn = document.getElementById('gk-restore-preview-btn');
				if (btn) btn.disabled = !f;
			}
		});

		var previewBox = E('div', { 'id': 'gk-restore-preview-box',
			'style': 'display: none; margin-top: 1em;' });

		function showPreview(html) {
			dom.content(previewBox, html);
			previewBox.style.display = '';
		}
		function hidePreview() {
			previewBox.style.display = 'none';
			dom.content(previewBox, '');
		}

		var previewBtn = E('button', {
			'class': 'btn cbi-button',
			'id': 'gk-restore-preview-btn',
			'disabled': 'disabled',
			'click': function () {
				hidePreview();
				var f = fileInput.files[0];
				if (!f) return;
				if (f.size > 1048576) {
					ui.addNotification(null, E('p', {}, _('File is larger than 1 MB; refusing.')), 'danger');
					return;
				}
				previewBtn.disabled = true;
				previewBtn.textContent = '…';
				fileToB64(f).then(callRestoreDryrun).then(function (resp) {
					if (resp.error) throw new Error(resp.error);
					if (resp.noop) {
						showPreview(E('div', { 'class': 'alert-message info' },
							E('p', {}, '🔄 ' + (resp.preview || _('Nothing to do — all entries already present.')))));
						return;
					}
					// Render preview + apply button.
					var counts = resp.counts || {};
					var summary = E('div', { 'style': 'margin-bottom: 0.5em;' }, [
						E('strong', {}, _('Plan: ') + (counts.total || 0) + _(' change(s)')),
						' (',
						(counts.main || 0), ' ', _('main'), ', ',
						(counts.blacklist || 0), ' ', _('blacklist'), ', ',
						(counts.schedules || 0), ' ', _('schedule'),
						')'
					]);
					var pre = E('pre', { 'class': 'gk-restore-preview' }, resp.preview || '');
					var applyBtn = E('button', {
						'class': 'btn cbi-button-positive',
						'click': function (ev) {
							if (!confirm(_('Apply this restore plan? Token / chat_id will NOT be touched. Failures during apply roll back via uci revert.'))) return;
							ev.target.disabled = true;
							ev.target.textContent = '…';
							callRestoreApply().then(function (resp) {
								if (resp.error) throw new Error(resp.error);
								var a = resp.applied || {};
								ui.addNotification(null, E('p', {},
									'✅ ' + _('Restore complete: ') + (a.total || 0) + _(' change(s) applied') +
									' (' + (a.main || 0) + ' ' + _('main') + ', ' +
									(a.blacklist || 0) + ' ' + _('blacklist') + ', ' +
									(a.schedules || 0) + ' ' + _('schedule') + ')'
								), 'info');
								hidePreview();
								fileInput.value = '';
								var label = document.getElementById('gk-restore-file-label');
								if (label) label.textContent = _('No file chosen');
								previewBtn.disabled = true;
							}).catch(function (e) {
								ui.addNotification(null, E('p', {}, '❌ ' + _('Restore failed: ') + String(e)), 'danger');
								ev.target.disabled = false;
								ev.target.textContent = _('Apply restore');
							});
						}
					}, _('Apply restore'));
					var cancelBtn = E('button', {
						'class': 'btn',
						'style': 'margin-left: 0.5em;',
						'click': function () { hidePreview(); }
					}, _('Cancel'));
					showPreview(E('div', { 'class': 'alert-message warning' }, [
						E('h4', { 'style': 'margin-top: 0;' }, _('Restore preview')),
						summary, pre,
						E('div', { 'style': 'margin-top: 0.5em;' }, [ applyBtn, cancelBtn ])
					]));
				}).catch(function (e) {
					ui.addNotification(null, E('p', {}, _('Preview failed: ') + String(e)), 'danger');
				}).finally(function () {
					previewBtn.disabled = false;
					previewBtn.textContent = _('Preview restore');
				});
			}
		}, _('Preview restore'));

		var backupBtn = E('button', {
			'class': 'btn cbi-button-positive',
			'click': function (ev) { performBackup(false, ev.target); }
		}, _('Download backup (with secrets)'));
		var backupNoBtn = E('button', {
			'class': 'btn cbi-button',
			'style': 'margin-left: 0.5em;',
			'click': function (ev) { performBackup(true, ev.target); }
		}, _('Download backup (NO secrets)'));

		return E('div', {}, [
			E('style', {}, [
				'.gk-restore-preview { background: #f8f8f8; border: 1px solid #ddd; padding: 1em; max-height: 400px; overflow: auto; font-family: monospace; font-size: 0.85em; white-space: pre-wrap; }',
				'.gk-bk-section { margin: 1.5em 0; padding: 1em; background: #fafafa; border: 1px solid #ddd; border-radius: 6px; }',
				'.gk-bk-section h3 { margin-top: 0; }'
			].join('\n')),
			E('h2', {}, _('Backup & Restore')),
			E('p', {},
				_('Download a UCI snapshot (gatekeeper config + DHCP host entries) or restore from a previously downloaded file. The two-step Restore flow shows a preview first; nothing is applied until you click Apply.')),
			E('div', { 'class': 'gk-bk-section' }, [
				E('h3', {}, _('Backup')),
				E('p', {}, _('Produces a plain-text backup file you can save anywhere. ') +
					E('strong', {}, _('NO secrets')).outerHTML +
					_(' blanks the bot token and chat_id before download.') ),
				backupBtn, backupNoBtn
			]),
			E('div', { 'class': 'gk-bk-section' }, [
				E('h3', {}, _('Restore')),
				E('p', {}, _('Choose a Gatekeeper backup file (.txt). Click Preview to see a merge plan, then Apply to commit. Restore is additive: existing entries are skipped, missing ones added. Token / chat_id are never overwritten.')),
				E('div', { 'style': 'display: flex; align-items: center; gap: 0.5em; flex-wrap: wrap;' }, [
					E('label', { 'class': 'btn cbi-button',
						'for': 'gk-restore-file' }, _('Choose file')),
					fileInput,
					E('span', { 'id': 'gk-restore-file-label',
						'style': 'color: #666;' }, _('No file chosen')),
					previewBtn
				]),
				E('style', {}, '#gk-restore-file { display: none; }'),
				previewBox
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
