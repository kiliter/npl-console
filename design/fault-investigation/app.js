/* 本文件只驱动本地模拟状态，不发送网络请求、不读取附件内容、不持久化业务材料。 */
'use strict';
const $ = (selector) => document.querySelector(selector);
const sources = {
  E01: {title:'接口返回 HTTP 400',kind:'模拟接口记录',location:'演示工单 / 接口记录 / 10:18:42',body:'POST /test/un_look\n时间：2026-09-20 10:18:42 +08:00\n单据号：DEMO-20260920-0086\nbucketName: demo-bucket\nobjectName: demo/document.pdf\next8: 0\n认证头：已移除\nHTTP 400 · 响应无业务错误详情',note:'此记录为人工构造的演示材料，不是当前客户端或生产服务的真实请求。'},
  E02: {title:'相同状态码覆盖两个失败分支',kind:'源码静态参照',location:'npl-js / npl-service-jiangsu/src/main/java/com/agile/js/eg/controller/TestController.java:94',body:'94  @PostMapping("/un_look")\n95  public ResponseEntity<Resource> download4Obs(...) {\n99    if (!JwtTokenKeyStoreUtil.validateToken(totp)) {\n100     return ResponseEntity.badRequest().build();\n101   }\n102   try {\n103     FileResult fileResult = ObsWrapper.wrapper(ext8)\n          .obsHandler(obsHandler).read(bucketName, objectName);\n      // 此处省略成功响应装配。\n108   } catch (Exception e) {\n109     return ResponseEntity.badRequest().build();\n110   }\n112 }',note:'根据本地源码手工节选，签名和长行已缩写。行号以设计时读取的文件为参照；不是已固定部署版本的证据快照。'},
  E03: {title:'ext8 进入平台加解密适配器',kind:'源码静态参照',location:'npl-backend / npl-backend-api/src/main/java/com/agile/npl/wo/wrapper/ObsWrapper.java',body:'// 根据加密类型选择 IEncryption，供文件处理包装器使用。\npublic static ObsWrapper wrapper(String encryptType) {\n  IEncryption iEncryption = EncryptionFactory.instance(encryptType);\n  return new ObsWrapper(iEncryption);\n}\n\npublic ObsHandlerWrapper obsHandler(ObsHandler obsHandler) {\n  return new ObsHandlerWrapper(iEncryption, obsHandler);\n}',note:'该片段只证明参数进入加解密适配层，不证明 ext8 错误，也不证明生产对象存在或可以读取。'},
  E04: {title:'演示读取补充结果',kind:'模拟敏感读取',location:'演示适配器 / 当前调查 / 本次允许',body:'查询对象：演示工单的文件元数据\n范围：DEMO-20260920-0086\n结果：材料仅包含对象路径与加密标记\n未包含：对象存储返回码、鉴权判定、解密异常\n结论：仍不能确认根因',note:'允许本次只改变原型状态；没有执行 HTTP、数据库或对象存储读取。'}
};
const records = [{id:1,title:'工单已生成，PDF 无法读取',problem:'工单已生成，但打开 PDF 返回 400。请结合接口与平台代码，判断从哪里继续排查。',caseNo:'DEMO-20260920-0086',env:'演示环境',state:'idle',phase:2,evidence:['E01','E02','E03'],notes:[],files:[],decision:null}];
let current = records[0], tab = 'timeline', timer = null, toastTimer = null;

