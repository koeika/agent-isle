'use strict';
// Independent bridge built on the VS Code extension API. Cursor's internal chat
// command is version dependent; absence is an explicit error, never a new chat.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const net = require('net');
const {execFile} = require('child_process');
const {promisify} = require('util');
const exec = promisify(execFile);
const ID = /^[a-zA-Z0-9_-]{8,100}$/;
let server, registry, socketPath;
const root = path.join(os.homedir(), 'Library/Application Support/Agent Isle/bridges');

function folders() { return (vscode.workspace.workspaceFolders || []).map(f => f.uri.fsPath); }
function covers(cwd) {
  return folders().some(f => cwd === f || cwd.startsWith(f + path.sep));
}
async function ttyFor(pid) {
  const {stdout} = await exec('/bin/ps', ['-p', String(pid), '-o', 'tty='], {timeout: 800});
  const tty = stdout.trim();
  return tty && tty !== '??' ? (tty.startsWith('/') ? tty : '/dev/' + tty) : '';
}
async function dispatch(request) {
  if (request.action === 'focus-context') {
    if (!vscode.window.state.focused) return {ok: true, focused: false};
    const selected = await vscode.commands.executeCommand('composer.getOrderedSelectedComposerIds');
    // Read only: never shows a panel, changes selection or executes a prompt.
    return {ok: true, focused: true, selectedIds: Array.isArray(selected) ? selected : []};
  }
  if (request.action === 'ping') return {ok: true, workspaces: folders(), pid: process.pid};
  if (request.action === 'open-chat') {
    if (!ID.test(request.id || '')) return {ok: false, code: 'invalid_session_id'};
    if (request.cwd && !covers(request.cwd)) return {ok: false, code: 'workspace_mismatch'};
    const commands = await vscode.commands.getCommands(true);
    if (!commands.includes('composer.openComposer')) return {ok: false, code: 'chat_command_unavailable'};
    // This is the same ID-based opening path used by Cursor's own UI. No
    // prompt submission, agent execution, approval or project modification.
    await vscode.commands.executeCommand('composer.openComposer', request.id);
    const selected = await vscode.commands.executeCommand('composer.getOrderedSelectedComposerIds');
    const selectedIds = Array.isArray(selected) ? selected : [];
    const ok = selectedIds.includes(request.id);
    return {ok, code: ok ? 'chat_selected' : 'chat_selection_unconfirmed',
      id: request.id, selectedIds, workspace: folders(), pid: process.pid};
  }
  if (request.action === 'focus-terminal') {
    const ancestors = new Set((request.processIds || []).map(Number));
    if (!request.tty && !ancestors.size) return {ok: false, code: 'terminal_identity_missing'};
    for (const terminal of vscode.window.terminals) {
      const pid = await terminal.processId;
      if (!pid) continue;
      const tty = await ttyFor(pid);
      if (ancestors.has(pid) || (request.tty && request.tty === tty)) {
        // show() returns before VS Code publishes the active-terminal change.
        // Subscribe first, and only report success after authoritative readback.
        const selected = new Promise(resolve => {
          let finished = false, listener, timer;
          const finish = () => {
            if (finished) return;
            finished = true;
            if (listener) listener.dispose();
            clearTimeout(timer);
            resolve(vscode.window.activeTerminal === terminal);
          };
          listener = vscode.window.onDidChangeActiveTerminal(t => { if (t === terminal) finish(); });
          timer = setTimeout(finish, 2000);
          terminal.show(false);
          if (vscode.window.activeTerminal === terminal) finish();
        });
        const ok = await selected;
        return {ok, code: ok ? 'terminal_selected' : 'terminal_selection_unconfirmed', shellPid: pid, tty, terminalName: terminal.name};
      }
    }
    return {ok: false, code: 'terminal_not_found'};
  }
  return {ok: false, code: 'unsupported_action'};
}

function publish() {
  const value = {version: 1, pid: process.pid, socket: socketPath, workspaces: folders(), app: vscode.env.appName, updated: Date.now()};
  const tmp = registry + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(value), {mode: 0o600});
  fs.renameSync(tmp, registry);
}

async function activate(context) {
  fs.mkdirSync(root, {recursive: true, mode: 0o700});
  const stat = fs.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Unsafe Agent Isle bridge directory');
  fs.chmodSync(root, 0o700);
  const instance = 'c' + process.pid + '-' + Math.random().toString(16).slice(2, 6);
  socketPath = path.join(root, instance + '.sock');
  registry = path.join(root, instance + '.json');
  if (Buffer.byteLength(socketPath) > 100) throw new Error('Agent Isle socket path is too long');
  server = net.createServer(socket => {
    socket.setTimeout(10000, () => socket.destroy());
    let input = '', handled = false;
    socket.on('error', () => {}); // A disconnected local requester must not crash Cursor.
    socket.on('data', async bytes => {
      if (handled) return;
      input += bytes.toString('utf8');
      if (input.length > 16384) { handled = true; socket.end('{"ok":false,"code":"oversize_request"}\n'); return; }
      if (!input.includes('\n')) return;
      handled = true;
      try { socket.end(JSON.stringify(await dispatch(JSON.parse(input.split('\n')[0]))) + '\n'); }
      catch (e) { socket.end(JSON.stringify({ok: false, code: 'bridge_error', error: String(e.message).slice(0, 300)}) + '\n'); }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  fs.chmodSync(socketPath, 0o600);
  publish();
  const heartbeat = setInterval(publish, 15000);
  context.subscriptions.push(vscode.workspace.onDidChangeWorkspaceFolders(publish));
  context.subscriptions.push(vscode.commands.registerCommand('agentIsle.bridgeStatus', () => vscode.window.showInformationMessage('Agent Isle local bridge active — ' + folders().join(', '))));
  context.subscriptions.push(vscode.window.registerUriHandler({async handleUri(uri) {
    const query = new URLSearchParams(uri.query);
    const result = await dispatch({action: 'open-chat', id: query.get('id'), cwd: query.get('cwd') || ''});
    if (!result.ok) vscode.window.showWarningMessage('Agent Isle: ' + result.code);
  }}));
  context.subscriptions.push({dispose() { clearInterval(heartbeat); deactivate(); }});
}

function deactivate() {
  if (server) server.close();
  for (const file of [registry, socketPath]) if (file && fs.existsSync(file)) fs.unlinkSync(file);
}
module.exports = {activate, deactivate};
