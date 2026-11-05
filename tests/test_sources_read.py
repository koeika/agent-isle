import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from agent_isle.core import Store
from agent_isle.monitor import Monitor, atomic_json

class SourcesReadTests(unittest.TestCase):
    def test_completed_unread_clears_and_next_completion_is_new(self):
        store=Store(clock=lambda:100)
        store.apply({'id':'s','provider':'codex','at':90,'status':'completed'})
        self.assertTrue(store.sessions['codex:s'].unread)
        store.snapshot()
        store.apply_read_receipts({'codex:s':90})
        self.assertFalse(store.sessions['codex:s'].unread)
        store.apply({'id':'s','provider':'codex','at':91,'status':'running'})
        store.apply({'id':'s','provider':'codex','at':92,'status':'completed'})
        store.apply_read_receipts({'codex:s':90})
        self.assertTrue(store.sessions['codex:s'].unread)
        self.assertEqual(store.sessions['codex:s'].completed_at,92)
        self.assertEqual(len(store.snapshot()['alerts']),1)
    def test_receipt_cannot_clear_pending_input(self):
        store=Store(clock=lambda:100)
        store.apply({'id':'s','provider':'codex','at':90,'status':'waiting','input_open':{'q':'async'}})
        store.apply_read_receipts({'codex:s':100})
        self.assertTrue(store.sessions['codex:s'].unread)
        self.assertEqual(store.sessions['codex:s'].status,'waiting')
    def test_disabled_source_not_watched_or_returned_and_live_reenable_is_quiet(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);state=root/'state';m=Monitor(root/'home',state)
            atomic_json(state/'events/cursor.json',{'id':'c','provider':'cursor','at':m.store.clock(),'status':'completed'})
            atomic_json(state/'events/claude.json',{'id':'h','provider':'claude','at':m.store.clock(),'status':'completed'})
            snap=m.step()
            self.assertNotIn('cursor',[s['provider'] for s in snap['sessions']])
            self.assertEqual([a['provider'] for a in snap['alerts']],['claude'])
            log=root/'cursor.jsonl';log.write_text('{}\n');m.add(log,'cursor');self.assertNotIn(log,m.tails)
            atomic_json(state/'preferences.json',{'enabledProviders':['codex','claude','cursor']})
            m.step();m.add(log,'cursor');self.assertIn(log,m.tails)
            atomic_json(state/'preferences.json',{'enabledProviders':[]})
            snap=m.step();self.assertEqual(snap['sessions'],[]);self.assertEqual(snap['alerts'],[]);self.assertEqual(m.tails,{})
    def test_disabled_hook_is_quiet_and_installer_only_configures_selected_tools(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);home=root/'home';state=root/'state'
            env={**os.environ,'AGENT_ISLE_HOME':str(state),'CLAUDE_CONFIG_DIR':str(home/'.claude')}
            repo=Path(__file__).resolve().parent.parent
            hook=subprocess.run([sys.executable,str(repo/'agent_isle/monitor.py'),'hook','--provider','cursor','--event','stop'],input='{"conversation_id":"disabled","status":"completed"}',text=True,capture_output=True,env=env,check=True)
            self.assertEqual(json.loads(hook.stdout),{})
            self.assertEqual(list((state/'events').glob('*.json')),[])
            subprocess.run([sys.executable,str(repo/'agent_isle/integrations.py'),'install','--home',str(home)],capture_output=True,env=env,check=True)
            self.assertTrue((home/'.claude/settings.json').exists())
            self.assertFalse((home/'.cursor/hooks.json').exists())
            subprocess.run([sys.executable,str(repo/'agent_isle/integrations.py'),'install','--home',str(home),'--providers','cursor'],capture_output=True,env=env,check=True)
            self.assertTrue((home/'.cursor/hooks.json').exists())

    def test_disk_receipt_applied_by_real_monitor(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);m=Monitor(root/'home',root/'state')
            at=m.store.clock()
            atomic_json(m.events/'completed.json',{'id':'s','provider':'claude','at':at,'status':'completed','hook':True})
            self.assertTrue(m.step()['sessions'][0]['unread'])
            atomic_json(m.state/'read-receipts.json',{'claude:s':at})
            self.assertFalse(m.step()['sessions'][0]['unread'])

if __name__=='__main__':unittest.main()