/** 将所有用户输入转义后再插入模板，确保故障描述与文件名仅作为文本。 */
function escapeHtml(value) { return String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char])); }
/** 短提示用于明确模拟动作结果，不把本地状态变化表述为真实服务成功。 */
function toast(message) { clearTimeout(toastTimer); $('#toast').textContent = message; $('#toast').hidden = false; toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 3500); }
/** 生成证据引用，统一由事件委托打开调查内保留片段。 */
function ref(id) { return `<button class="evidence-link" data-evidence="${id}">${id} ↗</button>`; }
/** 仅显示当前会话内的历史；刷新页面会回到初始演示。 */
function renderHistory() {
  const term = $('#historySearch').value.trim();
  const found = records.filter(record => record.title.includes(term));
  $('#history').innerHTML = found.map(record => `<button class="history-item ${record === current ? 'selected' : ''}" data-history="${record.id}"><strong>${escapeHtml(record.title)}</strong><small><span>今天 · 模拟调查</span><span>${record.state === 'completed' ? '已出报告' : '调查记录'}</span></small></button>`).join('') || '<p class="notice">没有匹配的调查记录</p>';
}
/** 调查过程只展示公开动作和证据摘要，不展示模型私有推理。 */
function timelineHtml() {
  const intro = `<div class="user-note"><div class="row between"><strong>故障描述</strong><small>来自工单上下文 · 模拟</small></div><p>${escapeHtml(current.problem)}</p><span class="chip">▤ ${escapeHtml(current.caseNo)}</span></div>`;
  if (current.phase === 0) return intro + '<div class="empty"><h3>正在整理调查范围</h3><p>模拟关联工单、代码源和时间范围。</p></div>';
  const steps = `<div class="timeline"><div class="step"><span class="step-icon">✓</span><div class="step-head"><strong>已载入文件读取排查手册</strong><small>模拟动作</small></div><p>核对接口返回 → 追踪读取路径 → 补齐运行证据</p></div><div class="step"><span class="step-icon blue">⌕</span><div class="step-head"><strong>关联接口记录与代码入口</strong><small>2 个代码源</small></div><details class="tool-card"><summary><span>代码检索 · download4Obs / ObsWrapper</span></summary><div class="tool-body">查询范围：npl-js 与 npl-backend。这里回放的是设计阶段整理的片段，未执行在线代码检索。${ref('E02')}${ref('E03')}</div></details><div class="chain"><div class="chain-node">维护中心<small>PDF 文件读取</small></div><span class="chain-arrow">→</span><div class="chain-node focus">npl-js<small>download4Obs</small></div><span class="chain-arrow">→</span><div class="chain-node">npl-backend<small>ObsWrapper</small></div></div><p>同一调用跨越江苏定制入口与平台文件处理层。</p>${ref('E02')}${ref('E03')}</div>${current.phase >= 2 ? `<div class="step"><span class="step-icon blue">◇</span><div class="step-head"><strong>建立候选原因，标出证据缺口</strong><small>尚未确认</small></div><div class="hypothesis"><h3>HTTP 400 无法区分鉴权失败与读取异常</h3><p>入口两个分支均返回 400；文件路径、存储返回与解密异常还没有运行证据。当前不能排除任一分支。</p>${ref('E01')}${ref('E02')}<div class="footnote">下一步：关联同一请求的鉴权结果和文件读取异常。</div></div></div>` : ''}</div>`;
  const notes = current.notes.map(note => `<div class="notice"><strong>补充方向 · ${current.state === 'running' ? '已接收，等待当前步骤结束' : '已记录'}</strong><br>${escapeHtml(note)}</div>`).join('');
  let tail = '';
  if (current.state === 'waiting') tail = `<div class="approval"><div class="row between"><h3>需要允许一次敏感读取</h3><span class="demo-badge">模拟审批</span></div><p>读取当前工单的文件元数据，用于核对对象路径与加密标记。范围限 ${escapeHtml(current.caseNo)}；不读取 PDF 正文或认证材料。</p><p>环境：${escapeHtml(current.env)} · 有效范围：本次调查中的一次读取</p><div class="row"><button class="button primary" id="approve">允许本次</button><button class="button" id="reject">拒绝，继续现有证据</button></div></div>`;
  if (current.state === 'completed') tail = `<div class="notice">${current.decision === 'denied' ? '已拒绝敏感读取，使用现有证据完成报告。' : '本轮模拟调查已结束。'} 结论：证据不足，根因待确认。 <button class="evidence-link" data-open-report>查看诊断报告 →</button></div>`;
  if (current.state === 'cancelled') tail = '<div class="notice">调查已停止。已保留现有证据，可继续调查。未完成的敏感读取允许已撤销。</div>';
  return intro + steps + notes + tail;
}
/** 报告明确区分静态代码观察、演示材料与未核对的运行事实。 */
function reportHtml() {
  if (current.state !== 'completed') return '<div class="empty"><span class="repo-icon" style="margin:auto">↗</span><h3>本轮诊断报告尚未生成</h3><p>继续调查并处理读取确认后，可查看完整模拟报告。</p><button class="button" data-open-timeline>返回调查过程</button></div>';
  return `<div class="report-banner"><div class="row between"><h3>证据不足 · 根因待确认</h3><span class="demo-badge">模拟报告</span></div><p>已定位到读取入口的两个失败分支，还需要运行证据才能区分原因。</p></div><div class="report-section"><h3>现象</h3><p>${escapeHtml(current.problem)}</p><p>本轮回放使用固定的 PDF 读取演示案例；自定义描述仅用于交互验证。</p>${ref('E01')}</div><div class="report-section"><h3>候选原因</h3><p>① JWT 校验未通过。② 文件读取或后续处理抛出异常。两者均可能表现为 HTTP 400，尚无证据确认其中任一项。</p>${ref('E02')}${ref('E03')}</div><div class="report-section"><h3>证据</h3><p>模拟接口记录与两个仓库的静态节选${current.evidence.includes('E04') ? '，以及本轮模拟元数据读取结果' : ''}。</p>${current.evidence.map(ref).join('')}</div><div class="report-section"><h3>已排除项</h3><p>暂无。代码能定位候选分支，但当前材料不足以排除鉴权、存储读取或解密问题。</p></div><div class="report-section"><h3>建议的下一步</h3><ol><li>核对 npl-js 部署提交及实际使用的 npl-backend 制品版本。</li><li>获取同一请求的鉴权判定、异常类型与时间，去除认证材料。</li><li>核对 bucket、objectName 与 ext8 的业务来源，并按只读权限验证对象读取。</li></ol></div><div class="report-section"><h3>尚未验证</h3><p>部署版本、真实日志覆盖范围、对象存储状态及实际解密结果均未验证。${current.decision === 'denied' ? '用户已拒绝模拟敏感读取，本轮没有此项补充材料。' : ''} 配置中心不自动访问，由人工提供脱敏结果。</p></div>`;
}
/** 使用单一调查状态刷新视图，让按钮、报告和审批状态保持一致。 */
function render() {
  $('#title').textContent = current.title; $('#caseTag').textContent = current.caseNo;
  $('#contextCase').textContent = current.caseNo; $('#envTag').textContent = current.env;
  const states = {idle:'待继续调查',running:'模拟调查中',waiting:'等待读取确认',cancelling:'正在停止',cancelled:'已停止',completed:'本轮已完成'};
  $('#status').textContent = states[current.state]; $('#evidenceCount').textContent = current.evidence.length;
  document.querySelectorAll('[data-tab]').forEach(button => { button.classList.toggle('active', button.dataset.tab === tab); button.setAttribute('aria-selected', String(button.dataset.tab === tab)); });
  $('#content').innerHTML = tab === 'timeline' ? timelineHtml() : tab === 'report' ? reportHtml() : current.evidence.map(id => `<button class="evidence-card" data-evidence="${id}"><div class="row"><span>${id} · ${sources[id].kind}</span><span>查看片段 ↗</span></div><strong>${sources[id].title}</strong><p>${escapeHtml(sources[id].note)}</p></button>`).join('') || '<div class="empty">还没有证据，请等待模拟步骤完成。</div>';
  const active = ['running','waiting','cancelling'].includes(current.state);
  $('#stop').hidden = !active; $('#stop').disabled = current.state === 'cancelling';
  $('#send').textContent = active ? '补充方向 ↗' : current.phase === 0 ? '开始调查 ↗' : '继续调查 ↗';
  $('#send').disabled = current.state === 'cancelling'; $('#export').disabled = current.state !== 'completed';
  $('#attachmentList').innerHTML = current.files.map(name => `<span class="chip">附件名：${escapeHtml(name)}</span>`).join(''); renderHistory();
}
/** 定时器仅回放预设场景，每次启动前取消旧任务，避免停止后旧回调复活。 */
function run() {
  clearTimeout(timer); current.state = 'running'; tab = 'timeline'; render();
  const record = current;
  timer = setTimeout(() => {
    if (record !== current || record.state !== 'running') return;
    current.phase = 2; current.evidence = ['E01','E02','E03']; current.state = 'waiting'; render();
  }, 1500);
}
/** 运行中接受方向补充；空闲时回放下一轮，不把固定演示描述当模型诊断。 */
function send() {
  const text = $('#direction').value.trim();
  if (['running','waiting'].includes(current.state)) {
    if (!text) return toast('请先填写补充方向');
    current.notes.push(text); $('#direction').value = ''; render(); return toast('已记录补充方向；原型仍回放固定演示案例');
  }
  if (text) current.notes.push(text);
  $('#direction').value = ''; run();
}
/** 审批绑定当前模拟调查；重复点击不会产生新的结果。 */
function resolveApproval(allowed) {
  if (current.state !== 'waiting') return;
  current.decision = allowed ? 'allowed' : 'denied';
  if (allowed && !current.evidence.includes('E04')) current.evidence.push('E04');
  current.state = 'completed'; render(); toast(allowed ? '已模拟本次读取，报告已生成' : '已拒绝读取，报告注明证据缺口');
}
/** 停止会撤销计时器和待处理审批，保留已取得的演示证据。 */
function stop() {
  clearTimeout(timer); current.state = 'cancelling'; render();
  const record = current;
  timer = setTimeout(() => { if (record !== current) return; current.state = 'cancelled'; current.decision = null; render(); }, 350);
}
/** 证据始终限定在当前调查已经取得的编号内。 */
function showEvidence(id) {
  if (!current.evidence.includes(id)) return;
  const evidence = sources[id]; $('#evidenceTitle').textContent = `${id} · ${evidence.title}`;
  $('#evidenceBody').innerHTML = `<span class="demo-badge">${evidence.kind}</span><p>${escapeHtml(evidence.location)}</p><pre>${escapeHtml(evidence.body)}</pre><p>${escapeHtml(evidence.note)}</p><div class="notice">归属：${escapeHtml(current.caseNo)} · 部署版本未核对</div>`;
  $('#evidenceDialog').showModal();
}
/** 新调查对话框默认携带当前工单，保留用户修改机会。 */
function openNew() { $('#newForm').elements.caseNo.value = current.caseNo; $('#newDialog').showModal(); }
/** 项目页展示拟接入范围，不提供虚假的连接测试或保存按钮。 */
function showSources(visible) {
  $('#sourcesView').hidden = !visible; $('#investigationView').hidden = visible;
  $('#sourcesNav').classList.toggle('active', visible); $('#investigationNav').classList.toggle('active', !visible);
  $('#pageName').textContent = visible ? '项目与数据源' : '故障调查';
  if (visible) $('#sourcesView').innerHTML = `<div class="sources-grid"><div class="source-card"><span class="demo-badge">方案预览</span><h3>一个业务项目，两个代码源</h3><p>NPL 江苏的定制代码与平台代码共同构成调查范围，使用独立版本标识关联。</p><div class="source-row"><code>npl-js</code><span>江苏定制入口</span></div><div class="source-row"><code>npl-backend</code><span>平台编排与文件处理</span></div><p>部署提交及依赖制品映射：待核对</p></div><div class="source-card"><span class="demo-badge">尚未接入</span><h3>调查数据源</h3><div class="source-row"><span>工单与关联材料</span><span>拟复用现有查询能力</span></div><div class="source-row"><span>代码检索</span><span>拟接服务端固定快照</span></div><div class="source-row"><span>业务日志</span><span>待选择实际来源</span></div><div class="source-row"><span>模型服务</span><span>待核验 Pi SDK 与端点</span></div></div><div class="source-card wide"><h3>从 HTML 验证到原生工作台</h3><p>先验收此原型的业务流程与布局，再在同一 HTML 界面接入真实调查服务。接口、事件和状态稳定后，用 Flutter 原生组件实现相同流程。</p><p>本页不保存任何连接配置。现有客户端密钥不会自动转交排障服务；Zookeeper 不开放自动访问。</p><button class="button" id="returnInvestigation">返回调查工作台 →</button></div></div>`;
}
/** 导出真正的本地文件；报告头部保留模拟标记及材料限制。 */
function exportReport() {
  if (current.state !== 'completed') return;
  const text = `# 故障调查报告（模拟）\n\n单据：${current.caseNo}\n环境：${current.env}\n\n## 现象\n${current.problem}\n\n本轮为固定 PDF 读取案例回放，不是对输入内容的真实诊断。\n\n## 根因\n证据不足：鉴权失败、文件读取或处理异常均未排除。\n\n## 证据\n${current.evidence.map(id => `${id}：${sources[id].title}（${sources[id].kind}）\n来源：${sources[id].location}\n${sources[id].body}\n限制：${sources[id].note}`).join('\n\n')}\n\n## 已排除项\n暂无。\n\n## 建议\n核对部署与制品版本，补充同请求的鉴权判定、文件读取异常，核对对象路径及加密标记。\n\n## 尚未验证\n生产日志、部署版本、对象存储与解密结果。敏感读取：${current.decision === 'allowed' ? '模拟允许，未执行真实请求' : '已拒绝'}。\n\n## 补充方向\n${current.notes.join('\n') || '无'}\n`;
  const url = URL.createObjectURL(new Blob([text], {type:'text/markdown;charset=utf-8'}));
  const anchor = document.createElement('a'); anchor.href = url; anchor.download = '故障调查报告-模拟.md'; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); toast('已导出带有模拟标记的报告');
}
// 注册固定入口；对动态生成的证据、审批与页签使用统一事件委托。
$('#send').addEventListener('click', send); $('#stop').addEventListener('click', stop);
$('#newSide').addEventListener('click', openNew); $('#newTop').addEventListener('click', openNew);
$('#sourcesNav').addEventListener('click', () => showSources(true)); $('#investigationNav').addEventListener('click', () => showSources(false));
$('#attach').addEventListener('click', () => $('#file').click()); $('#export').addEventListener('click', exportReport);
$('#historySearch').addEventListener('input', renderHistory);
$('#file').addEventListener('change', event => { current.files.push(...Array.from(event.target.files).map(file => file.name)); event.target.value = ''; render(); toast('仅添加文件名，没有上传或解析文件'); });
$('#direction').addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key === 'Enter' && !event.isComposing && !$('#send').disabled) { event.preventDefault(); send(); } });
$('#newForm').addEventListener('submit', event => {
  event.preventDefault(); const data = new FormData(event.target); const problem = String(data.get('problem')).trim();
  if (!problem) return toast('请填写故障现象');
  clearTimeout(timer); if (['running','waiting','cancelling'].includes(current.state)) current.state = 'cancelled';
  current = {id:records.length + 1,title:problem.length > 30 ? problem.slice(0,30) + '…' : problem,problem,caseNo:String(data.get('caseNo')).trim(),env:String(data.get('environment')),state:'idle',phase:0,evidence:[],notes:[],files:[],decision:null};
  records.unshift(current); $('#newDialog').close(); showSources(false); $('#direction').value = ''; run();
});
/** 工单入口演示携带上下文，而不是直接修改既有维护中心页面。 */
function openWork() { $('#workCase').textContent = current.caseNo; $('#workDialog').showModal(); }
$('#workNav').addEventListener('click', openWork); $('#workCard').addEventListener('click', openWork);
$('#fromWork').addEventListener('click', () => { $('#workDialog').close(); openNew(); });
document.addEventListener('click', event => {
  const button = event.target.closest('button'); if (!button) return;
  if (button.dataset.close) document.getElementById(button.dataset.close).close();
  if (button.dataset.evidence) showEvidence(button.dataset.evidence);
  if (button.dataset.tab) { tab = button.dataset.tab; render(); }
  if (button.hasAttribute('data-open-report')) { tab = 'report'; render(); }
  if (button.hasAttribute('data-open-timeline')) { tab = 'timeline'; render(); }
  if (button.id === 'approve') resolveApproval(true);
  if (button.id === 'reject') resolveApproval(false);
  if (button.id === 'returnInvestigation') showSources(false);
  if (button.dataset.history) {
    clearTimeout(timer); if (['running','waiting','cancelling'].includes(current.state)) current.state = 'cancelled';
    current = records.find(record => record.id === Number(button.dataset.history)); tab = 'timeline'; showSources(false); render();
  }
});
render();
