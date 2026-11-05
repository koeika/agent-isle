import json
import tempfile
import time
import unittest
from pathlib import Path
from agent_isle.core import Store, codex_record
from agent_isle.monitor import Monitor

class LatestPromptTests(unittest.TestCase):
    def test_wrapped_latest_question_replaces_previous_without_metadata(self):
        store=Store(clock=lambda:100);ctx={'id':'thread'}
        for at,text in [(80,'previous fee question'),(90,'<external_browser_tabs><in-app-browser-context>ambient only</in-app-browser-context></external_browser_tabs>\n<user_query>latest index comparison question</user_query>')]:
            event=codex_record({'timestamp':at,'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':text}]}},ctx)
            if event:store.apply(event)
        self.assertEqual(store.sessions['codex:thread'].user_message,'latest index comparison question')
        self.assertEqual(store.snapshot()['alerts'],[])
    def test_prompt_clock_is_independent_from_lifecycle_order(self):
        store=Store(clock=lambda:100)
        store.apply({'provider':'codex','id':'s','at':80,'kind':'prompt','text':'previous','status':'running'})
        store.apply({'provider':'codex','id':'s','at':95,'status':'completed'})
        store.snapshot()
        store.apply({'provider':'codex','id':'s','at':90,'kind':'prompt','text':'latest question','status':'running'})
        self.assertEqual(store.sessions['codex:s'].user_message,'latest question')
        self.assertEqual(store.sessions['codex:s'].status,'completed')
        store.apply({'provider':'codex','id':'s','at':85,'kind':'prompt','text':'old replay','status':'running'})
        self.assertEqual(store.sessions['codex:s'].user_message,'latest question')
        self.assertEqual(store.snapshot()['alerts'],[])
    def test_json_and_markup_are_valid_tasks_but_ambient_only_is_not(self):
        ctx={'id':'s'}
        def parse(text):return codex_record({'timestamp':90,'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':text}]}},ctx)
        for text in ['{"question":"compare"}','<task>compare the two indices</task>']:
            event=parse(text);self.assertIsNotNone(event);self.assertEqual(event['kind'],'prompt')
        for text in ['<environment_context>metadata</environment_context>','<external_codex_apps_open_page>{"page_id":null}</external_codex_apps_open_page>']:
            self.assertIsNone(parse(text))
    def test_prompt_cache_restore_does_not_replay_lifecycle(self):
        store=Store(clock=lambda:100)
        store.restore([{'id':'s','provider':'codex','updated':95,'status':'completed','user_message':'latest persisted question','user_message_at':90}])
        self.assertEqual(store.sessions['codex:s'].user_message,'latest persisted question')
        self.assertEqual(store.sessions['codex:s'].status,'unknown')
        self.assertEqual(store.snapshot()['alerts'],[])

    def test_attachment_envelope_keeps_request_only(self):
        ctx={'id':'s'}
        text='# Files mentioned by the user:\n\n## screenshot.png: /tmp/screenshot.png\n\n## My request:\nlatest actual question\n<image name="screenshot"></image>'
        e=codex_record({'timestamp':90,'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':text}]}},ctx)
        store=Store(clock=lambda:100);store.apply(e)
        self.assertEqual(store.sessions['codex:s'].user_message,'latest actual question')
        pasted=text.replace('# Files mentioned by the user:', '# Files pasted by the user:')
        event=codex_record({'timestamp':91,'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':pasted}]}},ctx)
        store.apply(event)
        self.assertEqual(store.sessions['codex:s'].user_message,'latest actual question')
    def test_restart_and_incremental_prompts_outside_tail_window(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);path=root/'rollout.jsonl';now=time.time()
            def record(at,typ,p):return json.dumps({'timestamp':at,'type':typ,'payload':p})+'\n'
            with path.open('w') as f:
                f.write(record(now-100,'session_meta',{'id':'s','cwd':str(root)}))
                f.write(record(now-90,'response_item',{'type':'message','role':'user','content':[{'type':'input_text','text':'previous question'}]}))
                f.write(record(now-80,'response_item',{'type':'message','role':'user','content':[{'type':'input_text','text':'<user_query>latest index comparison question</user_query>'}]}))
                for i in range(7):f.write(record(now-70+i,'response_item',{'type':'function_call_output','output':'x'*60000}))
                f.write(record(now-60,'response_item',{'type':'function_call','name':'exec'}))
            monitor=Monitor(root/'home',root/'state');monitor.add(path,'codex')
            snap=monitor.step();session=next(s for s in snap['sessions'] if s['id']=='s')
            self.assertEqual(session['user_message'],'latest index comparison question')
            self.assertEqual(session['status'],'running');self.assertEqual(snap['alerts'],[])
            with path.open('a') as f:f.write(record(now,'response_item',{'type':'message','role':'user','content':[{'type':'input_text','text':'next question'}]}))
            self.assertEqual(next(s for s in monitor.step()['sessions'] if s['id']=='s')['user_message'],'next question')

if __name__=='__main__':unittest.main()
