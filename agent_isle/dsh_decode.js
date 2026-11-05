// Independent read-only reader. Uses the installed Harness Node zstd runtime.
const fs = require('node:fs');
const zlib = require('node:zlib');
if (typeof zlib.zstdDecompressSync !== 'function') throw new Error('Node Zstandard support is required');
const [filename, start] = process.argv.slice(2);
const fd = fs.openSync(filename, 'r');
try {
  const offset = Number(start || 0);
  const size = Math.min(fs.fstatSync(fd).size - offset, 8 * 1024 * 1024);
  const buffer = Buffer.alloc(Math.max(0, size));
  const count = fs.readSync(fd, buffer, 0, buffer.length, offset);
  let at = 0, text = '', records = [];
  while (at < count) {
    let decoded;
    try { decoded = zlib.zstdDecompressSync(buffer.subarray(at, count), {info: true, maxOutputLength: 32 * 1024 * 1024}); }
    catch { break; } // A writer can be appending an incomplete final frame.
    const consumed = decoded.engine.bytesWritten;
    if (!consumed) break;
    const next = text + decoded.buffer.toString('utf8');
    // Harness frames end on JSONL boundaries; don't acknowledge a partial row.
    if (!next.endsWith('\n')) break;
    at += consumed;
    for (const line of next.split('\n')) {
      if (!line) continue;
      const r = JSON.parse(line), d = r.data || {};
      if (r.type === 'session') records.push(r);
      else if (['turn/start','turn/end','session/title','working-directory/change','approval/asked','approval/decided','tool/call','tool/result','user/message','assistant/message','tool/ptc-dispatch'].includes(r.type)) {
        // Never return request headers, credentials, thinking, or large tool output.
        let data = d;
        if (r.type === 'assistant/message') data = {message: {content: d.message?.content?.filter(x=>x.type==='text').map(x=>({type:'text',text:String(x.text).slice(0,16000)}))}};
        if (r.type === 'tool/result') data = {message: {toolCallId:d.message?.toolCallId,content:d.message?.content?.filter(x=>x.type==='text').map(x=>({type:'text',text:String(x.text).slice(0,16000)}))},error:d.error};
        if (r.type === 'user/message') data = {source:d.source,content:d.content?.filter(x=>x.type==='text').map(x=>({type:'text',text:String(x.text).slice(0,12000)}))};
        records.push({type:r.type,seq:r.seq,time:r.time,data});
      }
    }
    text = '';
    if (records.length > 4000) break;
  }
  process.stdout.write(JSON.stringify({offset: offset + at, backlog: at < count && records.length > 4000, records}));
} finally { fs.closeSync(fd); }
