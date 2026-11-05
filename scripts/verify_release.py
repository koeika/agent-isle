"""Verify the actual ZIP from an isolated extraction, with an empty home/PATH.
No installed Python or developer tools are used by the extracted application.
"""
import hashlib
import http.client
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def verify(source):
    with tempfile.TemporaryDirectory(prefix='Agent Isle 新安装 ') as temp:
        root = Path(temp)
        if source.suffix == '.zip':
            subprocess.run(['ditto','-x','-k',str(source),str(root/'unpacked')],check=True)
            app = next((root/'unpacked').glob('*/Agent Isle.app'))
            payload = app.parent
            for line in (payload/'SHA256SUMS.txt').read_text().splitlines():
                digest, relative = line.split('  ',1)
                path = payload/relative
                assert path.resolve().is_relative_to(payload.resolve()), 'unsafe checksum path'
                assert hashlib.sha256(path.read_bytes()).hexdigest()==digest, 'checksum mismatch: '+relative
            print('PASS: all ZIP payload checksums')
        else:
            app = root/'relocated path'/'Agent Isle.app'
            app.parent.mkdir()
            shutil.copytree(source,app)
        resources = app/'Contents/Resources'
        runtime = resources/'Runtime/python'
        exe = runtime/'bin/python3'
        for path in [exe,runtime/'Resources/Python.app/Contents/MacOS/Python',resources/'Guide/index.html',resources/'Guide/guide.js',resources/'Guide/guide.css',resources/'agent-isle-bridge.vsix',resources/'Sounds/complete.wav',resources/'AgentIsle.icns',resources/'Licenses/OpenSSL-LICENSE.txt']:
            assert path.is_file(), 'missing package resource: '+str(path.relative_to(app))
        assert not list(runtime.rglob('site-packages')), 'user packages must not be shipped'
        assert not list(app.rglob('snapshot.json')), 'user snapshot must not be shipped'
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        assert info['LSMinimumSystemVersion']=='14.0'
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
        for binary in [app/'Contents/MacOS/agent-isle',exe,runtime/'Python']:
            arches=subprocess.check_output(['lipo','-archs',str(binary)],text=True)
            assert 'arm64' in arches and 'x86_64' in arches
        home=root/'empty-home'; home.mkdir()
        state=root/'test-state'
        env={'PATH':'/usr/bin:/bin','HOME':str(home),'PYTHONHOME':str(runtime),'PYTHONNOUSERSITE':'1','PYTHONDONTWRITEBYTECODE':'1','AGENT_ISLE_HOME':str(state)}
        code='import sys,sqlite3,ssl,http.server,ctypes,json; print(json.dumps({"prefix":sys.prefix,"executable":sys.executable,"version":sys.version.split()[0]}))'
        data=json.loads(subprocess.check_output([str(exe),'-c',code],env=env,cwd=home,text=True))
        assert Path(data['prefix'])==runtime and str(app) in data['executable']
        print('PASS: relocated runtime imports SQLite / SSL / HTTP / ctypes with isolated HOME and PATH')
        script=resources/'agent_isle/integrations.py'
        subprocess.run([str(exe),str(script),'install','--home',str(home)],env=env,cwd=home,check=True,stdout=subprocess.PIPE)
        hooks=json.loads((home/'.claude/settings.json').read_text())['hooks']
        for event, expected in [('UserPromptSubmit','running'),('Stop','completed')]:
            command=hooks[event][0]['hooks'][0]['command']
            assert 'PYTHONHOME=' in command and str(app) in command
            run=subprocess.run(command,shell=True,input=json.dumps({'session_id':'isolated-release-task','cwd':str(home),'prompt':'release verification fixture'}),env=env,cwd=home,text=True,capture_output=True,check=True)
            assert json.loads(run.stdout)=={}
            snap=json.loads(subprocess.check_output([str(exe),str(resources/'agent_isle/monitor.py'),'watch','--once','--home',str(home),'--state',str(state)],env=env,cwd=home,text=True))
            assert next(s for s in snap['sessions'] if s['id']=='isolated-release-task')['status']==expected
        print('PASS: packaged installer -> actual generated Hook -> monitor spool -> completed status')
        child=subprocess.Popen([str(exe),str(resources/'agent_isle/guide.py'),'--assets',str(resources/'Guide')],env=env,cwd=home,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            from urllib.parse import urlsplit
            url=json.loads(child.stdout.readline())['url']; parts=urlsplit(url)
            assert parts.hostname=='127.0.0.1'
            client=http.client.HTTPConnection(parts.hostname,parts.port,timeout=3)
            client.request('GET','/'); response=client.getresponse(); body=response.read()
            assert response.status==200 and '把等待'.encode() in body
            client.request('GET','/api/status'); status=json.loads(client.getresponse().read())
            assert status['tools']['Codex'] is False and status['hooks']['Claude Code'] is True
            client.close()
        finally:
            child.terminate(); child.wait(timeout=5)
        try:
            client=http.client.HTTPConnection(parts.hostname,parts.port,timeout=1); client.request('GET','/')
        except OSError: pass
        else: raise AssertionError('server still listening after termination')
        print('PASS: packaged local guide / API from empty home; port closes after child termination')
        print('PASS: universal slices and minimum OS metadata; physical Intel/macOS14 not exercised')

if __name__=='__main__': verify(Path(sys.argv[1]).resolve())
