import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from agent_isle.core import Store
from agent_isle.dsh import DshTail, dsh_record, runtime
from agent_isle.monitor import Monitor, atomic_json


def event(kind, at, **data): return {'type': kind, 'seq':at, 'time':at, 'data':data}
def header(sid='session-demo', **more): return {'type':'session','id':sid,'createdAt':1,'cwd':'/tmp/demo',**more}


class DshTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ); env.start(); self.addCleanup(env.stop)
        os.environ.pop("DSH_HOME", None)

    def test_lifecycle_and_latest_content_and_read_receipts(self):
        ctx={'id':'session-demo','provider':'dsh'}; store=Store(clock=lambda:100)
        records=[header(),event('session/title',2,title='DSH regression'),event('turn/start',3,turn=1),event('user/message',4,source={'kind':'user'},content=[{'type':'text','text':'latest question'}]),event('assistant/message',5,message={'content':[{'type':'text','text':'done'}]}),event('turn/end',6,turn=1,reason={'kind':'completed'})]
        for r in records:
            v=dsh_record(r,ctx)
            if v: store.apply(v)
        s=store.sessions['dsh:session-demo'];self.assertEqual((s.title,s.status,s.user_message,s.summary),('DSH regression','completed','latest question','done'))
        self.assertEqual(len(store.snapshot()['alerts']),1)
        store.apply_read_receipts({'dsh:session-demo':6});self.assertFalse(s.unread)
        for r in [event('turn/start',7,turn=2),event('turn/end',8,turn=2,reason={'kind':'completed'})]:store.apply(dsh_record(r,ctx))
        self.assertTrue(s.unread);self.assertEqual(len(store.snapshot()['alerts']),1)

    def test_questions_and_approvals_survive_other_tools_until_answered(self):
        ctx={'id':'s'}; store=Store(clock=lambda:100)
        def apply(r):
            v=dsh_record(r,ctx)
            if v:store.apply(v)
        apply(event('turn/start',1,turn=1));apply(event('tool/call',2,name='ask_user_question',callId='ask'))
        apply(event('tool/result',3,message={'toolCallId':'ask','content':[{'type':'text','text':'{"pending":true}'}]}))
        apply(event('tool/call',4,name='exec',callId='exec'));self.assertEqual(store.sessions['dsh:s'].status,'waiting')
        apply(event('turn/end',5,turn=1,reason={'kind':'completed'}));self.assertEqual(store.sessions['dsh:s'].status,'waiting')
        apply(event('user/message',6,source={'kind':'user-question-reply','callId':'ask'},content=[]));self.assertEqual(store.sessions['dsh:s'].status,'completed')
        apply(event('turn/start',7,turn=2));apply(event('approval/asked',8,id='approval',toolName='exec'));self.assertEqual(store.sessions['dsh:s'].status,'waiting')
        apply(event('approval/decided',9,id='approval',outcome='allow'));self.assertEqual(store.sessions['dsh:s'].status,'running')

    def test_non_success_end_and_subagents_are_not_completed(self):
        for reason,status in [('error','error'),('aborted','cancelled'),('interrupted','cancelled'),('max-tokens','error'),('unknown','unknown')]:
            self.assertEqual(dsh_record(event('turn/end',2,turn=1,reason={'kind':reason}),{'id':'s'})['status'],status)
        ctx={'id':'child'};self.assertIsNone(dsh_record(header('child',delegationDepth=1),ctx));self.assertIsNone(dsh_record(event('turn/end',2,reason={'kind':'completed'}),ctx))

    def test_actual_monitor_live_toggle_append_and_no_historical_alerts(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp); state=home/'state'; path=home/'.dsh/sessions/project/session-demo/session.v4.jsonl';path.parent.mkdir(parents=True)
            path.write_text('\n'.join(json.dumps(x) for x in [header(),event('turn/start',time.time()-2,turn=1),event('turn/end',time.time()-1,turn=1,reason={'kind':'completed'})])+'\n')
            atomic_json(state/'preferences.json',{'enabledProviders':['dsh']});m=Monitor(home=home,state=state);snap=m.step();self.assertEqual(snap['sessions'][0]['status'],'completed');self.assertEqual(snap['alerts'],[])
            with path.open('a') as f:
                for r in [event('turn/start',time.time(),turn=2),event('turn/end',time.time()+.1,turn=2,reason={'kind':'error'})]:f.write(json.dumps(r)+'\n')
            snap=m.step();self.assertEqual(snap['sessions'][0]['status'],'error');self.assertEqual(len(snap['alerts']),1)
            atomic_json(state/'preferences.json',{'enabledProviders':[]});self.assertEqual(m.step()['sessions'],[]);self.assertFalse(m.tails)
            atomic_json(state/'preferences.json',{'enabledProviders':['dsh']});self.assertEqual(m.step()['alerts'],[])

    def test_real_zstd_concatenated_frames_partial_append_and_reset(self):
        exe=runtime();self.assertIsNotNone(exe,'DSH or a Node runtime with zstd is required for this integration test')
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'session.v4.jsonl.zstd'
            def compress(record):
                return subprocess.check_output([exe,'-e','process.stdout.write(require("node:zlib").zstdCompressSync(Buffer.from(process.argv[1])))',json.dumps(record)+'\n'],env={**os.environ,'ELECTRON_RUN_AS_NODE':'1'},stderr=subprocess.DEVNULL)
            first=compress(header());second=compress(event('turn/start',2,turn=1));last=compress(event('turn/end',3,turn=1,reason={'kind':'completed'}))
            path.write_bytes(first+second+last[:7]);reader=DshTail(path);quiet,rows=reader.read();self.assertTrue(quiet);self.assertEqual([r['type'] for r in rows],['session','turn/start']);self.assertEqual(reader.offset,len(first+second))
            with path.open('ab') as f:f.write(last[7:])
            quiet,rows=reader.read();self.assertFalse(quiet);self.assertEqual(rows[0]['type'],'turn/end');self.assertFalse(reader.read()[0])
            with path.open('ab') as f:f.write(compress(event('turn/start',4,turn=2)))
            quiet,rows=reader.read();self.assertFalse(quiet);self.assertEqual(rows[0]['data']['turn'],2)
            path.write_bytes(first);quiet,rows=reader.read();self.assertTrue(quiet);self.assertEqual(rows[0]['type'],'session')
