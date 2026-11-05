'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
let source = fs.readFileSync(path.join(__dirname, '../cursor-bridge/extension.js'), 'utf8');
if (process.argv.includes('--broken')) {
  const start = source.indexOf('        const selected = new Promise(resolve => {');
  const end = source.indexOf('        const ok = await selected;', start);
  assert(start >= 0 && end > start);
  source = source.slice(0, start) + '        terminal.show(false); const ok = vscode.window.activeTerminal === terminal;' + source.slice(end + '        const ok = await selected;'.length);
}
let listener, shown = 0;
const target = {name: 'desired tab', processId: Promise.resolve(process.pid), show() {
  shown++;
  setTimeout(() => { vscode.window.activeTerminal = target; if (listener) listener(target); }, 30);
}};
const vscode = {commands: {async executeCommand() { return ['current-chat']; }}, window: {state: {focused: true}, terminals: [target], activeTerminal: {name: 'decoy tab'},
  onDidChangeActiveTerminal(callback) { listener = callback; return {dispose() { listener = null; }}; }} };
const sandbox = {require: name => name === 'vscode' ? vscode : require(name), module: {exports: {}},
  process, console, setTimeout, clearTimeout, setInterval, clearInterval, URLSearchParams};
vm.runInNewContext(source + '\nmodule.exports.__dispatch = dispatch;', sandbox);
(async () => {
  const result = await sandbox.module.exports.__dispatch({action: 'focus-terminal', processIds: [process.pid]});
  assert.equal(shown, 1);
  assert.equal(result.ok, true, 'Selection must wait for the actual active-terminal event');
  assert.equal(result.code, 'terminal_selected');
  assert.equal(result.terminalName, 'desired tab');
  assert.equal((await sandbox.module.exports.__dispatch({action: 'execute-command'})).code, 'unsupported_action');
  assert.equal((await sandbox.module.exports.__dispatch({action: 'open-chat', id: '../bad'})).code, 'invalid_session_id');
  const context = await sandbox.module.exports.__dispatch({action: 'focus-context'});
  assert.equal(context.focused, true);
  assert.equal(context.selectedIds[0], 'current-chat');
  assert.equal(shown, 1, 'Reading focus must not show or switch a terminal');
  vscode.window.state.focused = false;
  assert.equal((await sandbox.module.exports.__dispatch({action: 'focus-context'})).focused, false);
  console.log('PASS: delayed terminal selection readback; unsupported actions and invalid IDs rejected');
})().catch(error => { console.error(error); process.exitCode = 1; });
