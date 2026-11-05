'use strict';
const connection = document.getElementById('connection');
async function refresh() {
  try {
    const response = await fetch('/api/status', {cache: 'no-store', signal: AbortSignal.timeout(3000)});
    if (!response.ok) throw new Error('offline');
    const status = await response.json();
    document.querySelector('.version').textContent = status.version;
    for (const badge of document.querySelectorAll('[data-tool]')) {
      const found = status.tools[badge.dataset.tool] === true;
      badge.textContent = found ? '已发现配置' : '尚未发现配置';
      badge.classList.toggle('detected', found);
    }
    for (const note of document.querySelectorAll('[data-hook]')) {
      const name = note.dataset.hook;
      note.textContent = status.hooks[name] ? (name === 'Cursor' ? 'Hook 已安装 · 重启 Cursor 后启用桥接。' : 'Hook 已安装 · 请新开一个会话。') : (name === 'Cursor' ? '请先在设置中安装 Hook 和桥接扩展。' : '请先在设置中安装 Hook。');
    }
    connection.textContent = '● 本地应用已连接 · 无需互联网';
    connection.classList.remove('offline');
  } catch {
    connection.textContent = '本地连接已断开 · 请先启动 Agent Isle';
    connection.classList.add('offline');
    document.querySelectorAll('[data-tool]').forEach(badge => { badge.textContent = '等待连接'; badge.classList.remove('detected'); });
  }
}
let waiting = false;
document.getElementById('demo-toggle').addEventListener('click', event => {
  waiting = !waiting;
  document.querySelector('.demo-alert').classList.toggle('waiting', waiting);
  document.querySelector('.check').textContent = waiting ? '?' : '✓';
  document.getElementById('demo-title').textContent = waiting ? '需要你的输入' : '任务完成';
  document.getElementById('demo-detail').textContent = waiting ? 'AI 正在等待你的确认。回答后，提醒自动消失。' : '回归测试已通过，点击小岛可返回原会话。';
  event.currentTarget.textContent = waiting ? '切换到「任务完成」演示 ↻' : '切换到「需要输入」演示 ↻';
});
refresh();
const timer = setInterval(refresh, 5000);
window.addEventListener('pagehide', () => clearInterval(timer), {once: true});
