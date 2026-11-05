"""Exact local editor routing, with explicit evidence of selection."""
import argparse
import json
import os
import socket
import stat
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from agent_isle.monitor import root_path


def process_identity(pid=None):
    """Capture the actual controlling TTY and shell ancestors, without argv/env."""
    import subprocess
    pid = pid or os.getpid()
    # Process enumeration is optional enrichment. Busy machines must still
    # deliver the lifecycle hook instead of losing the complete/input event.
    fallback = {'PROCESS_IDS': str(pid)}
    if pid == os.getpid():
        fallback['PROCESS_IDS'] += ',' + str(os.getppid())
        try:
            fallback['TTY'] = os.ttyname(0)
        except OSError:
            pass
    try:
        result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,tty=,comm='], capture_output=True, text=True, timeout=1)
    except (OSError, subprocess.SubprocessError):
        return fallback
    if result.returncode:
        return fallback
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            rows[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
    chain, tty, current = [], '', int(pid)
    while current > 1 and current in rows and len(chain) < 20:
        parent, terminal, _ = rows[current]
        chain.append(current)
        if not tty and terminal != '??':
            tty = terminal if terminal.startswith('/') else '/dev/' + terminal
        if parent == current:
            break
        current = parent
    info = {'PROCESS_IDS': ','.join(map(str, chain))} if chain else fallback
    if tty:
        info['TTY'] = tty
    return info


def request_bridge(entry, request, timeout=8):
    path = Path(entry['socket'])
    # Private local Unix sockets only. Registry content cannot redirect to a
    # remote address or an arbitrary local service.
    allowed = root_path() / 'bridges'
    if path.parent.resolve() != allowed.resolve():
        raise ValueError('unsafe_socket_path')
    info = path.lstat()
    if info.st_uid != os.getuid() or not stat.S_ISSOCK(info.st_mode):
        raise ValueError('unsafe_socket_owner')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(path))
        client.sendall(json.dumps(request).encode() + b'\n')
        data = b''
        while b'\n' not in data and len(data) < 65536:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
    return json.loads(data.split(b'\n')[0])


def editor_jump(session, terminal=False):
    root = root_path() / 'bridges'
    entries, errors = [], []
    for file in root.glob('*.json'):
        try:
            if file.lstat().st_uid != os.getuid() or file.is_symlink():
                continue
            entry = json.loads(file.read_text())
            if terminal:
                entries.append(entry)
            elif any(session.get('cwd') == f or session.get('cwd', '').startswith(f + os.sep) for f in entry.get('workspaces', [])):
                entries.append(entry)
        except (OSError, ValueError, TypeError):
            continue  # A stale registry is never reported as a successful jump.
    if not entries:
        return {'ok': False, 'code': 'editor_bridge_not_active'}
    env = session.get('terminal') or {}
    if terminal:
        request = {'action': 'focus-terminal', 'tty': env.get('TTY', ''),
                   'processIds': [int(n) for n in env.get('PROCESS_IDS', '').split(',') if n.isdigit()]}
    else:
        request = {'action': 'open-chat', 'id': session['id'], 'cwd': session.get('cwd', '')}
        # Multiple matching windows should not all be mutated. Require an
        # unambiguous exact workspace, then select a single live editor host.
        exact = [e for e in entries if session.get('cwd') in e.get('workspaces', [])]
        if exact:
            entries = exact
        if len(entries) > 1:
            return {'ok': False, 'code': 'ambiguous_editor_windows'}
    for entry in entries:
        try:
            result = request_bridge(entry, request)
            if result.get('ok'):
                return result
            errors.append(result.get('code'))
        except (OSError, ValueError, KeyError) as exc:
            errors.append(type(exc).__name__)
    return {'ok': False, 'code': 'exact_target_not_found', 'attempts': errors}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--terminal', action='store_true')
    args = parser.parse_args()
    data = json.load(sys.stdin)
    print(json.dumps(editor_jump(data, args.terminal), ensure_ascii=False))


if __name__ == '__main__':
    main()
