"""DeepSeek Harness v4 events, read-only; never loads plugins or credentials."""
import json
import os
import shutil
import subprocess
from pathlib import Path
from agent_isle.core import Tail, text_content, timestamp


def runtime():
    for root in (Path('/Applications'), Path.home() / 'Applications'):
        exe = root / 'DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'
        if exe.is_file(): return str(exe)
    return shutil.which('node')


def pending_result(content):
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict) or block.get('type') != 'text': continue
        try:
            value = json.loads(block.get('text', ''))
            if isinstance(value, dict) and value.get('pending') is True: return True
        except (ValueError, TypeError): pass
    return False


class DshTail:
    def __init__(self, path):
        self.path = Path(path)
        self.plain = Tail(path) if self.path.suffix == '.jsonl' else None
        self.offset = 0
        self.identity = None
        self.signature = None
        self.bootstrapping = True
        self.stalled = False
        self.buffer = None

    def read(self):
        if self.buffer is not None:
            result, self.buffer = self.buffer, None
            return result
        if self.plain: return self.plain.read()
        stat = self.path.stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity != self.identity or stat.st_size < self.offset:
            self.identity, self.offset, self.bootstrapping = identity, 0, True
        signature = (identity, stat.st_mtime_ns, stat.st_size)
        if signature == self.signature and (self.offset >= stat.st_size or self.stalled): return False, []
        exe = runtime()
        if not exe: raise ValueError('DSH zstd runtime unavailable')
        result = subprocess.run([exe, str(Path(__file__).with_name('dsh_decode.js')), str(self.path), str(self.offset)],
                                env={**os.environ, 'ELECTRON_RUN_AS_NODE': '1'}, capture_output=True, timeout=8)
        if result.returncode or len(result.stdout) > 8 * 1024 * 1024: raise ValueError('DSH decode failed')
        decoded = json.loads(result.stdout)
        quiet = self.bootstrapping
        if decoded['offset'] == self.offset:
            self.signature, self.stalled = signature, True
            return quiet, []
        self.stalled = False
        initial_remaining = stat.st_size - self.offset
        self.offset = decoded['offset']
        self.signature = signature
        if self.offset >= stat.st_size or (initial_remaining <= 8 * 1024 * 1024 and not decoded.get("backlog")): self.bootstrapping = False
        return quiet, decoded['records']


def dsh_record(record, ctx):
    if not isinstance(record, dict): return None
    kind, data = record.get('type'), record.get('data') or {}
    if not isinstance(data, dict): return None
    if kind == 'session':
        if record.get('delegationDepth', 0) > 0: ctx['hidden'] = True; return None
        ctx.update(id=record.get('id', ctx.get('id')), cwd=record.get('cwd', ''), origin='DeepSeek Harness')
    if ctx.get('hidden'): return None
    at = timestamp(record.get('time', record.get('createdAt')), ctx.get('mtime', 0))
    event = {k:ctx[k] for k in ('id','cwd','transcript','origin') if k in ctx}
    event.update(provider='dsh', at=at, turn=str(data.get('turn', ctx.get('turn', ''))))
    pending = ctx.setdefault('dsh_inputs', {})
    if kind == 'session': return {**event, 'status':'idle', 'detail':'会话已发现'}
    if kind == 'session/title':
        ctx['named_title'] = data.get('title', '')
        return {**event, 'title':ctx['named_title'], 'title_source':'named'}
    if kind == 'working-directory/change': return {**event, 'cwd':data.get('cwd', '')}
    if kind == 'turn/start':
        ctx['turn'] = str(data.get('turn', '')); ctx.pop('dsh_end', None)
        return {**event, 'status':'running', 'detail':'正在思考'}
    if kind == 'user/message':
        source = data.get('source') or {}
        if source.get('kind') == 'user': return {**event,'kind':'prompt','text':text_content(data.get('content'))}
        if source.get('kind') == 'user-question-reply':
            call = str(source.get('callId', '')); pending.pop(call, None)
            return {**event,'input_close':[call],'status':ctx.get('dsh_end','running'),'detail':'输入已回答'}
        return None
    if kind == 'assistant/message': return {**event,'assistant_message':text_content((data.get('message') or {}).get('content')),'detail':'正在回复'}
    if kind in ('approval/asked','tool/call','tool/ptc-dispatch'):
        call = str(data.get('id') or data.get('subCallId') or data.get('callId') or '')
        name = data.get('toolName') or data.get('name') or ''
        if kind == 'approval/asked' or name == 'ask_user_question':
            pending[call] = name or 'approval'
            return {**event,'status':'waiting','detail':'需要你授权' if kind=='approval/asked' else '需要你回答问题','input_open':{call:name or 'approval'}}
        return {**event,'status':'running','detail':'正在调用 '+name}
    if kind in ('approval/decided','tool/result'):
        call = str(data.get('id') or (data.get('message') or {}).get('toolCallId') or '')
        if kind == 'tool/result' and call in pending and (pending_result((data.get('message') or {}).get('content')) or (data.get('error') or {}).get('code') == 'tool-outcome-unknown'): return None
        pending.pop(call,None)
        return {**event,'input_close':[call],'status':ctx.get('dsh_end','running'),'detail':'正在处理工具结果'}
    if kind == 'turn/end':
        reason = (data.get('reason') or {}).get('kind')
        status = {'completed':'completed','aborted':'cancelled','interrupted':'cancelled','error':'error','blocked':'error','max-tokens':'error','forked':'unknown'}.get(reason,'unknown')
        ctx['dsh_end'] = status
        if pending and status == 'completed': return {**event,'status':'waiting','detail':'需要你回答问题'}
        pending.clear()
        return {**event,'status':status,'detail':{'completed':'本轮任务已完成','cancelled':'本轮任务已中止','error':'本轮未完成：'+str(reason)}.get(status,'结束原因待确认'),'clear_inputs':True}
    return None
