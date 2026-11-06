/* ==========================================================================
   无纸化维护中心 · NPL Console v1.6.2 高保真全功能交互原型引擎
   包含：
   1. 工单查询工作台（5 组 WO_INFO 字段、A4 电子单据 PDF 阅读、三级确认上传修复、
      JSON/XML/全量报文递归专注树、手写签字与证件影像连续画廊）
   2. 单据图片修复工作台（左旧单据选图、中共享素材区、右新单据实时合成预览、
      常驻 SVG 流光贝塞尔曲线「左图 → 共享卡片 → 右图」、旧页镜像/补页、本地导图）
   3. 五表数据查询与会话内 16 字节 SM4 实时本地解密（含 SYS_INTER_RESULT）
   4. 容器日志文件浏览（Server/Web 多 Pod 副本、1.5MB 分片下载、ls *.log 通配符批量下载）
   5. 多环境配置、JKS 密钥库导入、应用内更新检查、接口记录与 runtime-*.jsonl 运行日志
   ========================================================================== */

const ICONS = {
  search: 'M21 21l-4.35-4.35M17 10.5a6.5 6.5 0 1 1-13 0 6.5 6.5 0 0 1 13 0z',
  doc: 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h5',
  pdf: 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M9 15h6M9 11h2',
  code: 'M8 6l-6 6 6 6M16 6l6 6-6 6M13.5 4l-3 16',
  sign: 'M3 20h18M5 16L15.5 5.5a2.12 2.12 0 0 1 3 3L8 19l-4 1 1-4z',
  image: 'M3 5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5zm0 11l5-5 4 4 3-3 6 6M15.5 8.5h.01',
  repair: 'M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z',
  table: 'M3 5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5zm0 5h18M3 15h18M9 10v10',
  terminal: 'M4 17l6-5-6-5M12 19h8',
  settings: 'M4 7h16M4 17h16M8 4v6M16 14v6',
  refresh: 'M20 7v5h-5M4 17v-5h5M5.3 7.3a8 8 0 0 1 13.4-1.3L20 7M4 17l1.3 1A8 8 0 0 0 18.7 16.7',
  copy: 'M8 8h11a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1zm8 0V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3',
  download: 'M12 3v12m-5-4l5 5 5-5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2',
  upload: 'M12 15V3m-5 5l5-5 5 5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2',
  expand: 'M8 3H3v5M16 3h5v5M21 16v5h-5M8 21H3v-5',
  collapse: 'M3 8h5V3M16 3v5h5M21 16h-5v5M8 21v-5H3',
  close: 'M6 6l12 12M18 6L6 18',
  check: 'M5 12l4.5 4.5L19 7',
  shield: 'M12 3l8 3.5v5.5c0 5-8 9-8 9s-8-4-8-9V6.5L12 3zm-3 9l2 2 4-4',
  lock: 'M5 11h14a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1zm3 0V7a4 4 0 0 1 8 0v4',
  key: 'M14 7a5 5 0 1 0-10 0 5 5 0 0 0 10 0zm-2 4l9 9m-4-4l3-3',
  globe: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM2 12h20M12 2a15 15 0 0 1 0 20M12 2a15 15 0 0 0 0 20',
  swap: 'M7 10l-4-4 4-4M3 6h18M17 14l4 4-4 4M21 18H3',
  folder: 'M3 6a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6z',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7l1-8z',
  plus: 'M12 5v14M5 12h14',
  minus: 'M5 12h14',
  chevron: 'M9 6l6 6-6 6',
  back: 'M15 6l-6 6 6 6',
  panel: 'M3 4h18v16H3zM9 4v16',
  alert: 'M12 9v4m0 4h.01M10.3 3.9L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
};

const icon = (name, cls = '') =>
  `<svg class="icon ${cls}" viewBox="0 0 24 24" aria-hidden="true"><path d="${ICONS[name] || ICONS.doc}"/></svg>`;
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ---------- WO_INFO 字段字典与 5 大业务分组 ---------- */
const FIELD_LABELS = {
  caseNo: '单据号', sysAccept: '受理流水', phoneNo: '手机号码', opMonth: '业务月份',
  opCode: '业务编码', opName: '业务名称', opTime: '受理时间', sts: '状态编码',
  stsDesc: '单据状态', loginNo: '受理工号', loginName: '受理人员', groupId: '营业厅编码',
  groupName: '营业厅名称', areaCode: '区县编码', areaName: '所属区县', regionCode: '地市编码',
  regionName: '所属地市', provinceCode: '省份编码', provinceName: '所属省份', tenantId: '租户标识',
  isSign: '是否签字', isPhoto: '是否拍照', isRead: '是否阅读', signNum: '签字数量',
  photoNum: '图片数量', picSeq: '图片序号', cardNum: '证件图片数', isPreControl: '是否预控',
  isAgainCreate: '是否重新生成', cdFlag: '处理标记', fileName: '归档文件路径',
  ext1: '扩展字段 1 (渠道端)', ext2: '扩展字段 2 (实名批次)', ext3: '扩展字段 3',
  ext4: '扩展字段 4', ext5: '扩展字段 5', ext6: '扩展字段 6',
  ext7: '扩展字段 7 (归档桶目录)', ext8: '扩展字段 8 (加密标识)', ext9: '扩展字段 9', ext10: '扩展字段 10',
};

const FIELD_GROUPS = [
  ['单据与业务核心', ['caseNo', 'sysAccept', 'phoneNo', 'opMonth', 'opCode', 'opName', 'opTime', 'sts', 'stsDesc']],
  ['受理人员与渠道', ['loginNo', 'loginName', 'groupId', 'groupName', 'tenantId']],
  ['归属地市与网格', ['provinceCode', 'provinceName', 'regionCode', 'regionName', 'areaCode', 'areaName']],
  ['电子签署与影像核验', ['isSign', 'isRead', 'isPhoto', 'signNum', 'photoNum', 'cardNum', 'picSeq', 'isPreControl', 'isAgainCreate', 'cdFlag']],
  ['OBS 归档与 EXT1~EXT10', ['fileName', 'ext1', 'ext2', 'ext3', 'ext4', 'ext5', 'ext6', 'ext7', 'ext8', 'ext9', 'ext10']],
];

function createWorkOrders(month = '202610', phone = '13813809527') {
  const specs = [
    {
      suffix: '0186', accept: '0928', code: 'BP003', name: '5G 智享套餐变更及终端合约受理单',
      time: '14:32:08', sts: '1', stsDesc: '已归档', hall: '南京 · 鼓楼中心旗舰营业厅',
      area: '鼓楼区', region: '南京', regionCode: '025', signNum: '2', photoNum: '3',
      again: '0', ext1: 'H5_PAD_PRO', ext2: 'AUTH_FACE_99.4%',
    },
    {
      suffix: '0219', accept: '1042', code: 'BP018', name: '千兆宽带新装及全屋 Wi-Fi 融合受理单',
      time: '11:15:46', sts: '2', stsDesc: '缺签字待修复', hall: '南京 · 新街口正洪大厦营业厅',
      area: '秦淮区', region: '南京', regionCode: '025', signNum: '1', photoNum: '2',
      again: '1', ext1: 'SMART_COUNTER', ext2: 'NEEDS_SIGN_SYNC',
    },
    {
      suffix: '0305', accept: '1189', code: 'BP024', name: '政企集团云专线开户及责任告知书',
      time: '09:48:19', sts: '1', stsDesc: '已归档', hall: '苏州 · 工业园区星海街政企厅',
      area: '工业园区', region: '苏州', regionCode: '0512', signNum: '2', photoNum: '3',
      again: '0', ext1: 'PC_PORTAL_V4', ext2: 'CERT_VERIFIED',
    },
    {
      suffix: '0412', accept: '1360', code: 'BP009', name: '家庭亲情网主副卡成员变更确认单',
      time: '16:05:51', sts: '1', stsDesc: '已归档', hall: '无锡 · 中山路崇安寺营业厅',
      area: '梁溪区', region: '无锡', regionCode: '0510', signNum: '2', photoNum: '2',
      again: '0', ext1: 'APP_MINI_SIGN', ext2: 'PASS',
    },
  ];
  return specs.map((s) => ({
    caseNo: `${month}120925000000${s.suffix}`,
    sysAccept: `JS${month}1200000${s.accept}`,
    phoneNo: phone,
    opMonth: month,
    opCode: s.code,
    opName: s.name,
    opTime: `${month.slice(0, 4)}-${month.slice(4)}-12 ${s.time}`,
    sts: s.sts,
    stsDesc: s.stsDesc,
    loginNo: 'JS025088',
    loginName: '林知夏 (工号025088)',
    groupId: `HALL_${s.regionCode}_${s.suffix}`,
    groupName: s.hall,
    areaCode: `${s.regionCode}01`,
    areaName: s.area,
    regionCode: s.regionCode,
    regionName: s.region,
    provinceCode: '32',
    provinceName: '江苏',
    tenantId: 'JS_CMCC_NPL',
    isSign: '1',
    isPhoto: '1',
    isRead: '1',
    signNum: s.signNum,
    photoNum: s.photoNum,
    picSeq: '1,2,3',
    cardNum: '2',
    isPreControl: '0',
    isAgainCreate: s.again,
    cdFlag: '0',
    fileName: `/receipt${s.regionCode}/${month}/signed/${month}120925000000${s.suffix}.pdf`,
    ext1: s.ext1,
    ext2: s.ext2,
    ext3: null,
    ext4: null,
    ext5: null,
    ext6: null,
    ext7: `${month}/receipt${s.regionCode}`,
    ext8: '0',
    ext9: null,
    ext10: null,
  }));
}

const isEmbedMobile = location.search.includes('embed=mobile');
if (isEmbedMobile) {
  document.body.classList.add('embed-mobile', 'is-mobile');
}

/* ---------- 全局响应式状态 ---------- */
const state = {
  theme: 'neo-cloud',
  density: 'standard',
  radius: 'balanced',
  viewport: isEmbedMobile ? 'mobile' : 'desktop',
  activeScene: 'details',

  // 一级工作台：false = 工单查询，true = 单据图片修复
  editorTab: false,

  // 工单查询工作台状态
  works: createWorkOrders(),
  selectedWorkIndex: 0,
  section: 'details', // 'details' | 'pdf' | 'message' | 'sign' | 'picture'
  orderFilter: '',
  fieldFilter: '',
  fieldMode: 'grouped', // 'grouped' | 'all' | 'nonempty'

  // 查询条件与进度
  query: {
    kind: 'phoneNo',
    value: '13813809527',
    start: '2026-10',
    end: '2026-10',
    range: false,
  },
  queryLabel: '手机号码 · 13813809527 · 2026-10',
  queriedAt: '14:35:12',
  cacheHits: 3,
  history: [
    { kind: 'phoneNo', value: '13813809527', start: '2026-10', end: '2026-10', range: false },
    { kind: 'sysAccept', value: 'JS20261012000000928', start: '2026-10', end: '2026-10', range: false },
    { kind: 'caseNo', value: '2026101209250000000219', start: '2026-10', end: '2026-10', range: false },
  ],

  // PDF 阅读器与三级确认上传修复状态
  pdfPage: 1,
  pdfZoom: 96,
  pdfFit: 'width',
  pdfThumbs: true,
  pdfFullscreen: false,
  uploadStep: 0, // 0:未打开, 1:选择与本地备份, 2:确认单据参数(1/3), 3:确认备份(2/3), 4:最终红色确认(3/3)
  uploadBackupSaved: false,
  uploadBackupChecked: false,
  uploadPickedFile: '2026101209250000000219_修复后单据.pdf',

  // 报文阅读与递归专注栈
  messageFileIndex: 0,
  messageFormat: 'auto',
  messageRaw: false,
  messageKeyFilter: '',
  messageValFilter: '',
  messageCollapsed: new Set(),
  messageFrames: [],

  // 单据图片修复工作台状态 (v1.6 核心)
  repair: {
    oldCaseNo: '2026091209250000000108',
    newCaseNo: '2026101209250000000219',
    oldPages: 3,
    newPages: 2, // 故意设置页数不一致（3页 vs 2页），演示琥珀色补页提示条与一键复制补页！
    mobileSide: 'source', // 手机端切换：'source' | 'target'
    showConnections: true,
    needsSync: true,
    saved: false,
    selectedSourceIds: new Set(['src-p1-sign']),
    sourceObjects: [
      { id: 'src-p1-sign', page: 1, label: '客户手写签字轨 #1', size: '420×160 px', kind: 'sign' },
      { id: 'src-p1-photo', page: 1, label: '现场人证抓拍像 #2', size: '320×400 px', kind: 'photo' },
      { id: 'src-p2-agent', page: 2, label: '经办人确认签字 #3', size: '380×140 px', kind: 'agent' },
      { id: 'src-p3-seal', page: 3, label: '补充协议签章 #4', size: '240×240 px', kind: 'seal' },
    ],
    materials: [
      { id: 'mat-1', sourceObjId: 'src-p1-sign', kind: 'old', thumbKind: 'sign', page: 1, targetPage: 1, label: '旧图 · 1页 (客户签字)', size: '420×160' },
      { id: 'mat-2', sourceObjId: 'src-p1-photo', kind: 'old', thumbKind: 'photo', page: 1, targetPage: 1, label: '旧图 · 1页 (人像抓拍)', size: '320×400' },
      { id: 'mat-3', sourceObjId: 'tgt-staged-1', kind: 'staged', thumbKind: 'staged', page: 2, targetPage: 2, label: '暂存 · 2页 (原受理章)', size: '200×200' },
      { id: 'mat-4', sourceObjId: 'local-import-1', kind: 'local', thumbKind: 'local', page: 2, targetPage: 2, label: '本地 · 2页 (补拍凭证.png)', size: '640×480' },
    ],
  },

  // 五表数据查询与 SM4 解密状态
  tableKind: 'SYS_INTER_RESULT', // 默认打开亮点功能：接口结果表 + SM4 解密
  sm4Key: 'NPL_JS_SM4_KEY16',
  sm4Decrypted: true,
  selectedTableRow: null,

  // 容器日志文件浏览与批量下载状态
  logApp: 'server', // 'server' | 'web'
  logDir: '/usr/local/logs',
  logDownloading: null,
  logBatchPattern: '*.log *error*.txt',
  logBatchDone: false,

  // 多环境与设置状态
  activeEnvIndex: 0,
  environments: [
    { name: '江苏生产环境 (只读)', baseUrl: 'https://npl-js.cmcc.internal:8443/npl-service', webUrl: 'https://npl-web.cmcc.internal:8443/npl-web' },
    { name: '江苏灰度验证环境', baseUrl: 'https://npl-gray.cmcc.internal:8443/npl-service', webUrl: 'https://npl-gray-web.cmcc.internal:8443/npl-web' },
    { name: '南京研发联调环境', baseUrl: 'http://10.25.16.88:18080/npl-service', webUrl: 'http://10.25.16.88:18081/npl-web' },
  ],
  keystoreFile: 'js_cmcc_npl_prod_2026.jks',
  loginNo: 'JS025088',
  channel: 'HALL_PAD',
  bucketOverride: '',
  githubProxy: 'https://ghproxy.net/',

  // 接口调用记录与运行日志
  logs: [
    { time: '14:35:12', method: 'POST', path: '/wo/queryList', duration: '42ms', status: 200, body: { phoneNo: '13813809527', opMonth: '202610' }, respNote: '命中 4 条工单记录 · 已缓存' },
    { time: '14:35:14', method: 'POST', path: '/test/un_look', duration: '118ms', status: 200, body: { bucketName: 'receipt025', objectName: '2026101209250000000186.pdf', ext8: '0' }, respNote: 'PDF 二进制流 (294,912 Bytes · 内存直载)' },
    { time: '14:35:19', method: 'POST', path: '/interResult/queryList', duration: '65ms', status: 200, body: { caseNo: '2026101209250000000186' }, respNote: '返回 3 条接口调用结果 (含 SM4: 密文字段)' },
    { time: '14:35:25', method: 'POST', path: '/log-file/list', duration: '31ms', status: 200, body: { dir: '/usr/local/logs' }, respNote: '返回注册中心 2 个在线 Pod 副本日志目录' },
  ],

  modal: null,
};

function currentWork() {
  return state.works[state.selectedWorkIndex ?? 0] || state.works[0];
}

let toastTimeout;
function showToast(msg) {
  const el = document.getElementById('toast');
  if (!el) return;
  el.textContent = msg;
  el.classList.add('visible');
  clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => el.classList.remove('visible'), 2500);
}

function copyText(text, label = '内容') {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(String(text)).then(() => showToast(`已复制${label}到剪贴板`)).catch(() => showToast(`已复制：${String(text).slice(0, 24)}`));
  } else {
    showToast(`已复制${label}：${String(text).slice(0, 24)}`);
  }
}

function triggerDownload(filename, content, mime = 'application/json;charset=utf-8') {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1500);
  showToast(`已生成并开始下载：${filename}`);
}

/* ---------- 矢量签名与证件缩略图生成 ---------- */
const SIGN_SVG_CUSTOMER = `<svg class="sign-stroke" viewBox="0 0 380 130" aria-label="客户手写签名"><path d="M35 65c8-28 24-35 28-10 4 22-8 50-12 58m-24-32l62-14M105 42l-14 68m6-46c26-18 46-22 42-4-4 18-24 38-12 44 12 6 34-12 48-28M198 36l-12 72m-8-44l54-16m-26-12c18 28 32 52 18 58-12 5-28-6-36-16M276 52c14-20 32-24 28-4-4 18-26 42-8 46 16 4 38-18 52-34"/></svg>`;
const SIGN_SVG_AGENT = `<svg class="sign-stroke" viewBox="0 0 380 130" aria-label="受理员手写签名"><path d="M48 45l-12 64m-18-38l48-10m8-18l-10 62m10-36c18-14 34-14 30 6-4 18-18 34-4 36 14 2 32-16 42-28M188 40v66m-22-42h46m14-14l-14 58m14-38c24-12 44-8 38 14-6 20-26 28-10 32 16 4 38-10 54-24"/></svg>`;

function renderMiniObjectThumb(kind) {
  if (kind === 'sign' || kind === 'old') {
    return `<svg viewBox="0 0 220 70" style="width:100%;height:48px;stroke:#1d4ed8;fill:none;stroke-width:2.5;stroke-linecap:round"><path d="M20 40c10-22 25-20 22 4-3 18-12 20 8 10 20-10 38-28 45-8s-10 26 12 18c22-8 42-28 52-12s-8 24 18 14 28-18 35-22"/></svg>`;
  }
  if (kind === 'photo') {
    return `<svg viewBox="0 0 120 70" style="width:100%;height:48px"><rect x="18" y="4" width="84" height="62" rx="6" fill="#eff6ff" stroke="#60a5fa"/><circle cx="60" cy="26" r="11" fill="#93c5fd"/><path d="M38 58c4-14 40-14 44 0" fill="#60a5fa"/></svg>`;
  }
  if (kind === 'staged' || kind === 'seal') {
    return `<svg viewBox="0 0 120 70" style="width:100%;height:48px"><circle cx="60" cy="35" r="24" fill="none" stroke="#7c3aed" stroke-width="2" stroke-dasharray="3 2"/><text x="60" y="39" text-anchor="middle" font-size="10" fill="#7c3aed" font-weight="700">专用章图层</text></svg>`;
  }
  return `<svg viewBox="0 0 120 70" style="width:100%;height:48px"><rect x="14" y="6" width="92" height="58" rx="5" fill="#fef3c7" stroke="#d97706"/><text x="60" y="39" text-anchor="middle" font-size="10" fill="#b45309" font-weight="600">本地补拍图</text></svg>`;
}

/* ==========================================================================
   主界面渲染入口
   ========================================================================== */
function renderApp() {
  const isMobileSurface = state.viewport === 'mobile' || isEmbedMobile;
  document.body.classList.toggle('is-mobile', isMobileSurface);
  document.documentElement.setAttribute('data-theme', state.theme);
  document.documentElement.setAttribute('data-density', state.density);
  document.documentElement.setAttribute('data-radius', state.radius);
  if (!isEmbedMobile) {
    document.body.setAttribute('data-viewport', state.viewport);
  }

  const app = document.getElementById('app');
  if (!app) return;

  app.innerHTML = `
    <div class="app-shell">
      ${renderTopbar()}
      ${renderMobileTop()}
      ${state.editorTab ? renderRepairWorkbench() : renderQueryWorkbench()}
      ${!state.editorTab && state.selectedWorkIndex !== null ? renderMobileBottomNav() : ''}
    </div>
  `;

  if (state.editorTab) {
    requestAnimationFrame(drawRepairConnections);
  } else if (state.section === 'pdf') {
    bindPdfEvents();
  }
}

/* ---------- 桌面端顶栏与手机端顶栏 ---------- */
function renderTopbar() {
  const env = state.environments[state.activeEnvIndex] || state.environments[0];
  const dirty = state.repair.needsSync || !state.repair.saved;
  return `
    <header class="app-topbar">
      <div class="brand-cluster">
        <img src="app-icon.png" alt="应用图标">
        <div class="brand-title">
          <strong>无纸化维护中心 <span class="badge blue" style="font-size:9.5px;padding:1px 6px">v1.6.2</span></strong>
          <small>NPL CONSOLE · 原生工单核对与影像修复</small>
        </div>
      </div>

      <!-- 一级双工作台切换 -->
      <nav class="mode-switcher" aria-label="主工作台切换">
        <button class="mode-tab ${!state.editorTab ? 'active' : ''}" data-action="switch-mode" data-id="query">
          ${icon('search')} 工单查询
        </button>
        <button class="mode-tab ${state.editorTab ? 'active' : ''}" data-action="switch-mode" data-id="repair">
          ${icon('repair')} 单据图片修复
          ${dirty ? '<i class="dirty-dot" title="共享区有未保存的修复操作"></i>' : ''}
        </button>
      </nav>

      ${!state.editorTab ? `
        <button class="search-trigger" data-action="open-search" title="点击打开工单查询面板 (快捷键 ⌘K)">
          ${icon('search')}
          <strong>${esc(state.queryLabel)}</strong>
          <kbd>⌘K</kbd>
        </button>
        <div class="inline-status" title="内存响应缓存 5 分钟 · 最多 128 条 / 64 MiB">
          <i class="status-dot"></i>
          <span>只读 · 缓存命中 ${state.cacheHits} 次</span>
        </div>
      ` : `
        <div class="inline-status" style="margin-left:8px">
          <span class="badge purple">${icon('bolt')} 实时流光连线已启用</span>
          <span class="muted">编辑仅在本地合成 PDF，不会自动覆盖 OBS</span>
        </div>
      `}

      <div class="top-utility">
        <button class="util-btn" data-action="open-table-query" title="五张物理表直查与接口结果 SM4 解密">
          ${icon('table')} 数据查询
        </button>
        <button class="util-btn" data-action="open-pod-logs" title="浏览全部 Pod 副本 /usr/local/logs 与分片批量下载">
          ${icon('terminal')} 日志文件
        </button>
        <button class="util-btn" data-action="open-logs" title="查看接口请求记录与程序运行日志 runtime-*.jsonl">
          ${icon('code')} 接口记录 <span class="count-pill">${state.logs.length}</span>
        </button>
        <button class="util-btn" data-action="open-portal" title="私钥解密内置安全门户链接">
          ${icon('globe')} 门户
        </button>
        <button class="env-pill" data-action="cycle-env" title="点击快速切换运行环境（切换会清空当前结果与缓存）">
          <i></i>
          <span>${esc(env.name)}</span>
          ${icon('swap')}
        </button>
        <button class="btn sm" data-action="open-settings">
          ${icon('settings')} 设置
        </button>
      </div>
    </header>
  `;
}

function renderMobileTop() {
  const w = currentWork();
  const inDetail = !state.editorTab && state.selectedWorkIndex !== null;
  const secLabels = { details: '单据信息', pdf: '单据 PDF', message: '报文信息', sign: '签字信息', picture: '图片信息' };
  return `
    <header class="mobile-top">
      <div class="ios-statusbar">
        <span>9:41</span>
        <div class="dynamic-island"></div>
        <span class="mono" style="font-size:10px">5G · 100%</span>
      </div>
      <div class="mobile-bar-row">
        ${state.editorTab ? `
          <button class="btn quiet sm" data-action="switch-mode" data-id="query">${icon('back')} 返回查询</button>
          <strong style="font-size:15px">单据图片修复</strong>
          <button class="icon-btn" data-action="open-settings" title="设置">${icon('settings')}</button>
        ` : inDetail ? `
          <button class="btn quiet sm" data-action="mobile-back-list">${icon('back')} 工单列表</button>
          <strong style="font-size:15px">${secLabels[state.section] || '工单详情'}</strong>
          <div class="row" style="gap:2px">
            <button class="icon-btn" data-action="switch-mode" data-id="repair" title="单据图片修复">${icon('repair')}</button>
            <button class="icon-btn" data-action="open-mobile-more" title="更多操作">${icon('more')}</button>
          </div>
        ` : `
          <div class="row">
            <img src="app-icon.png" alt="" style="width:26px;height:26px;border-radius:7px">
            <strong style="font-size:16px">无纸化维护中心</strong>
          </div>
          <div class="row" style="gap:4px">
            <button class="btn soft sm" data-action="switch-mode" data-id="repair">${icon('repair')} 图片修复</button>
            <button class="icon-btn" data-action="open-mobile-more" title="更多">${icon('more')}</button>
          </div>
        `}
      </div>
      ${!state.editorTab && !inDetail ? `
        <button class="search-trigger" style="max-width:none;width:100%;margin-top:6px" data-action="open-search">
          ${icon('search')}
          <strong>${esc(state.queryLabel)}</strong>
          <span class="badge blue" style="margin-left:auto">修改条件</span>
        </button>
      ` : ''}
    </header>
  `;
}

function renderMobileBottomNav() {
  const tabs = [
    ['details', 'doc', '详情'],
    ['pdf', 'pdf', 'PDF'],
    ['message', 'code', '报文'],
    ['sign', 'sign', '签字'],
    ['picture', 'image', '图片'],
  ];
  return `
    <nav class="mobile-nav" aria-label="手机端资料分类导航">
      ${tabs.map(([k, ic, label]) => `
        <button class="m-nav-btn ${state.section === k ? 'active' : ''}" data-action="select-section" data-id="${k}">
          ${icon(ic)}
          <span>${label}</span>
        </button>
      `).join('')}
    </nav>
  `;
}

/* ==========================================================================
   工作台一：工单查询与 5 大资料分类视图
   ========================================================================== */
function renderQueryWorkbench() {
  const isMobileSurface = state.viewport === 'mobile' || isEmbedMobile;
  if (isMobileSurface) {
    return `
      <main class="query-workbench">
        ${state.selectedWorkIndex === null ? renderResultsSidebar() : renderMainWorkspace()}
      </main>
    `;
  }
  return `
    <main class="query-workbench">
      ${renderResultsSidebar()}
      ${renderMainWorkspace()}
    </main>
  `;
}

function renderResultsSidebar() {
  const kw = state.orderFilter.trim().toLowerCase();
  const filtered = state.works
    .map((w, idx) => ({ w, idx }))
    .filter(({ w }) => !kw || JSON.stringify(w).toLowerCase().includes(kw));

  return `
    <aside class="results-panel" aria-label="工单查询结果">
      <div class="results-head">
        <h3>查询结果 <span class="badge blue">${state.works.length} 份</span></h3>
        <div class="row" style="gap:2px">
          <button class="icon-btn" data-action="open-search" title="修改查询条件">${icon('search')}</button>
          <button class="icon-btn" data-action="refresh-query" title="重新请求后台并刷新列表">${icon('refresh')}</button>
        </div>
      </div>
      <div class="results-filter">
        ${icon('search')}
        <input id="order-filter-input" placeholder="在结果中筛选单据号/厅台/业务…" value="${esc(state.orderFilter)}" aria-label="筛选工单结果">
      </div>
      <div class="orders-list">
        ${filtered.length ? filtered.map(({ w, idx }) => {
          const isWarn = w.sts === '2';
          return `
            <button class="order-card ${state.selectedWorkIndex === idx ? 'selected' : ''}" data-action="select-work" data-id="${idx}">
              <h4>
                <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(w.opName)}</span>
              </h4>
              <span class="case-id mono">${esc(w.caseNo)}</span>
              <span class="sub-meta">${esc(w.regionName)} · ${esc(w.groupName.split(' · ')[1] || w.groupName)}</span>
              <footer>
                <span class="mono">${esc(w.opTime.slice(5, 16))}</span>
                <span class="badge ${isWarn ? 'amber' : 'green'}"><i></i>${esc(w.stsDesc)}</span>
              </footer>
            </button>
          `;
        }).join('') : `
          <div class="empty-state" style="padding:24px 12px">
            <p>没有匹配「${esc(state.orderFilter)}」的工单</p>
          </div>
        `}
      </div>
      <div class="results-foot">
        <span>更新于 ${state.queriedAt}</span>
        <button class="btn quiet sm" data-action="clear-cache" style="padding:2px 6px">清空缓存</button>
      </div>
    </aside>
  `;
}

function renderMainWorkspace() {
  if (state.selectedWorkIndex === null || !state.works.length) {
    return `
      <section class="main-workspace">
        <div class="empty-state">
          <div class="empty-icon-ring">${icon('doc')}</div>
          <h3 style="color:var(--ink);margin:0 0 6px">选择一份工单，展开完整关联资料</h3>
          <p style="max-width:320px;line-height:1.7;margin:0 0 16px">从左侧查询结果中选择工单，即可并排核对 WO_INFO 全量字段、原始 PDF、CRM/H5 报文、手写签字与证件照片。</p>
          <button class="btn primary" data-action="open-search">${icon('search')} 查询工单</button>
        </div>
      </section>
    `;
  }

  const w = currentWork();
  const isWarn = w.sts === '2';
  const secTabs = [
    ['details', 'doc', '单据信息', `${Object.keys(w).length}`],
    ['pdf', 'pdf', '单据 PDF', '3页'],
    ['message', 'code', '报文信息', '4'],
    ['sign', 'sign', '签字信息', w.signNum],
    ['picture', 'image', '图片信息', w.photoNum],
  ];

  return `
    <section class="main-workspace">
      <header class="work-header">
        <div class="work-title-row">
          <div class="row" style="min-width:0;flex-wrap:wrap">
            <h1>${esc(w.opName)}</h1>
            <span class="badge ${isWarn ? 'amber' : 'green'}"><i></i>${esc(w.stsDesc)}</span>
          </div>
          <div class="row" style="flex-wrap:wrap">
            <button class="btn soft sm" data-action="send-to-repair" title="将此工单单据号带入「单据图片修复」工作台">
              ${icon('repair')} 送入图片修复
            </button>
            <button class="btn sm" data-action="copy-caseno">
              ${icon('copy')} 复制单据号
            </button>
            <button class="btn sm" data-action="export-work-json">
              ${icon('download')} 导出 JSON
            </button>
          </div>
        </div>
        <div class="work-meta-pills" style="margin-top:7px">
          <span>单据号：<strong class="mono">${esc(w.caseNo)}</strong></span>
          <span class="divider"></span>
          <span>受理流水：<strong class="mono">${esc(w.sysAccept)}</strong></span>
          <span class="divider"></span>
          <span>${esc(w.groupName)}</span>
          <span class="divider"></span>
          <span class="mono">${esc(w.opTime)}</span>
        </div>
        <nav class="section-tabs" aria-label="工单关联资料分类">
          ${secTabs.map(([key, ic, label, badgeCount]) => `
            <button class="sec-tab ${state.section === key ? 'active' : ''}" data-action="select-section" data-id="${key}">
              ${icon(ic)}
              <span>${label}</span>
              <em>${badgeCount}</em>
            </button>
          `).join('')}
          <span class="muted" style="margin-left:auto;font-size:11px;display:inline-flex;align-items:center;gap:4px">
            ${icon('shield')} 遵循 WO_INFO202610 建表规范 · EXT1~10 完整保留
          </span>
        </nav>
      </header>
      <div class="workspace-body">
        ${renderSectionBody()}
      </div>
    </section>
  `;
}

function renderSectionBody() {
  if (state.section === 'details') return renderDetailsSection();
  if (state.section === 'pdf') return renderPdfSection();
  if (state.section === 'message') return renderMessageSection();
  if (state.section === 'sign') return renderGallerySection('sign');
  return renderGallerySection('picture');
}

/* ---------- 1. 单据信息 (WO_INFO Details) ---------- */
function highlightMatch(val, query) {
  const str = String(val ?? '');
  if (!query) return esc(str);
  const idx = str.toLowerCase().indexOf(query.toLowerCase());
  if (idx < 0) return esc(str);
  return (
    esc(str.slice(0, idx)) +
    `<mark>${esc(str.slice(idx, idx + query.length))}</mark>` +
    esc(str.slice(idx + query.length))
  );
}

function renderDetailsSection() {
  const w = currentWork();
  const q = state.fieldFilter.trim().toLowerCase();
  const groups =
    state.fieldMode === 'grouped'
      ? FIELD_GROUPS
      : [['WO_INFO 建表全量字段', Object.keys(w)]];

  return `
    <div class="details-container">
      <div class="details-toolbar">
        <div class="row" style="flex-wrap:wrap">
          <div class="segmented" role="group" aria-label="字段展示分组模式">
            <button class="${state.fieldMode === 'grouped' ? 'active' : ''}" data-action="set-field-mode" data-id="grouped">业务分组 (5)</button>
            <button class="${state.fieldMode === 'all' ? 'active' : ''}" data-action="set-field-mode" data-id="all">全部字段</button>
            <button class="${state.fieldMode === 'nonempty' ? 'active' : ''}" data-action="set-field-mode" data-id="nonempty">隐藏空 EXT</button>
          </div>
          <span class="badge green">${icon('check')} 0 与 false 均作为有效值保留</span>
        </div>
        <div class="field-search-box">
          ${icon('search')}
          <input id="field-filter-input" placeholder="搜索字段中文名、英文名或值…" value="${esc(state.fieldFilter)}" aria-label="搜索单据字段">
        </div>
      </div>

      <div class="details-scroll" id="details-scroll-area">
        ${!q ? `
          <div class="kpi-strip">
            <div class="kpi-card">
              <small>业务月份 (opMonth)</small>
              <strong class="mono">${esc(w.opMonth.slice(0, 4))}-${esc(w.opMonth.slice(4))}</strong>
            </div>
            <div class="kpi-card">
              <small>电子签署与实名状态</small>
              <strong style="color:var(--green)">${icon('check')} 已签字(${w.signNum}) · 已拍照(${w.photoNum})</strong>
            </div>
            <div class="kpi-card">
              <small>受理员工号与渠道</small>
              <strong>${esc(w.loginNo)} · <span class="mono" style="font-size:11px">${esc(w.ext1)}</span></strong>
            </div>
            <div class="kpi-card">
              <small>OBS 归档索引 (ext7 / ext8)</small>
              <strong class="mono" style="font-size:11.5px">${esc(w.ext7)} (ext8=${esc(w.ext8)})</strong>
            </div>
          </div>
        ` : ''}

        ${groups.map(([title, keys]) => {
          const validKeys = keys.filter((k) => {
            if (!(k in w)) return false;
            if (state.fieldMode === 'nonempty' && w[k] === null) return false;
            if (!q) return true;
            const hay = `${FIELD_LABELS[k] || k} ${k} ${w[k] ?? '未返回值'}`.toLowerCase();
            return hay.includes(q);
          });
          if (!validKeys.length) return '';
          return `
            <details class="field-group" open>
              <summary>
                <i class="group-accent"></i>
                <span>${esc(title)}</span>
                <small>${validKeys.length} 个字段</small>
              </summary>
              <div class="field-grid">
                ${validKeys.map((k) => {
                  const val = w[k];
                  const isWide = ['caseNo', 'sysAccept', 'groupName', 'fileName'].includes(k);
                  const isMono = ['caseNo', 'sysAccept', 'phoneNo', 'opMonth', 'opTime', 'fileName', 'ext7'].includes(k);
                  return `
                    <div class="field-cell ${isWide ? 'wide' : ''}">
                      <label>
                        <span>${highlightMatch(FIELD_LABELS[k] || k, q)}</span>
                        <code>${highlightMatch(k, q)}</code>
                      </label>
                      <div class="val ${val === null ? 'empty' : ''} ${isMono ? 'mono' : ''}">
                        ${val === null ? '— 未返回值 (EXT保留)' : highlightMatch(val, q)}
                      </div>
                      <button class="icon-btn copy-btn" data-action="copy-field" data-id="${k}" title="复制 ${esc(FIELD_LABELS[k] || k)}">
                        ${icon('copy')}
                      </button>
                    </div>
                  `;
                }).join('')}
              </div>
            </details>
          `;
        }).join('')}
      </div>

      <footer class="details-footer">
        <span>按 WO_INFO202610 建表字段展示 · 共 ${Object.keys(w).length} 项（已排除额外 Bean 属性）</span>
        <button class="btn quiet sm" data-action="export-work-json">${icon('download')} 导出同规则 JSON ↗</button>
      </footer>
    </div>
  `;
}

/* ---------- 2. 单据 PDF 阅读器与三级确认上传修复 ---------- */
function renderA4Paper(pageNum) {
  const w = currentWork();
  return `
    <article class="a4-paper" id="pdf-page-${pageNum}" data-page="${pageNum}">
      <header class="a4-head">
        <strong>中国移动通信集团江苏有限公司 · 电子业务受理单</strong>
        <span class="mono">地市：${esc(w.regionName)} (${esc(w.regionCode)}) · 第 ${pageNum} / 3 页</span>
      </header>
      <div class="a4-watermark">江苏移动无纸化电子凭证</div>
      <h2>${pageNum === 1 ? esc(w.opName) : pageNum === 2 ? '业务办理服务协议与资费告知书' : '客户实名认证与电子签署确认页'}</h2>
      <div class="a4-serial">单据编号 (caseNo)：${esc(w.caseNo)} 　|　 CRM 受理流水：${esc(w.sysAccept)}</div>

      ${pageNum === 1 ? `
        <table class="a4-table">
          <tr><td class="k">客户手机号码</td><td class="mono">${esc(w.phoneNo)}</td><td class="k">业务受理月份</td><td class="mono">${esc(w.opMonth)}</td></tr>
          <tr><td class="k">受理业务名称</td><td colspan="3">${esc(w.opName)}（业务编码：${esc(w.opCode)}）</td></tr>
          <tr><td class="k">受理营业厅台</td><td>${esc(w.groupName)}</td><td class="k">受理工号/姓名</td><td>${esc(w.loginName)}</td></tr>
          <tr><td class="k">实名核验批次</td><td class="mono">${esc(w.ext2 || 'FACE_PASS')}</td><td class="k">受理时间</td><td class="mono">${esc(w.opTime)}</td></tr>
        </table>
        <h3>一、本次业务受理变更明细</h3>
        <p>1. 客户申请办理上述通信业务，相关套餐月费、包含流量与语音权益、合约期约束及违约金条款已由营业厅台受理人员现场告知并经客户本人阅读确认。</p>
        <p>2. 本电子单据经无纸化系统（NPL）实时合成并加盖电子业务受理专用章，归档存储于对象存储桶 <span class="mono">receipt${esc(w.regionCode)}</span>，与纸质凭证具有同等业务核验效力。</p>
        <h3>二、客户签署确认</h3>
        <p>本人已阅读并完全知悉本受理单全部内容，确认上述业务受理信息真实、准确。</p>
        <div class="a4-sign-box">
          <div>
            <div style="font-size:0.85em;color:#64748b">客户本人电子签字（手写压感笔迹合成）：</div>
            <span class="hand-sign">林知夏 · 演示签署</span>
          </div>
          <div style="text-align:right;font-size:0.82em;color:#64748b">
            <div>签署日期：${esc(w.opTime.slice(0, 10))}</div>
            <div class="mono">终端渠道：${esc(w.ext1)}</div>
          </div>
        </div>
      ` : pageNum === 2 ? `
        <h3>一、资费生效与账单结转规则</h3>
        <p>1. 套餐变更自次月 1 日零时起正式生效；千兆宽带及融合终端装维服务自预约工程师上门竣工归档之时起算。</p>
        <p>2. 在网合约期内如需提前办理解约、过户或携号转网，需按协议约定结清已享终端补贴或融合优惠差额。</p>
        <h3>二、个人信息保护与电子档案留存说明</h3>
        <p>1. 为保障通信服务安全并履行实名制登记义务，本次办理采集的电子签名笔迹、现场人像比对照片及身份证件影像均采用加密传输并关联单据号归档。</p>
        <p>2. 维护人员通过「无纸化维护中心」查阅本单据时，所有查询行为均通过 RS256 JWT 鉴权并记录本地审计流水。</p>
        <table class="a4-table" style="margin-top:8%">
          <tr><td class="k">关联报文文件</td><td class="mono">${esc(w.caseNo)}_${esc(w.opCode)}.txt</td><td class="k">归档加密标识</td><td class="mono">ext8 = ${esc(w.ext8)}</td></tr>
          <tr><td class="k">电子签字文件</td><td class="mono">signature_01.svg / signature_02.svg</td><td class="k">影像附件序号</td><td class="mono">picSeq = ${esc(w.picSeq)}</td></tr>
        </table>
      ` : `
        <h3>三、电子签字与人像合成核验页</h3>
        <p>本页用于集中核对客户电子签字轨迹、经办人签字及受理专用章。若遇到签字漏合或图片错位，可通过顶部「单据图片修复」工作台从旧单据提取图层后重新合成导出。</p>
        <table class="a4-table">
          <tr><td class="k">核验单据号</td><td class="mono">${esc(w.caseNo)}</td><td class="k">当前单据状态</td><td>${esc(w.stsDesc)}</td></tr>
          <tr><td class="k">归档路径</td><td colspan="3" class="mono">${esc(w.fileName)}</td></tr>
        </table>
        <div class="a4-sign-box" style="margin-top:12%">
          <span>客户确认签字：<span class="hand-sign">林知夏</span></span>
          <span>受理员复核：<span class="hand-sign" style="font-size:1.6em;color:#2b5b8c">工号025088</span></span>
        </div>
      `}

      ${pageNum !== 2 ? `<div class="red-seal"><span>中国移动江苏<b>受理专用章</b>(${esc(w.regionName)})</span></div>` : ''}
      <footer class="a4-foot">
        <span>NPL Console 原生 PDFium 内存直载渲染 · 演示凭证</span>
        <span class="mono">Page ${pageNum} of 3</span>
      </footer>
    </article>
  `;
}

function renderPdfSection() {
  const w = currentWork();
  return `
    <div class="pdf-container ${state.pdfFullscreen ? 'fullscreen' : ''}">
      <header class="pdf-toolbar">
        <span class="pdf-badge">PDF</span>
        <div class="grow" style="min-width:0">
          <strong class="mono" style="font-size:12px;display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(w.caseNo)}.pdf</strong>
          <small class="muted" style="font-size:10px">3 页 · 288.0 KB · 内存直载 (Direct Memory Load)</small>
        </div>

        <button class="icon-btn" data-action="toggle-pdf-thumbs" title="显示/隐藏缩略图导航">${icon('panel')}</button>
        <span class="divider"></span>
        <span class="mono" style="font-size:11.5px;color:var(--ink-secondary)"><b id="pdf-curr-page">${state.pdfPage}</b> / 3</span>
        <button class="icon-btn" data-action="pdf-zoom-out" title="缩小">${icon('minus')}</button>
        <span class="mono" id="pdf-zoom-label" style="font-size:11.5px;min-width:38px;text-align:center">${state.pdfZoom}%</span>
        <button class="icon-btn" data-action="pdf-zoom-in" title="放大">${icon('plus')}</button>

        <select class="ctl-select" id="pdf-fit-select" style="padding:4px 8px;font-size:11.5px" aria-label="PDF 适应方式">
          <option value="page" ${state.pdfFit === 'page' ? 'selected' : ''}>适应整页</option>
          <option value="width" ${state.pdfFit === 'width' ? 'selected' : ''}>适应宽度</option>
          <option value="actual" ${state.pdfFit === 'actual' ? 'selected' : ''}>实际大小</option>
        </select>

        <span class="divider"></span>
        <!-- 危险写操作：上传修复（仅单据 PDF 页提供） -->
        <button class="btn danger-outline sm" data-action="open-upload-repair" title="危险写操作：经过本地备份与三级确认后覆盖上传修复后的 PDF 到 OBS">
          ${icon('upload')} 上传修复
        </button>
        <button class="btn sm" data-action="download-pdf" title="保存原始 PDF 到本机">
          ${icon('download')} 下载
        </button>
        <button class="icon-btn" data-action="toggle-pdf-full" title="${state.pdfFullscreen ? '退出应用内全屏 (Esc)' : '应用内全屏阅读'}">
          ${icon(state.pdfFullscreen ? 'collapse' : 'expand')}
        </button>
      </header>

      <div class="pdf-body">
        ${state.pdfThumbs ? `
          <aside class="pdf-thumbs" aria-label="PDF 页面缩略图">
            ${[1, 2, 3].map((n) => `
              <button class="thumb-btn ${state.pdfPage === n ? 'active' : ''}" data-action="jump-pdf-page" data-id="${n}">
                <div class="thumb-paper">
                  <i class="head"></i><i></i><i></i>
                  <div class="box"></div>
                  <i></i><i></i>
                </div>
                <span>P${n}</span>
              </button>
            `).join('')}
          </aside>
        ` : ''}
        <div class="pdf-viewport" id="pdf-viewport">
          ${[1, 2, 3].map(renderA4Paper).join('')}
        </div>
      </div>

      <footer class="pdf-statusbar">
        <span>${icon('check')} 已启用 v1.6.2 内存直载策略（绕过 >1MB 异步流回调，避免多页等待）</span>
        <span>滚轮连续阅读 · 支持三级确认「上传修复」覆盖 OBS</span>
      </footer>
    </div>
  `;
}

function bindPdfEvents() {
  const vp = document.getElementById('pdf-viewport');
  if (!vp) return;
  applyPdfZoom();
  vp.addEventListener('scroll', () => {
    const top = vp.getBoundingClientRect().top;
    let current = 1;
    vp.querySelectorAll('.a4-paper').forEach((p) => {
      if (p.getBoundingClientRect().top - top < vp.clientHeight * 0.45) {
        current = +p.dataset.page;
      }
    });
    if (current !== state.pdfPage) {
      state.pdfPage = current;
      const lbl = document.getElementById('pdf-curr-page');
      if (lbl) lbl.textContent = current;
      document.querySelectorAll('.thumb-btn').forEach((b) => {
        b.classList.toggle('active', +b.dataset.id === current);
      });
    }
  }, { passive: true });
}

function applyPdfZoom() {
  const vp = document.getElementById('pdf-viewport');
  if (!vp) return;
  const base = 680;
  let z = state.pdfZoom;
  if (state.pdfFit === 'page') {
    const availH = vp.clientHeight - 54;
    const availW = vp.clientWidth - 56;
    z = Math.max(50, Math.min(160, Math.floor(Math.min(availW / base, (availH * 210) / (297 * base)) * 100)));
  } else if (state.pdfFit === 'width') {
    const availW = vp.clientWidth - 80;
    z = Math.max(65, Math.min(105, Math.floor((availW / base) * 100)));
  }
  document.querySelectorAll('.a4-paper').forEach((p) => {
    p.style.maxWidth = `${(base * z) / 100}px`;
    p.style.setProperty('--pz', z / 100);
  });
  const zLbl = document.getElementById('pdf-zoom-label');
  if (zLbl) zLbl.textContent = `${z}%`;
}

/* ---------- 3. 报文信息 (JSON / XML / 全量报文递归解析专注) ---------- */
function getMessageSamples() {
  const w = currentWork();
  return [
    {
      name: `${w.caseNo}_${w.opCode}.txt (原始受理报文 · JSON)`,
      raw: JSON.stringify({
        caseNo: w.caseNo,
        sysAccept: w.sysAccept,
        opCode: w.opCode,
        opTime: w.opTime,
        channelInfo: { loginNo: w.loginNo, groupId: w.groupId, terminalType: w.ext1 },
        customer: { phoneNo: w.phoneNo, regionCode: w.regionCode, realNameVerify: 'PASS' },
        crmResponse: `<crmRoot><retCode>0000</retCode><retMsg>受理成功</retMsg><innerPayload><![CDATA[{"receiptNo":"${w.caseNo}","obsBucket":"receipt${w.regionCode}","signCount":2,"auditPassed":true}]]></innerPayload></crmRoot>`,
      }, null, 2),
    },
    {
      name: `${w.caseNo}_${w.opCode}_oprInfo.txt (营业受理 XML + CDATA)`,
      raw: `<acceptanceOrder caseNo="${w.caseNo}" opMonth="${w.opMonth}"><operator loginNo="${w.loginNo}" hall="${w.groupName}"/><business code="${w.opCode}" name="${w.opName}"/><acceptContent><![CDATA[{"packageId":"5G_199_PRO","effectiveDate":"2026-11-01","contractMonths":24,"remark":"客户现场确认签署，含双层嵌套JSON字符串"}]]></acceptContent></acceptanceOrder>`,
    },
    {
      name: `${w.caseNo}_${w.opCode}_h5.txt (H5 电子签章回调报文)`,
      raw: JSON.stringify({
        caseNo: w.caseNo,
        signChannel: 'PAD_H5_CANVAS',
        strokesCount: 284,
        signatures: [
          { seq: 1, role: 'CUSTOMER', objectName: `${w.caseNo}_sign_1.svg`, ext8: '0' },
          { seq: 2, role: 'OPERATOR', objectName: `${w.caseNo}_sign_2.svg`, ext8: '0' },
        ],
        nestedArchiveMeta: '{"bucket":"receipt025","checksum":"sha256:9f86d081884c7d659a2feaa0c55ad015"}',
      }, null, 2),
    },
    {
      name: `全量报文 (/agapi/biz/downloadBiz · 多重转义自动解码)`,
      raw: JSON.stringify({
        code: '200',
        caseNo: w.caseNo,
        downloadBizSource: '/agapi/biz/downloadBiz',
        data: JSON.stringify({
          fullOrderSnapshot: {
            caseNo: w.caseNo,
            sysAccept: w.sysAccept,
            phoneNo: w.phoneNo,
            escapedRowNote: '兼容未转义双引号与多重反斜线转义自动逐层解码 (v1.3.9)',
            deepJsonPayload: '{"step":"FINAL_ARCHIVE","obsSynced":true,"pdfPages":3}',
          },
        }),
      }, null, 2),
    },
  ];
}

function xmlElementToObj(el) {
  const children = [...el.children];
  if (!children.length && !el.attributes.length) return el.textContent;
  const out = {};
  for (const attr of el.attributes) out[`@${attr.name}`] = attr.value;
  for (const child of children) {
    const v = xmlElementToObj(child);
    if (child.tagName in out) {
      if (!Array.isArray(out[child.tagName])) out[child.tagName] = [out[child.tagName]];
      out[child.tagName].push(v);
    } else {
      out[child.tagName] = v;
    }
  }
  if (!children.length && el.textContent.trim()) out['#cdata_or_text'] = el.textContent.trim();
  return out;
}

function parseStructuredMessage(raw, mode = 'auto') {
  if (typeof raw !== 'string') {
    return { format: 'JSON', value: raw, source: JSON.stringify(raw, null, 2) };
  }
  if (mode === 'text') return { format: '纯文本', value: raw, source: raw };
  const trimmed = raw.trim();
  if (mode !== 'xml') {
    try {
      const parsed = JSON.parse(trimmed);
      if (typeof parsed === 'string' && mode === 'auto' && /^[\[{<]/.test(parsed.trim())) {
        return parseStructuredMessage(parsed, 'auto');
      }
      return { format: 'JSON', value: parsed, source: JSON.stringify(parsed, null, 2) };
    } catch (_) {}
  }
  if (mode !== 'json' && trimmed.startsWith('<')) {
    const doc = new DOMParser().parseFromString(trimmed, 'application/xml');
    if (!doc.querySelector('parsererror')) {
      return {
        format: 'XML',
        value: { [doc.documentElement.tagName]: xmlElementToObj(doc.documentElement) },
        source: raw,
      };
    }
  }
  return { format: '纯文本', value: raw, source: raw };
}

let currentVisibleTreeNodes = [];

function renderMessageSection() {
  const samples = getMessageSamples();
  if (!state.messageFrames.length) {
    state.messageFrames = [{ label: '根节点 ($)', value: samples[state.messageFileIndex].raw }];
  }
  const activeFrame = state.messageFrames[state.messageFrames.length - 1];
  const parsed = parseStructuredMessage(activeFrame.value, state.messageFormat);

  currentVisibleTreeNodes = [];
  const qk = state.messageKeyFilter.trim().toLowerCase();
  const qv = state.messageValFilter.trim().toLowerCase();
  const rows = [];

  function walk(key, val, path, depth) {
    const isObj = val !== null && typeof val === 'object';
    const strVal = isObj ? `${Array.isArray(val) ? 'Array' : 'Object'} (${Object.keys(val).length} 项)` : String(val);
    const canFocusNested = !isObj && /^[\[{<]/.test(strVal.trim());
    const matchKey = !qk || key.toLowerCase().includes(qk);
    const matchVal = !qv || strVal.toLowerCase().includes(qv);

    if (matchKey && matchVal) {
      const nodeIdx = currentVisibleTreeNodes.push({ label: key, value: val, path }) - 1;
      rows.push(`
        <div class="tree-node" style="padding-left:${Math.min(depth, 8) * 16 + 8}px">
          <button class="tree-caret" data-action="toggle-tree-node" data-id="${esc(path)}">
            ${isObj ? (state.messageCollapsed.has(path) ? '▸' : '▾') : '·'}
          </button>
          <span class="tree-k">${highlightMatch(key, qk)}</span>
          <span class="tree-v ${canFocusNested ? 'nested-hint' : ''}">${highlightMatch(strVal.length > 180 ? strVal.slice(0, 180) + '…' : strVal, qv)}</span>
          ${canFocusNested || isObj ? `
            <button class="focus-pill" data-action="focus-tree-node" data-id="${nodeIdx}" title="将此节点推入面包屑并递归解析内部的 JSON / XML / CDATA">
              ${canFocusNested ? '解析嵌套 ↗' : '专注'}
            </button>
          ` : ''}
        </div>
      `);
    }
    if (isObj && !state.messageCollapsed.has(path)) {
      Object.entries(val).forEach(([childK, childV]) => walk(childK, childV, `${path}/${childK}`, depth + 1));
    }
  }

  if (!state.messageRaw && parsed.format !== '纯文本') {
    walk('$', parsed.value, '$', 0);
  }

  return `
    <div class="msg-container">
      <div class="msg-toolbar">
        <select class="ctl-select" id="msg-file-select" style="max-width:310px" aria-label="选择报文文件">
          ${samples.map((s, i) => `<option value="${i}" ${state.messageFileIndex === i ? 'selected' : ''}>${esc(s.name)}</option>`).join('')}
        </select>
        <select class="ctl-select" id="msg-format-select" aria-label="解析格式">
          <option value="auto" ${state.messageFormat === 'auto' ? 'selected' : ''}>自动识别 (${parsed.format})</option>
          <option value="json" ${state.messageFormat === 'json' ? 'selected' : ''}>JSON</option>
          <option value="xml" ${state.messageFormat === 'xml' ? 'selected' : ''}>XML</option>
          <option value="text" ${state.messageFormat === 'text' ? 'selected' : ''}>纯文本</option>
        </select>
        <button class="btn sm" data-action="toggle-msg-raw">${state.messageRaw ? '切回结构树' : '查看原文'}</button>
        <input class="ctl-input" id="msg-key-input" placeholder="过滤字段名 Key…" value="${esc(state.messageKeyFilter)}" style="width:140px">
        <input class="ctl-input" id="msg-val-input" placeholder="搜索报文内容…" value="${esc(state.messageValFilter)}" style="width:150px">
        <div class="row" style="margin-left:auto">
          <button class="btn sm" data-action="copy-msg">${icon('copy')} 复制</button>
          <button class="btn sm" data-action="download-msg">${icon('download')} 保存报文</button>
        </div>
      </div>

      <div class="msg-breadcrumbs">
        <span class="muted">${icon('code')} 专注路径：</span>
        ${state.messageFrames.map((f, idx) => `
          <button class="crumb-btn" data-action="pop-msg-crumb" data-id="${idx}">${esc(f.label)}</button>
          ${idx < state.messageFrames.length - 1 ? '<span class="muted">/</span>' : ''}
        `).join('')}
        <span class="badge blue" style="margin-left:auto">${parsed.format} · 支持 CDATA 与多重转义 JSON 逐层钻取</span>
      </div>

      <div class="msg-tree-scroll" id="msg-tree-scroll">
        ${state.messageRaw || parsed.format === '纯文本'
          ? `<pre class="mono" style="margin:0;font-size:12px;line-height:1.75;white-space:pre-wrap;word-break:break-all">${highlightMatch(parsed.source, state.messageValFilter)}</pre>`
          : rows.join('') || '<div class="empty-state"><p>未找到匹配的报文字段</p></div>'
        }
      </div>
    </div>
  `;
}

/* ---------- 4 & 5. 签字与图片连续画廊 ---------- */
function renderGallerySection(kind) {
  const w = currentWork();
  const isSign = kind === 'sign';
  const items = isSign
    ? [
        { title: '客户本人手写签字轨 (signature_01.svg)', meta: '采样点：284 · 压感级别：1024 · ext8=0', svg: SIGN_SVG_CUSTOMER },
        { title: '营业厅受理工号复核签字 (signature_02.svg)', meta: `工号：${w.loginNo} · 渠道：${w.ext1}`, svg: SIGN_SVG_AGENT },
      ]
    : [
        { title: '二代身份证 · 人像面 (picSeq=1)', meta: '分辨率：1280×800 · 实名水印已合成', badge: '证件正面' },
        { title: '二代身份证 · 国徽面 (picSeq=2)', meta: '有效期核验：通过 · 签发机关：南京市公安局', badge: '证件反面' },
        { title: '现场活体人证比对抓拍 (picSeq=3)', meta: `比对相似度：99.4% · 受理流水：${w.sysAccept}`, badge: '人像抓拍' },
      ];

  return `
    <div class="gallery-container">
      <div class="gallery-head">
        <div>
          <strong style="font-size:14px">${isSign ? '电子签字笔迹画廊' : '关联业务影像画廊'}</strong>
          <span class="muted" style="margin-left:10px;font-size:11.5px">共 ${items.length} 份 · 原生连续展示，单图支持独立重试与全屏</span>
        </div>
        <div class="row">
          <button class="btn soft sm" data-action="send-to-repair">${icon('repair')} 去图片修复工作台提取合成</button>
          <button class="btn sm" data-action="download-all-gallery">${icon('download')} 批量下载全部 (${items.length})</button>
        </div>
      </div>

      <div class="gallery-grid" style="grid-template-columns:repeat(${items.length}, minmax(240px, 1fr))">
        ${items.map((item, idx) => `
          <article class="media-card">
            <header>
              <h4>${esc(item.title)}</h4>
              <div class="row" style="gap:2px">
                <button class="icon-btn" data-action="preview-media" data-id="${idx}" title="全屏查看">${icon('expand')}</button>
                <button class="icon-btn" data-action="download-single-media" data-id="${idx}" title="下载此文件">${icon('download')}</button>
              </div>
            </header>
            <div class="media-stage">
              ${isSign ? item.svg : `
                <div style="width:86%;height:165px;background:var(--bg-elevated);border:1.5px solid var(--line-strong);border-radius:10px;padding:14px;display:flex;flex-direction:column;justify-content:space-between;position:relative">
                  <div class="row between">
                    <span class="badge blue">${esc(item.badge)}</span>
                    <span class="mono muted" style="font-size:10px">OBS://receipt${esc(w.regionCode)}</span>
                  </div>
                  <div style="display:flex;align-items:center;gap:14px;margin:8px 0">
                    <div style="width:52px;height:64px;border-radius:7px;background:var(--brand-soft);border:1px solid var(--brand-border);display:grid;place-items:center;color:var(--brand)">
                      ${icon('image')}
                    </div>
                    <div class="grow">
                      <div style="height:7px;width:75%;background:var(--line-strong);border-radius:4px;margin-bottom:8px"></div>
                      <div style="height:6px;width:55%;background:var(--line);border-radius:4px;margin-bottom:8px"></div>
                      <div style="height:6px;width:85%;background:var(--line);border-radius:4px"></div>
                    </div>
                  </div>
                  <div class="mono muted" style="font-size:9.5px;text-align:right">专用于江苏移动无纸化业务核验 · 严禁外传</div>
                </div>
              `}
            </div>
            <footer>
              <span>${esc(item.meta)}</span>
              <span class="badge green">已读取</span>
            </footer>
          </article>
        `).join('')}
      </div>
    </div>
  `;
}

/* ==========================================================================
   工作台二：单据图片修复工作台 (PdfEditorScreen · 三栏 + 常驻流光贝塞尔曲线)
   ========================================================================== */
function renderRepairWorkbench() {
  const r = state.repair;
  const isMobileSurface = state.viewport === 'mobile' || isEmbedMobile;
  const pageDiff = r.oldPages !== r.newPages;

  return `
    <main class="repair-workbench">
      <!-- 顶部新老单据加载与修复工具栏 -->
      <section class="repair-topbar">
        <div class="repair-inputs-row">
          <div class="doc-input-pill">
            <span class="tag old">旧单据号 (来源)</span>
            <input id="repair-old-input" value="${esc(r.oldCaseNo)}" aria-label="旧单据号">
          </div>
          <span class="muted">${icon('chevron')}</span>
          <div class="doc-input-pill">
            <span class="tag new">新单据号 (目标)</span>
            <input id="repair-new-input" value="${esc(r.newCaseNo)}" aria-label="新单据号">
          </div>

          <button class="btn sm" data-action="repair-reload">${icon('refresh')} 加载单据</button>
          <button class="btn soft sm" data-action="repair-collect" ${r.selectedSourceIds.size === 0 ? 'disabled' : ''}>
            ${icon('plus')} 加入共享区 (${r.selectedSourceIds.size})
          </button>
          <button class="btn sm" data-action="repair-import-local">
            ${icon('image')} 导入本地图片
          </button>
          <button class="btn primary sm" data-action="repair-apply" ${!r.needsSync ? 'disabled' : ''}>
            ${icon('bolt')} 应用 (${r.needsSync ? '待合成' : '已同步'})
          </button>
          <button class="btn sm ${!r.needsSync ? 'soft' : ''}" data-action="repair-save" ${r.needsSync ? 'disabled' : ''}>
            ${icon('download')} 保存到本地 (_修复.pdf)
          </button>
        </div>

        <div class="row between" style="font-size:11.5px;color:var(--ink-secondary);flex-wrap:wrap">
          <span>操作提示：点击左侧旧单据图片框可多选并加入共享区；点击「应用」后合成 PDF，再保存到本地（不会自动覆盖 OBS）。</span>
          ${!isMobileSurface ? `
            <div class="row">
              <span class="badge blue">蓝色：旧图同步</span>
              <span class="badge purple">紫色：右侧暂存</span>
              <span class="badge amber">琥珀：本地导入</span>
              <button class="btn quiet sm" data-action="toggle-repair-lines" style="padding:2px 7px">
                ${r.showConnections ? '隐藏流光连线' : '显示流光连线'}
              </button>
            </div>
          ` : `
            <div class="segmented">
              <button class="${r.mobileSide === 'source' ? 'active' : ''}" data-action="repair-mobile-side" data-id="source">旧单据 (${r.oldPages}页)</button>
              <button class="${r.mobileSide === 'target' ? 'active' : ''}" data-action="repair-mobile-side" data-id="target">新单据预览 (${r.newPages}页)</button>
            </div>
          `}
        </div>
      </section>

      <!-- 页数不一致琥珀色警告条 -->
      ${pageDiff ? `
        <div class="repair-mismatch-banner" role="status">
          <div class="row">
            ${icon('alert')}
            <span><strong>页数不一致提示：</strong>旧单据共 <b>${r.oldPages}</b> 页，新单据当前仅 <b>${r.newPages}</b> 页。第 3 页上的素材无法自动对应，可一键将旧单据第 3 页复制到新单据末尾补齐。</span>
          </div>
          <button class="btn amber sm" data-action="repair-copy-missing-page">
            ${icon('copy')} 复制旧单据第 3 页到新单据末尾
          </button>
        </div>
      ` : ''}

      <!-- 三栏画布 + 顶层 SVG 动态流光贝塞尔连线 -->
      <section class="repair-stage" id="repair-stage">
        ${!isMobileSurface || r.mobileSide === 'source' ? renderRepairSourceColumn() : ''}
        ${renderRepairSharedColumn(isMobileSurface)}
        ${!isMobileSurface || r.mobileSide === 'target' ? renderRepairTargetColumn() : ''}
        <svg class="connections-svg" id="repair-connections-svg" aria-hidden="true"></svg>
      </section>
    </main>
  `;
}

function renderRepairSourceColumn() {
  const r = state.repair;
  return `
    <div class="repair-column">
      <header class="repair-col-head">
        <span>旧单据 · 选择图片 <small class="mono muted">${esc(r.oldCaseNo)} (${r.oldPages}页)</small></span>
        <div class="row" style="gap:4px">
          <button class="btn quiet sm" data-action="repair-mirror-page" title="在左侧将第 1 页复制为镜像页">镜像旧页</button>
          <button class="btn quiet sm" data-action="repair-copy-missing-page" title="复制旧单据页到右侧新单据">复制页到右侧</button>
        </div>
      </header>
      <div class="repair-canvas-scroll" id="repair-source-scroll">
        ${Array.from({ length: r.oldPages }, (_, idx) => {
          const page = idx + 1;
          const objs = r.sourceObjects.filter((o) => o.page === page);
          return `
            <article class="repair-paper">
              <div class="repair-paper-bar">
                <strong>旧单据 · 第 ${page} / ${r.oldPages} 页</strong>
                <span class="mono">可点选提取图片图层</span>
              </div>
              <p style="margin:4px 0 8px;color:#64748b;font-size:10.5px">
                业务受理存档页（单据号：${esc(r.oldCaseNo)}）。点击下方带框图片图层可多选加入中间共享区：
              </p>
              ${objs.map((o) => {
                const selected = r.selectedSourceIds.has(o.id);
                const inShared = r.materials.some((m) => m.sourceObjId === o.id);
                return `
                  <div class="pdf-img-object ${selected ? 'selected' : ''}" id="anchor-src-${o.id}" data-action="toggle-source-obj" data-id="${o.id}">
                    <div class="obj-meta-bar">
                      <span style="color:var(--brand)">${selected ? '☑ 已选中 · ' : '☐ '}${esc(o.label)}</span>
                      <span class="badge ${inShared ? 'blue' : ''}">${inShared ? '已在共享区' : esc(o.size)}</span>
                    </div>
                    ${renderMiniObjectThumb(o.kind)}
                  </div>
                `;
              }).join('')}
            </article>
          `;
        }).join('')}
      </div>
    </div>
  `;
}

function renderRepairSharedColumn(compact) {
  const r = state.repair;
  return `
    <div class="repair-column" style="${compact ? 'max-height:195px;flex:none' : ''}">
      <header class="repair-col-head">
        <span>共享素材区 (${r.materials.length})</span>
        <span style="color:var(--green);font-size:11px;display:inline-flex;align-items:center;gap:3px">${icon('bolt')} 实时联动</span>
      </header>
      <div class="shared-grid" id="repair-shared-scroll">
        ${r.materials.length ? r.materials.map((m) => {
          const missingPage = m.targetPage > r.newPages;
          const srcClass = m.kind === 'staged' ? 'src-staged' : m.kind === 'local' ? 'src-local' : 'src-old';
          return `
            <div class="material-card ${srcClass}" id="anchor-mat-${m.id}">
              <div class="material-preview">
                ${renderMiniObjectThumb(m.thumbKind || m.kind)}
                <button class="material-remove" data-action="remove-material" data-id="${m.id}" title="从共享区移除">×</button>
              </div>
              <div class="material-foot">
                <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(m.label)}</span>
                <span class="mono">${missingPage ? '⚠缺页' : `→P${m.targetPage}`}</span>
              </div>
            </div>
          `;
        }).join('') : `
          <div class="empty-state" style="padding:16px 8px">
            <p style="font-size:11px">从左侧点选旧图或导入本地图片后在此展示</p>
          </div>
        `}
      </div>
    </div>
  `;
}

function renderRepairTargetColumn() {
  const r = state.repair;
  return `
    <div class="repair-column">
      <header class="repair-col-head">
        <span>新单据 · 修复预览 <small class="mono muted">${esc(r.newCaseNo)} (${r.newPages}页)</small></span>
        <span class="badge ${r.needsSync ? 'amber' : 'green'}">
          <i></i>${r.needsSync ? '画布实时预览 · 待点击应用' : '已应用合成 PDF'}
        </span>
      </header>
      <div class="repair-canvas-scroll" id="repair-target-scroll">
        ${Array.from({ length: r.newPages }, (_, idx) => {
          const page = idx + 1;
          const matsOnPage = r.materials.filter((m) => m.targetPage === page);
          return `
            <article class="repair-paper">
              <div class="repair-paper-bar">
                <strong>新单据 · 第 ${page} / ${r.newPages} 页</strong>
                <button class="btn quiet sm" data-action="repair-stage-right-img" data-id="${page}" style="font-size:10px;padding:1px 6px">
                  暂存本页原图到共享区
                </button>
              </div>
              <p style="margin:4px 0 8px;color:#64748b;font-size:10.5px">
                目标单据（${esc(r.newCaseNo)}）实时合成画布。共享区素材按对应页序与坐标在此实时叠加预览：
              </p>
              ${matsOnPage.length ? matsOnPage.map((m) => {
                const syncCls = m.kind === 'staged' ? 'synced-staged' : m.kind === 'local' ? 'synced-local' : 'synced-old';
                return `
                  <div class="pdf-img-object ${syncCls}" id="anchor-tgt-${m.id}">
                    <div class="obj-meta-bar">
                      <span>${r.needsSync ? '⚡ 实时预览图层：' : '✓ 已固化图层：'}${esc(m.label)}</span>
                      <span class="mono muted">${esc(m.size)}</span>
                    </div>
                    ${renderMiniObjectThumb(m.thumbKind || m.kind)}
                  </div>
                `;
              }).join('') : `
                <div style="padding:18px;border:1px dashed #cbd5e1;border-radius:6px;text-align:center;color:#94a3b8;font-size:11px">
                  本页暂无叠加素材 · 可从左侧选择图片加入共享区
                </div>
              `}
            </article>
          `;
        }).join('')}
      </div>
    </div>
  `;
}

/* 绘制常驻流光贝塞尔曲线：左图右侧锚点 → 共享卡片左右锚点 → 右图左侧锚点 */
function drawRepairConnections() {
  const svg = document.getElementById('repair-connections-svg');
  const stage = document.getElementById('repair-stage');
  if (!svg || !stage || !state.repair.showConnections || state.viewport === 'mobile' || isEmbedMobile) {
    if (svg) svg.innerHTML = '';
    return;
  }

  const stageRect = stage.getBoundingClientRect();
  const paths = [];

  state.repair.materials.forEach((m, index) => {
    const matEl = document.getElementById(`anchor-mat-${m.id}`);
    if (!matEl) return;
    const matRect = matEl.getBoundingClientRect();
    const strokeColor = m.kind === 'staged' ? '#7c3aed' : m.kind === 'local' ? '#d97706' : '#2563eb';
    const laneOffset = (index - 1.5) * 6;

    // 1. 左图 → 共享卡片左侧
    const srcEl = document.getElementById(`anchor-src-${m.sourceObjId}`);
    if (srcEl) {
      const srcRect = srcEl.getBoundingClientRect();
      const x1 = srcRect.right - stageRect.left;
      const y1 = srcRect.top + srcRect.height / 2 - stageRect.top;
      const x2 = matRect.left - stageRect.left;
      const y2 = matRect.top + matRect.height / 2 - stageRect.top;
      const cx = (x1 + x2) / 2 + laneOffset;
      const d = `M ${x1} ${y1} C ${cx} ${y1}, ${cx} ${y2}, ${x2} ${y2}`;
      paths.push(`<path class="conn-track" d="${d}" stroke="${strokeColor}"/>`);
      paths.push(`<path class="conn-flow" d="${d}" stroke="${strokeColor}"/>`);
      paths.push(`<circle cx="${x1}" cy="${y1}" r="3.5" fill="${strokeColor}"/>`);
      paths.push(`<circle cx="${x2}" cy="${y2}" r="3.5" fill="${strokeColor}"/>`);
    }

    // 2. 共享卡片右侧 → 右侧新单据预览图左侧
    const tgtEl = document.getElementById(`anchor-tgt-${m.id}`);
    if (tgtEl) {
      const tgtRect = tgtEl.getBoundingClientRect();
      const x1 = matRect.right - stageRect.left;
      const y1 = matRect.top + matRect.height / 2 - stageRect.top;
      const x2 = tgtRect.left - stageRect.left;
      const y2 = tgtRect.top + tgtRect.height / 2 - stageRect.top;
      const cx = (x1 + x2) / 2 + laneOffset;
      const d = `M ${x1} ${y1} C ${cx} ${y1}, ${cx} ${y2}, ${x2} ${y2}`;
      paths.push(`<path class="conn-track" d="${d}" stroke="${strokeColor}"/>`);
      paths.push(`<path class="conn-flow" d="${d}" stroke="${strokeColor}"/>`);
      paths.push(`<circle cx="${x1}" cy="${y1}" r="3.5" fill="${strokeColor}"/>`);
      paths.push(`<circle cx="${x2}" cy="${y2}" r="4" fill="${strokeColor}"/>`);
    }
  });

  svg.innerHTML = paths.join('');

  ['repair-source-scroll', 'repair-shared-scroll', 'repair-target-scroll'].forEach((id) => {
    const sc = document.getElementById(id);
    if (sc && !sc.dataset.boundConn) {
      sc.dataset.boundConn = '1';
      sc.addEventListener('scroll', () => requestAnimationFrame(drawRepairConnections), { passive: true });
    }
  });
}

window.addEventListener('resize', () => {
  if (state.editorTab) requestAnimationFrame(drawRepairConnections);
  else if (state.section === 'pdf') applyPdfZoom();
});

/* ==========================================================================
   全局模态框系统：1. 工单查询  2. 五表查询与SM4解密  3. 容器日志与批量下载
                  4. 三级确认上传修复  5. 多环境与密钥设置  6. 接口与运行日志
   ========================================================================== */
function openModal(title, subtitle, bodyHtml, footHtml = '', wide = false) {
  const overlay = document.getElementById('overlay');
  if (!overlay) return;
  overlay.innerHTML = `
    <div class="scrim" data-action="scrim-close">
      <section class="dialog ${wide ? 'wide' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title)}" onclick="event.stopPropagation()">
        <header class="dialog-head">
          <div>
            <h2>${esc(title)}</h2>
            <p>${esc(subtitle)}</p>
          </div>
          <button class="icon-btn" data-action="close-modal" title="关闭 (Esc)">${icon('close')}</button>
        </header>
        <div class="dialog-body">${bodyHtml}</div>
        ${footHtml ? `<footer class="dialog-foot">${footHtml}</footer>` : ''}
      </section>
    </div>
  `;
}

function closeModal() {
  const overlay = document.getElementById('overlay');
  if (overlay) overlay.innerHTML = '';
  state.modal = null;
}

/* 弹层 1：工单查询 (支持单月与最多 12 个月范围查询 + 最近 30 次搜索历史) */
function showSearchDialog() {
  state.modal = 'search';
  const q = state.query;
  openModal(
    '查询工单',
    '支持手机号码、受理流水或单据号查询 · 跨月范围最多 12 个月，本地保留最近 30 次合法历史',
    `
      <div class="segmented" style="width:100%;display:grid;grid-template-columns:repeat(3,1fr);margin-bottom:16px">
        ${[
          ['phoneNo', '手机号码'],
          ['sysAccept', '受理流水'],
          ['caseNo', '单据号 (免填月份)'],
        ].map(([k, label]) => `
          <button class="${q.kind === k ? 'active' : ''}" data-action="set-query-kind" data-id="${k}" style="padding:8px">${label}</button>
        `).join('')}
      </div>

      <div style="margin-bottom:14px">
        <label style="display:flex;justify-content:space-between;font-size:12px;font-weight:600;margin-bottom:6px">
          <span>${FIELD_LABELS[q.kind]}</span>
          <small class="muted">${q.kind === 'phoneNo' ? '11 位移动手机号' : '输入完整编号'}</small>
        </label>
        <input class="ctl-input mono" id="modal-query-val" value="${esc(q.value)}" style="width:100%;font-size:16px;padding:11px 13px">
      </div>

      ${q.kind !== 'caseNo' ? `
        <div class="row between" style="margin-bottom:8px">
          <strong style="font-size:12px">业务月份范围</strong>
          <div class="segmented">
            <button class="${!q.range ? 'active' : ''}" data-action="set-query-range" data-id="single">单月精确查询</button>
            <button class="${q.range ? 'active' : ''}" data-action="set-query-range" data-id="range">跨月范围 (最多12个月)</button>
          </div>
        </div>
        <div class="row" style="margin-bottom:10px">
          <input type="month" class="ctl-input mono grow" id="modal-query-start" value="${esc(q.start)}">
          ${q.range ? `<span class="muted">至</span><input type="month" class="ctl-input mono grow" id="modal-query-end" value="${esc(q.end)}">` : ''}
        </div>
        <div class="row" style="margin-bottom:16px">
          <button class="btn sm" data-action="query-Quick-months" data-id="1">本月 (2026-10)</button>
          <button class="btn sm" data-action="query-Quick-months" data-id="3">最近 3 个月</button>
          <button class="btn sm" data-action="query-Quick-months" data-id="6">最近 6 个月</button>
        </div>
      ` : `
        <p class="muted" style="font-size:11.5px;margin:0 0 16px">单据号内已包含业务月份信息，服务端将自动解析对应分表。</p>
      `}

      <div style="border-top:1px solid var(--line);padding-top:12px">
        <div class="row between" style="margin-bottom:8px">
          <span class="muted" style="font-size:11px;font-weight:600">最近查询历史 (本地持久化)</span>
          <button class="btn quiet sm" data-action="clear-search-history" style="font-size:11px">清空历史</button>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px">
          ${state.history.length ? state.history.map((h, i) => `
            <button class="btn quiet" style="justify-content:space-between;padding:7px 10px" data-action="apply-history" data-id="${i}">
              <span class="mono">${esc(FIELD_LABELS[h.kind])} · ${esc(h.value)}</span>
              <small class="muted mono">${esc(h.start)}${h.range ? ' ~ ' + esc(h.end) : ''}</small>
            </button>
          `).join('') : '<span class="muted" style="font-size:11px">暂无历史记录</span>'}
        </div>
      </div>
    `,
    `
      <span class="muted" style="font-size:11px">${icon('shield')} 客户端直接发起 HTTPS 请求，不经过浏览器代理</span>
      <div class="row">
        <button class="btn quiet" data-action="close-modal">取消</button>
        <button class="btn primary" data-action="execute-search">${icon('search')} 立即查询</button>
      </div>
    `
  );
}

/* 弹层 2：五表数据查询与接口结果表 SM4 本地解密 (TableQuerySheet) */
function showTableQueryDialog() {
  state.modal = 'table-sm4';
  const w = currentWork();
  const tables = [
    ['WO_INFO', '工单表'],
    ['WO_BIZ_INFO', '报文表'],
    ['WO_SIGN_INFO', '签字表'],
    ['WO_PIC_INFO', '图片表 (picSeq)'],
    ['SYS_INTER_RESULT', '接口结果表 (SM4解密)'],
  ];

  const isInter = state.tableKind === 'SYS_INTER_RESULT';
  const isPic = state.tableKind === 'WO_PIC_INFO';

  const interRows = [
    {
      interId: 'IR_20261012_001',
      interUrl: 'signcheck',
      retCode: '0000',
      opTime: '2026-10-12 14:32:05',
      retMsg: state.sm4Decrypted ? '电子签名轨迹质量校验通过 (strokes=284)' : 'SM4:9f4a8c12e7b03d55a1c8e902f4b7d610',
      retDetail: state.sm4Decrypted ? '{"verifyScore":99.6,"signer":"CUSTOMER","status":"PASS"}' : 'SM4:4e21b8c79012fa34d87c65e1209ab31c8890f12a',
      paramInt: state.sm4Decrypted ? `{"caseNo":"${w.caseNo}","channel":"HALL_PAD"}` : 'SM4:7a19c044b2e8d15f6632a098c4b1e72d',
    },
    {
      interId: 'IR_20261012_002',
      interUrl: 'crm_order_sync',
      retCode: '0000',
      opTime: '2026-10-12 14:32:07',
      retMsg: state.sm4Decrypted ? 'CRM 营业工单同步归档成功' : 'SM4:3c81d902a4f5e612b789c012d3e4f5a6',
      retDetail: state.sm4Decrypted ? `{"sysAccept":"${w.sysAccept}","archiveBucket":"receipt025"}` : 'SM4:8b72e190c3a4d567e890f123a4b5c6d7',
      paramInt: state.sm4Decrypted ? `{"phoneNo":"${w.phoneNo}","opCode":"${w.opCode}"}` : 'SM4:1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f60',
    },
    {
      interId: 'IR_20261012_003',
      interUrl: 'obs_pdf_seal',
      retCode: '0000',
      opTime: '2026-10-12 14:32:08',
      retMsg: 'PDF 电子印章合成成功 (无 SM4: 前缀明文原样展示)',
      retDetail: '{"pdfSize":294912,"sealCode":"JS_025_SEAL"}',
      paramInt: `{"objectName":"${w.caseNo}.pdf"}`,
    },
  ];

  openModal(
    '物理表数据直查与 SM4 解密',
    '支持 WO_INFO / WO_BIZ_INFO / WO_SIGN_INFO / WO_PIC_INFO / SYS_INTER_RESULT · 复用只读接口',
    `
      <div class="table-pills" role="tablist">
        ${tables.map(([k, label]) => `
          <button class="table-pill ${state.tableKind === k ? 'active' : ''}" data-action="select-table-kind" data-id="${k}">
            <span>${label}</span>
            <code class="mono" style="font-size:10px;opacity:0.8">${k}</code>
          </button>
        `).join('')}
      </div>

      <div class="row" style="flex-wrap:wrap;margin-bottom:12px">
        <input class="ctl-input mono grow" value="${esc(w.caseNo)}" placeholder="单据号 caseNo" aria-label="单据号">
        <input class="ctl-input mono" style="width:170px" placeholder="${isPic ? '图片序号 picSeq (如 1,2,3)' : '受理流水 sysAccept'}" value="${isPic ? '1,2,3' : esc(w.sysAccept)}">
        <input type="month" class="ctl-input mono" style="width:135px" value="2026-10">
        ${isInter ? `<input class="ctl-input mono" style="width:130px" placeholder="接口标识 (如 signcheck)" value="signcheck">` : ''}
        <button class="btn primary sm" data-action="run-table-query">${icon('search')} 查询表数据</button>
      </div>

      ${isInter ? `
        <div class="sm4-box">
          <div class="row between" style="margin-bottom:8px;flex-wrap:wrap">
            <div class="row">
              ${icon('key')}
              <strong style="font-size:12px">会话内 SM4/ECB 本地解密 (对齐 CrmFieldEncryptService / Sm4EcbPkcs5)</strong>
              <span class="badge ${state.sm4Decrypted ? 'green' : 'amber'}">
                ${state.sm4Decrypted ? '✓ 已解密 retMsg / retDetail / paramInt' : '当前显示原始 SM4:Base64 密文'}
              </span>
            </div>
            <span class="muted" style="font-size:10.5px">密钥仅存当前面板内存，不发服务端、不写日志</span>
          </div>
          <div class="row" style="flex-wrap:wrap">
            <input class="ctl-input mono grow" id="sm4-key-input" value="${esc(state.sm4Key)}" placeholder="输入 16 字节 UTF-8 原始 SM4 密钥">
            <button class="btn soft sm" data-action="toggle-sm4-decrypt" data-id="decrypt">本地解密 (16字节)</button>
            <button class="btn quiet sm" data-action="toggle-sm4-decrypt" data-id="clear">清除密钥及明文</button>
          </div>
        </div>
      ` : ''}

      <div class="data-table-wrap">
        <table class="data-table">
          <thead>
            ${isInter
              ? `<tr><th>接口标识</th><th>返回码</th><th>调用时间</th><th>retMsg (${state.sm4Decrypted ? '已解密明文' : 'SM4密文'})</th><th>retDetail</th><th>paramInt</th></tr>`
              : `<tr><th>单据号 (caseNo)</th><th>受理流水 / 序号</th><th>业务月份</th><th>业务名称 / 文件路径</th><th>状态</th></tr>`
            }
          </thead>
          <tbody>
            ${isInter
              ? interRows.map((r, idx) => `
                <tr data-action="inspect-table-row" data-id="${idx}">
                  <td class="mono"><b>${esc(r.interUrl)}</b></td>
                  <td><span class="badge green mono">${esc(r.retCode)}</span></td>
                  <td class="mono muted">${esc(r.opTime.slice(11))}</td>
                  <td class="mono" style="color:${state.sm4Decrypted ? 'var(--green)' : 'var(--ink-secondary)'}">${esc(r.retMsg)}</td>
                  <td class="mono">${esc(r.retDetail)}</td>
                  <td class="mono">${esc(r.paramInt)}</td>
                </tr>
              `).join('')
              : state.works.map((row) => `
                <tr>
                  <td class="mono">${esc(row.caseNo)}</td>
                  <td class="mono">${esc(isPic ? row.picSeq : row.sysAccept)}</td>
                  <td class="mono">${esc(row.opMonth)}</td>
                  <td class="mono">${esc(state.tableKind === 'WO_INFO' ? row.opName : row.fileName)}</td>
                  <td><span class="badge green">${esc(row.stsDesc)}</span></td>
                </tr>
              `).join('')
            }
          </tbody>
        </table>
      </div>
    `,
    `
      <span class="muted" style="font-size:11px">点击任意行可查看完整字段与复制 JSON · 切换表或关闭面板自动释放解密明文</span>
      <button class="btn primary" data-action="close-modal">完成</button>
    `,
    true
  );
}

/* 弹层 3：容器日志文件浏览与通配符批量下载 (LogFilesSheet & LogBatchDialog) */
function showPodLogsDialog() {
  state.modal = 'pod-logs';
  const pods = state.logApp === 'server'
    ? [
        {
          pod: 'npl-js-prod-7d9f8b-x2k9p',
          ip: '10.244.1.82:18080',
          files: [
            { name: 'npl-service-info.log', size: '48.6 MB', updated: '14:35:20', key: 'inode:884120' },
            { name: 'npl-service-error.log', size: '3.2 MB', updated: '14:29:11', key: 'inode:884121' },
            { name: 'crm-interface-trace.log', size: '112.4 MB', updated: '14:35:22', key: 'inode:884125' },
          ],
        },
        {
          pod: 'npl-js-prod-7d9f8b-m4v1q',
          ip: '10.244.2.19:18080',
          files: [
            { name: 'npl-service-info.log', size: '51.1 MB', updated: '14:35:19', key: 'inode:910244' },
            { name: 'npl-service-error.log', size: '1.8 MB', updated: '14:18:04', key: 'inode:910245' },
          ],
        },
      ]
    : [
        {
          pod: 'npl-web-prod-5c8a1d-p9w2n',
          ip: '10.244.3.45:18081',
          files: [
            { name: 'npl-web-access.log', size: '26.4 MB', updated: '14:35:18', key: 'inode:330192' },
            { name: 'npl-web-error.log', size: '840 KB', updated: '13:50:00', key: 'inode:330193' },
          ],
        },
      ];

  openModal(
    '容器日志文件浏览与分片下载',
    '实时读取注册中心全部在线 Pod 副本的 /usr/local/logs · 按 1.5MB 分片流式写盘 (.part)，支持 HTTP 409 日志轮转按 fileKey 自动续传',
    `
      <div class="row between" style="margin-bottom:14px;flex-wrap:wrap">
        <div class="row">
          <div class="segmented">
            <button class="${state.logApp === 'server' ? 'active' : ''}" data-action="set-log-app" data-id="server">服务端 (npl-js · 2 副本)</button>
            <button class="${state.logApp === 'web' ? 'active' : ''}" data-action="set-log-app" data-id="web">Web 端 (npl-web · 1 副本)</button>
          </div>
          <span class="badge mono">${esc(state.logDir)}</span>
        </div>
        <div class="row">
          <button class="btn soft sm" data-action="trigger-batch-logs">
            ${icon('download')} 按通配符批量下载 (ls *.log)
          </button>
          <button class="btn sm" data-action="refresh-pod-logs">${icon('refresh')} 刷新目录</button>
        </div>
      </div>

      <!-- 批量下载通配符配置栏 -->
      <div class="sm4-box" style="margin-bottom:14px">
        <div class="row between" style="margin-bottom:6px">
          <strong style="font-size:12px">批量下载过滤器（支持 *、?、[abc]，多个模式用空格分隔）</strong>
          <span class="muted" style="font-size:11px">新建 ${state.logApp}_logs_20261105 文件夹并按 Pod 分目录保存</span>
        </div>
        <div class="row">
          <input class="ctl-input mono grow" id="batch-log-pattern" value="${esc(state.logBatchPattern)}">
          <button class="btn primary sm" data-action="trigger-batch-logs">匹配并批量下载全部副本</button>
        </div>
        ${state.logBatchDone ? `
          <div style="margin-top:8px;font-size:11.5px;color:var(--green)">
            ✓ 已完成跨 Pod 批量下载：共保存 5 个日志文件至本地 <code>~/Downloads/${state.logApp}_logs_20261105/</code>（0 个失败）
          </div>
        ` : ''}
      </div>

      ${state.logDownloading ? `
        <div class="repair-mismatch-banner" style="margin-bottom:12px;background:var(--brand-soft);border-color:var(--brand-border);color:var(--brand)">
          <span>正在按 1.5MB 分片流式写入磁盘：<b>${esc(state.logDownloading)}.part</b> (Offset: 12.0 MB / X-File-Size 校验通过)</span>
          <span class="mono">100% 完成</span>
        </div>
      ` : ''}

      ${pods.map((p) => `
        <div class="pod-card">
          <div class="pod-head">
            <div class="row">
              <span class="badge green"><i></i>Online</span>
              <span class="mono">${esc(p.pod)}</span>
            </div>
            <span class="mono muted" style="font-size:11px">${esc(p.ip)}</span>
          </div>
          ${p.files.map((f) => `
            <div class="log-file-row">
              <div class="row">
                ${icon('doc')}
                <span class="mono" style="font-weight:500">${esc(f.name)}</span>
                <span class="badge mono" style="font-size:9.5px">${esc(f.key)}</span>
              </div>
              <div class="row">
                <span class="mono muted" style="font-size:11px">${esc(f.size)} · ${esc(f.updated)}</span>
                <button class="btn sm" data-action="download-pod-file" data-id="${esc(p.pod + '_' + f.name)}">
                  ${icon('download')} 分片下载
                </button>
              </div>
            </div>
          `).join('')}
        </div>
      `).join('')}
    `,
    `
      <span class="muted" style="font-size:11px">内存仅保留当前 1.5MB 分片，下载完成自动重命名 .part 为正式文件</span>
      <button class="btn primary" data-action="close-modal">关闭</button>
    `,
    true
  );
}

/* 弹层 4：单据 PDF 上传修复三级确认弹窗 (Upload Repair 3-Step Confirmation) */
function showUploadRepairDialog() {
  state.modal = 'upload-repair';
  const w = currentWork();
  const step = state.uploadStep || 1;

  let body = '';
  let foot = '';

  if (step === 1) {
    body = `
      <div class="repair-mismatch-banner" style="margin-bottom:14px">
        <span><strong>安全守则：</strong>上传修复文件前，必须先把当前 OBS 上的原始单据 PDF 备份到本地留存，以便异常时恢复。</span>
      </div>
      <div class="kpi-card" style="margin-bottom:12px">
        <small>第一步：已选择的待上传修复文件</small>
        <strong class="mono">${esc(state.uploadPickedFile)} (296.4 KB)</strong>
      </div>
      <div class="kpi-card">
        <small>第二步：本地备份当前原始单据 PDF</small>
        ${state.uploadBackupSaved ? `
          <strong class="mono" style="color:var(--green)">✓ 已备份至：~/Downloads/${esc(w.caseNo)}_backup.pdf</strong>
        ` : `
          <div class="row between" style="margin-top:4px">
            <span class="muted">尚未保存备份，点击右侧按钮保存后方可进入三级确认</span>
            <button class="btn soft sm" data-action="upload-save-backup">${icon('download')} 保存备份文件</button>
          </div>
        `}
      </div>
    `;
    foot = `
      <button class="btn quiet" data-action="close-modal">取消上传</button>
      <button class="btn primary" data-action="upload-next-step" data-id="2" ${!state.uploadBackupSaved ? 'disabled' : ''}>
        已备份，进入第一级确认 (1/3) →
      </button>
    `;
  } else if (step === 2) {
    body = `
      <div class="badge blue" style="margin-bottom:12px">第一级确认 (1 / 3) · 核对单据信息与 OBS 目标参数</div>
      <div class="kpi-strip" style="grid-template-columns:1fr 1fr;margin-bottom:12px">
        <div class="kpi-card"><small>单据号 (caseNo)</small><strong class="mono">${esc(w.caseNo)}</strong></div>
        <div class="kpi-card"><small>CRM 受理流水 (sysAccept)</small><strong class="mono">${esc(w.sysAccept)}</strong></div>
      </div>
      <div style="display:grid;gap:10px">
        <label style="font-size:11.5px;font-weight:600">OBS 目标桶 (bucketName)<input class="ctl-input mono" style="width:100%;margin-top:4px" value="receipt${esc(w.regionCode)}"></label>
        <label style="font-size:11.5px;font-weight:600">OBS 对象名 (objectName)<input class="ctl-input mono" style="width:100%;margin-top:4px" value="${esc(w.caseNo)}.pdf"></label>
        <label style="font-size:11.5px;font-weight:600">加密标识 (ext8)<input class="ctl-input mono" style="width:100%;margin-top:4px" value="${esc(w.ext8)}"></label>
      </div>
    `;
    foot = `
      <button class="btn quiet" data-action="close-modal">取消</button>
      <button class="btn primary" data-action="upload-next-step" data-id="3">参数核对无误，继续 (2/3) →</button>
    `;
  } else if (step === 3) {
    body = `
      <div class="badge amber" style="margin-bottom:12px">第二级确认 (2 / 3) · 强制确认本地备份留存</div>
      <div class="kpi-card" style="margin-bottom:14px">
        <small>当前单据原始 PDF 备份路径：</small>
        <strong class="mono">~/Downloads/${esc(w.caseNo)}_backup.pdf</strong>
      </div>
      <label class="row" style="padding:12px;border:1px solid var(--line);border-radius:var(--r-ctl);cursor:pointer">
        <input type="checkbox" id="upload-backup-check" ${state.uploadBackupChecked ? 'checked' : ''} data-action="toggle-upload-check">
        <span style="font-weight:600">我已核实当前原始单据 PDF 已完整备份到本地留存</span>
      </label>
    `;
    foot = `
      <button class="btn quiet" data-action="close-modal">取消</button>
      <button class="btn primary" data-action="upload-next-step" data-id="4" ${!state.uploadBackupChecked ? 'disabled' : ''}>
        已确认备份，进入最终确认 (3/3) →
      </button>
    `;
  } else {
    body = `
      <div class="badge danger" style="margin-bottom:12px">第三级最终确认 (3 / 3) · 高危写操作不可撤销</div>
      <div style="background:var(--danger-bg);border:1px solid var(--danger-border);color:var(--danger);padding:14px;border-radius:var(--r-card);margin-bottom:14px;font-weight:600">
        ⚠️ 警告：即将调用 /test/look 用「${esc(state.uploadPickedFile)}」直接覆盖 OBS 桶 receipt${esc(w.regionCode)} 中的同名对象 ${esc(w.caseNo)}.pdf，此操作不可撤销！
      </div>
      <p class="muted" style="font-size:12px;line-height:1.7">
        上传将通过独立 multipart 通道发送，不经过只读白名单与响应缓存；成功后系统将自动强制重新读取 OBS 刷新当前 PDF 预览。
      </p>
    `;
    foot = `
      <button class="btn quiet" data-action="close-modal">立即中止</button>
      <button class="btn danger" data-action="upload-confirm-final">${icon('upload')} 确认修复并覆盖上传</button>
    `;
  }

  openModal('上传修复单据 PDF (三级安全确认)', '仅单据 PDF 阅读页提供的受控写操作通道', body, foot);
}

/* 弹层 5：多环境、密钥库与自动更新设置 (SettingsDialog) */
function showSettingsDialog() {
  state.modal = 'settings';
  openModal(
    '连接、多环境与业务密钥设置',
    '配置存储在 ~/.config/npl-maintenance (权限 700/600)，业务私钥受系统钥匙串保护',
    `
      <div style="margin-bottom:16px">
        <div class="row between" style="margin-bottom:8px">
          <strong style="font-size:12.5px">多环境配置 (圆点选中为当前生效环境)</strong>
          <button class="btn soft sm" data-action="add-demo-env">${icon('plus')} 新增环境</button>
        </div>
        <div style="display:flex;flex-direction:column;gap:8px">
          ${state.environments.map((env, idx) => `
            <div style="border:1.5px solid ${state.activeEnvIndex === idx ? 'var(--brand)' : 'var(--line)'};background:${state.activeEnvIndex === idx ? 'var(--brand-tint)' : 'var(--bg-elevated)'};border-radius:var(--r-card);padding:10px 12px">
              <div class="row between" style="margin-bottom:6px">
                <label class="row" style="cursor:pointer;font-weight:600">
                  <input type="radio" name="activeEnv" ${state.activeEnvIndex === idx ? 'checked' : ''} data-action="select-env-radio" data-id="${idx}">
                  <span>${esc(env.name)}</span>
                </label>
                <span class="badge ${state.activeEnvIndex === idx ? 'blue' : ''}">${state.activeEnvIndex === idx ? '当前环境' : '备用'}</span>
              </div>
              <div class="mono muted" style="font-size:11px">服务地址：${esc(env.baseUrl)}</div>
              <div class="mono muted" style="font-size:11px;margin-top:2px">Web地址 (日志用)：${esc(env.webUrl)}</div>
            </div>
          `).join('')}
        </div>
      </div>

      <div class="kpi-strip" style="grid-template-columns:repeat(3,1fr);margin-bottom:14px">
        <div class="kpi-card">
          <small>JWT 受理工号 (loginNo)</small>
          <input class="ctl-input mono" style="width:100%;margin-top:4px" value="${esc(state.loginNo)}">
        </div>
        <div class="kpi-card">
          <small>调用渠道 (channel)</small>
          <input class="ctl-input mono" style="width:100%;margin-top:4px" value="${esc(state.channel)}">
        </div>
        <div class="kpi-card">
          <small>OBS 桶覆盖 (可选)</small>
          <input class="ctl-input mono" style="width:100%;margin-top:4px" placeholder="默认 receipt+地市" value="${esc(state.bucketOverride)}">
        </div>
      </div>

      <div class="sm4-box" style="margin-bottom:14px">
        <div class="row between">
          <div class="row">
            ${icon('lock')}
            <div>
              <strong style="font-size:12px;display:block">RS256 业务签名密钥库 (.jks / .keystore / PKCS#8)</strong>
              <small class="muted mono">已导入钥匙串：${esc(state.keystoreFile)} · 有效期 20 分钟自动签发 kkk 与 agAuthorization</small>
            </div>
          </div>
          <button class="btn sm" data-action="reimport-keystore">重新选择密钥文件</button>
        </div>
      </div>

      <div class="row between" style="padding:10px 12px;background:var(--bg-subtle);border:1px solid var(--line);border-radius:var(--r-card)">
        <div>
          <strong style="font-size:12px">GitHub 应用内自动更新与加速站前缀</strong>
          <div class="mono muted" style="font-size:11px;margin-top:2px">当前版本：v1.6.2 · 加速站：${esc(state.githubProxy)}</div>
        </div>
        <button class="btn soft sm" data-action="check-app-update">${icon('refresh')} 检查新版本</button>
      </div>
    `,
    `
      <span class="muted" style="font-size:11px">切换环境会自动清空当前工单结果、缓存与未保存修复会话</span>
      <div class="row">
        <button class="btn quiet" data-action="close-modal">取消</button>
        <button class="btn primary" data-action="save-settings">保存连接设置</button>
      </div>
    `,
    true
  );
}

/* 弹层 6：接口调用记录与程序运行日志 (LogsDialog) */
function showLogsDialog() {
  state.modal = 'logs';
  openModal(
    '接口调用记录与程序运行诊断日志',
    '所有请求与 PDF 内存渲染阶段均自动脱敏落盘，不记录私钥、JWT 或认证头',
    `
      <div style="display:grid;gap:8px;margin-bottom:14px">
        <div class="kpi-card" style="display:flex;align-items:center;justify-content:space-between">
          <div>
            <small>接口请求日志路径 (每次启动独立 JSONL 文件)</small>
            <strong class="mono" style="font-size:11.5px">~/Library/Application Support/npl_maintenance/request-logs/requests-20261105-1430.jsonl</strong>
          </div>
          <button class="btn sm" data-action="copy-log-path" data-id="request-logs">${icon('copy')} 复制路径</button>
        </div>
        <div class="kpi-card" style="display:flex;align-items:center;justify-content:space-between">
          <div>
            <small>程序运行与 PDFium 阶段诊断日志 (v1.6.2 新增 · 5×4MB 轮转)</small>
            <strong class="mono" style="font-size:11.5px">~/Library/Application Support/npl_maintenance/runtime-logs/runtime-20261105-01.jsonl</strong>
          </div>
          <button class="btn sm" data-action="copy-log-path" data-id="runtime-logs">${icon('copy')} 复制路径</button>
        </div>
      </div>

      <div style="display:flex;flex-direction:column;gap:8px">
        ${state.logs.map((l, idx) => `
          <details class="field-group" ${idx === 0 ? 'open' : ''} style="margin:0">
            <summary>
              <span class="badge green mono">${l.status}</span>
              <span class="mono" style="font-weight:700">${esc(l.method)} ${esc(l.path)}</span>
              <span class="muted" style="font-size:11px">${esc(l.respNote)}</span>
              <small class="mono">${esc(l.time)} · ${esc(l.duration)}</small>
            </summary>
            <div style="padding:10px 14px;background:var(--bg-subtle)">
              <pre class="mono" style="margin:0;font-size:11px;line-height:1.65;white-space:pre-wrap">URL: ${esc(state.environments[state.activeEnvIndex].baseUrl + l.path)}
Request Body: ${esc(JSON.stringify(l.body, null, 2))}
Diagnostic: ${esc(l.respNote)}</pre>
            </div>
          </details>
        `).join('')}
      </div>
    `,
    `
      <button class="btn quiet sm" data-action="clear-cache">${icon('refresh')} 清空内存响应缓存 (${state.cacheHits})</button>
      <button class="btn primary" data-action="close-modal">关闭</button>
    `,
    true
  );
}

/* ==========================================================================
   场景快速切换与双端同步 (Studio Bar & PostMessage)
   ========================================================================== */
function syncDualIframe() {
  if (isEmbedMobile) return;
  const iframe = document.getElementById('dual-iframe');
  if (!iframe) return;
  if (state.viewport === 'dual' && !iframe.getAttribute('src')) {
    iframe.setAttribute('src', 'index.html?embed=mobile');
    iframe.addEventListener('load', () => postStateToIframe(iframe));
  } else if (iframe.contentWindow) {
    postStateToIframe(iframe);
  }
}

function postStateToIframe(iframe) {
  iframe.contentWindow?.postMessage({
    type: 'studio-sync',
    theme: state.theme,
    density: state.density,
    radius: state.radius,
    scene: state.activeScene,
  }, '*');
}

function applyStudioScene(scene) {
  state.activeScene = scene;
  closeModal();

  if (scene === 'details') {
    state.editorTab = false;
    state.selectedWorkIndex = 0;
    state.section = 'details';
  } else if (scene === 'pdf') {
    state.editorTab = false;
    state.selectedWorkIndex = 0;
    state.section = 'pdf';
  } else if (scene === 'message') {
    state.editorTab = false;
    state.selectedWorkIndex = 0;
    state.section = 'message';
  } else if (scene === 'gallery') {
    state.editorTab = false;
    state.selectedWorkIndex = 0;
    state.section = 'sign';
  } else if (scene === 'repair') {
    state.editorTab = true;
  } else if (scene === 'table-sm4') {
    state.editorTab = false;
    renderApp();
    showTableQueryDialog();
    return;
  } else if (scene === 'pod-logs') {
    state.editorTab = false;
    renderApp();
    showPodLogsDialog();
    return;
  } else if (scene === 'settings') {
    state.editorTab = false;
    renderApp();
    showSettingsDialog();
    return;
  }

  renderApp();
  syncDualIframe();
}

window.addEventListener('message', (e) => {
  if (e.data?.type !== 'studio-sync') return;
  state.theme = e.data.theme || state.theme;
  state.density = e.data.density || state.density;
  state.radius = e.data.radius || state.radius;
  if (e.data.scene && e.data.scene !== state.activeScene) {
    applyStudioScene(e.data.scene);
  } else {
    renderApp();
  }
});

/* ==========================================================================
   全局点击与输入事件委托
   ========================================================================== */
document.addEventListener('click', (e) => {
  // 1. 顶部 Studio Bar 按钮处理
  const themeBtn = e.target.closest('[data-studio-theme]');
  if (themeBtn) {
    state.theme = themeBtn.dataset.studioTheme;
    document.querySelectorAll('[data-studio-theme]').forEach((b) => b.classList.toggle('active', b === themeBtn));
    renderApp();
    syncDualIframe();
    return;
  }

  const radiusBtn = e.target.closest('[data-studio-radius]');
  if (radiusBtn) {
    state.radius = radiusBtn.dataset.studioRadius;
    document.querySelectorAll('[data-studio-radius]').forEach((b) => b.classList.toggle('active', b === radiusBtn));
    renderApp();
    syncDualIframe();
    return;
  }

  const densityBtn = e.target.closest('[data-studio-density]');
  if (densityBtn) {
    state.density = densityBtn.dataset.studioDensity;
    document.querySelectorAll('[data-studio-density]').forEach((b) => b.classList.toggle('active', b === densityBtn));
    renderApp();
    syncDualIframe();
    return;
  }

  const vpBtn = e.target.closest('[data-studio-viewport]');
  if (vpBtn) {
    state.viewport = vpBtn.dataset.studioViewport;
    document.querySelectorAll('[data-studio-viewport]').forEach((b) => b.classList.toggle('active', b === vpBtn));
    renderApp();
    syncDualIframe();
    return;
  }

  const sceneBtn = e.target.closest('[data-studio-scene]');
  if (sceneBtn) {
    document.querySelectorAll('[data-studio-scene]').forEach((b) => b.classList.toggle('active', b === sceneBtn));
    applyStudioScene(sceneBtn.dataset.studioScene);
    return;
  }

  const studioAct = e.target.closest('[data-studio-action]');
  if (studioAct) {
    const act = studioAct.dataset.studioAction;
    if (act === 'collapse-bar') document.body.classList.add('studio-collapsed');
    if (act === 'expand-bar') document.body.classList.remove('studio-collapsed');
    if (state.editorTab) requestAnimationFrame(drawRepairConnections);
    return;
  }

  // 2. 应用内业务动作处理
  const btn = e.target.closest('[data-action]');
  if (!btn) return;
  const action = btn.dataset.action;
  const id = btn.dataset.id;

  switch (action) {
    case 'scrim-close':
    case 'close-modal':
      closeModal();
      break;
    case 'switch-mode':
      state.editorTab = id === 'repair';
      renderApp();
      break;
    case 'select-work':
      state.selectedWorkIndex = +id;
      state.messageFrames = [];
      renderApp();
      break;
    case 'mobile-back-list':
      state.selectedWorkIndex = null;
      renderApp();
      break;
    case 'select-section':
      state.section = id;
      renderApp();
      break;
    case 'set-field-mode':
      state.fieldMode = id;
      renderApp();
      break;
    case 'copy-caseno':
      copyText(currentWork().caseNo, '单据号');
      break;
    case 'copy-field':
      copyText(currentWork()[id] ?? '', FIELD_LABELS[id] || id);
      break;
    case 'export-work-json':
      triggerDownload(`${currentWork().caseNo}_WO_INFO.json`, JSON.stringify(currentWork(), null, 2));
      break;
    case 'send-to-repair':
      state.repair.newCaseNo = currentWork().caseNo;
      state.editorTab = true;
      renderApp();
      showToast(`已将单据 ${currentWork().caseNo} 带入「单据图片修复」工作台`);
      break;
    case 'clear-cache':
      state.cacheHits = 0;
      renderApp();
      showToast('已清空内存响应缓存');
      break;
    case 'refresh-query':
      state.queriedAt = new Date().toTimeString().slice(0, 8);
      renderApp();
      showToast('已重新请求后台刷新工单列表');
      break;
    case 'cycle-env':
      state.activeEnvIndex = (state.activeEnvIndex + 1) % state.environments.length;
      state.cacheHits = 0;
      renderApp();
      showToast(`已切换至：${state.environments[state.activeEnvIndex].name}`);
      break;

    // PDF 阅读与三级上传修复
    case 'toggle-pdf-thumbs':
      state.pdfThumbs = !state.pdfThumbs;
      renderApp();
      break;
    case 'jump-pdf-page':
      document.getElementById(`pdf-page-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      break;
    case 'pdf-zoom-in':
      state.pdfFit = 'actual';
      state.pdfZoom = Math.min(180, state.pdfZoom + 15);
      applyPdfZoom();
      break;
    case 'pdf-zoom-out':
      state.pdfFit = 'actual';
      state.pdfZoom = Math.max(55, state.pdfZoom - 15);
      applyPdfZoom();
      break;
    case 'toggle-pdf-full':
      state.pdfFullscreen = !state.pdfFullscreen;
      renderApp();
      break;
    case 'download-pdf':
      triggerDownload(`${currentWork().caseNo}.pdf`, '%PDF-1.4 NPL Console Demo Receipt', 'application/pdf');
      break;
    case 'open-upload-repair':
      state.uploadStep = 1;
      state.uploadBackupSaved = false;
      state.uploadBackupChecked = false;
      showUploadRepairDialog();
      break;
    case 'upload-save-backup':
      state.uploadBackupSaved = true;
      triggerDownload(`${currentWork().caseNo}_backup.pdf`, '%PDF-1.4 Backup Receipt', 'application/pdf');
      showUploadRepairDialog();
      break;
    case 'upload-next-step':
      state.uploadStep = +id;
      showUploadRepairDialog();
      break;
    case 'toggle-upload-check':
      state.uploadBackupChecked = !state.uploadBackupChecked;
      showUploadRepairDialog();
      break;
    case 'upload-confirm-final':
      closeModal();
      showToast('已通过三级确认并完成上传修复，正在重新读取 OBS 最新 PDF…');
      break;

    // 报文树交互
    case 'toggle-msg-raw':
      state.messageRaw = !state.messageRaw;
      renderApp();
      break;
    case 'toggle-tree-node':
      if (state.messageCollapsed.has(id)) state.messageCollapsed.delete(id);
      else state.messageCollapsed.add(id);
      renderApp();
      break;
    case 'focus-tree-node': {
      const node = currentVisibleTreeNodes[+id];
      if (node) {
        state.messageFrames.push({ label: node.label, value: node.value });
        state.messageKeyFilter = '';
        state.messageValFilter = '';
        renderApp();
      }
      break;
    }
    case 'pop-msg-crumb':
      state.messageFrames = state.messageFrames.slice(0, +id + 1);
      renderApp();
      break;
    case 'copy-msg':
      copyText(getMessageSamples()[state.messageFileIndex].raw, '当前报文');
      break;
    case 'download-msg':
      triggerDownload(`${currentWork().caseNo}_message.txt`, getMessageSamples()[state.messageFileIndex].raw, 'text/plain;charset=utf-8');
      break;

    // 画廊交互
    case 'download-all-gallery':
    case 'download-single-media':
      triggerDownload(`${currentWork().caseNo}_media.svg`, SIGN_SVG_CUSTOMER, 'image/svg+xml');
      break;
    case 'preview-media':
      openModal('高清影像与签字笔迹检视', `${currentWork().caseNo} · 原生缩放预览`, `<div style="padding:28px;background:var(--bg-subtle);border-radius:12px;display:grid;place-items:center">${SIGN_SVG_CUSTOMER}</div>`, `<button class="btn primary" data-action="close-modal">关闭预览</button>`);
      break;

    // 单据图片修复工作台动作
    case 'toggle-source-obj':
      if (state.repair.selectedSourceIds.has(id)) state.repair.selectedSourceIds.delete(id);
      else state.repair.selectedSourceIds.add(id);
      renderApp();
      break;
    case 'repair-collect':
      state.repair.selectedSourceIds.forEach((srcId) => {
        const obj = state.repair.sourceObjects.find((o) => o.id === srcId);
        if (obj && !state.repair.materials.some((m) => m.sourceObjId === obj.id)) {
          state.repair.materials.push({
            id: `mat-${Date.now()}-${Math.random().toString(36).slice(2, 5)}`,
            sourceObjId: obj.id,
            kind: 'old',
            thumbKind: obj.kind,
            page: obj.page,
            targetPage: Math.min(obj.page, state.repair.newPages),
            label: `旧图 · ${obj.page}页 (${obj.label.split(' ')[0]})`,
            size: obj.size.replace(' px', ''),
          });
        }
      });
      state.repair.selectedSourceIds.clear();
      state.repair.needsSync = true;
      renderApp();
      showToast('已将选中旧单据图片加入共享素材区');
      break;
    case 'remove-material':
      state.repair.materials = state.repair.materials.filter((m) => m.id !== id);
      state.repair.needsSync = true;
      renderApp();
      break;
    case 'repair-import-local':
      state.repair.materials.push({
        id: `mat-local-${Date.now()}`,
        sourceObjId: 'local-new',
        kind: 'local',
        page: 1,
        targetPage: 1,
        label: '本地 · 1页 (补签照片.png)',
        size: '480×320',
      });
      state.repair.needsSync = true;
      renderApp();
      showToast('已导入本地图片至共享素材区');
      break;
    case 'repair-stage-right-img':
      state.repair.materials.push({
        id: `mat-stage-${Date.now()}`,
        sourceObjId: 'staged-right',
        kind: 'staged',
        page: +id,
        targetPage: +id,
        label: `暂存 · ${id}页 (右侧提取图层)`,
        size: '300×150',
      });
      state.repair.needsSync = true;
      renderApp();
      showToast(`已将新单据第 ${id} 页原图暂存至共享区`);
      break;
    case 'repair-copy-missing-page':
      state.repair.newPages = state.repair.oldPages;
      state.repair.needsSync = true;
      renderApp();
      showToast('已将旧单据第 3 页复制到新单据末尾，两侧页数已对齐 (3页)');
      break;
    case 'repair-mirror-page':
      state.repair.oldPages += 1;
      renderApp();
      showToast('已在左侧将旧单据第 1 页复制为镜像页');
      break;
    case 'repair-apply':
      state.repair.needsSync = false;
      state.repair.saved = false;
      renderApp();
      showToast('已应用共享区修改并生成新 PDF 预览，现在可保存到本地');
      break;
    case 'repair-save':
      state.repair.saved = true;
      triggerDownload(`${state.repair.newCaseNo}_修复.pdf`, '%PDF-1.4 Repaired Document', 'application/pdf');
      renderApp();
      break;
    case 'repair-reload':
      state.repair.oldCaseNo = document.getElementById('repair-old-input')?.value.trim() || state.repair.oldCaseNo;
      state.repair.newCaseNo = document.getElementById('repair-new-input')?.value.trim() || state.repair.newCaseNo;
      renderApp();
      showToast('已重新加载新老单据 PDF 及图层快照');
      break;
    case 'toggle-repair-lines':
      state.repair.showConnections = !state.repair.showConnections;
      renderApp();
      break;
    case 'repair-mobile-side':
      state.repair.mobileSide = id;
      renderApp();
      break;

    // 弹层打开与交互
    case 'open-search':
      showSearchDialog();
      break;
    case 'set-query-kind':
      state.query.kind = id;
      state.query.value = id === 'phoneNo' ? '13813809527' : id === 'sysAccept' ? 'JS20261012000000928' : '2026101209250000000219';
      showSearchDialog();
      break;
    case 'set-query-range':
      state.query.range = id === 'range';
      showSearchDialog();
      break;
    case 'query-Quick-months':
      state.query.range = +id > 1;
      state.query.start = +id === 1 ? '2026-10' : +id === 3 ? '2026-08' : '2026-05';
      state.query.end = '2026-10';
      showSearchDialog();
      break;
    case 'apply-history':
      state.query = { ...state.history[+id] };
      showSearchDialog();
      break;
    case 'clear-search-history':
      state.history = [];
      showSearchDialog();
      break;
    case 'execute-search': {
      const v = document.getElementById('modal-query-val')?.value.trim();
      if (v) state.query.value = v;
      state.queryLabel = `${FIELD_LABELS[state.query.kind]} · ${state.query.value} · ${state.query.start}`;
      closeModal();
      renderApp();
      showToast(`查询完成 · 共命中 ${state.works.length} 份关联工单`);
      break;
    }

    case 'open-table-query':
      showTableQueryDialog();
      break;
    case 'select-table-kind':
      state.tableKind = id;
      showTableQueryDialog();
      break;
    case 'toggle-sm4-decrypt':
      state.sm4Decrypted = id === 'decrypt';
      if (id === 'clear') state.sm4Key = '';
      else state.sm4Key = document.getElementById('sm4-key-input')?.value || 'NPL_JS_SM4_KEY16';
      showTableQueryDialog();
      showToast(state.sm4Decrypted ? '已完成会话内 SM4 本地解密' : '已清除密钥并恢复原始密文');
      break;
    case 'run-table-query':
      showToast(`已查询物理表 ${state.tableKind}`);
      showTableQueryDialog();
      break;

    case 'open-pod-logs':
      showPodLogsDialog();
      break;
    case 'set-log-app':
      state.logApp = id;
      state.logBatchDone = false;
      showPodLogsDialog();
      break;
    case 'download-pod-file':
      state.logDownloading = id;
      showPodLogsDialog();
      setTimeout(() => {
        triggerDownload(`${id}`, '2026-11-05 14:35:20.118 [http-nio-18080-exec-4] INFO  c.c.n.LogFileController - chunk download ok\n', 'text/plain;charset=utf-8');
      }, 300);
      break;
    case 'trigger-batch-logs':
      state.logBatchPattern = document.getElementById('batch-log-pattern')?.value || '*.log';
      state.logBatchDone = true;
      showPodLogsDialog();
      showToast('已按通配符过滤全部 Pod 副本并完成批量下载');
      break;
    case 'refresh-pod-logs':
      state.logDownloading = null;
      showPodLogsDialog();
      showToast('已刷新注册中心全部 Pod 副本目录');
      break;

    case 'open-settings':
      showSettingsDialog();
      break;
    case 'select-env-radio':
      state.activeEnvIndex = +id;
      showSettingsDialog();
      break;
    case 'add-demo-env':
      state.environments.push({
        name: `新增自定义环境 #${state.environments.length + 1}`,
        baseUrl: 'https://npl-custom.cmcc.internal:8443/npl-service',
        webUrl: 'https://npl-custom-web.cmcc.internal:8443/npl-web',
      });
      showSettingsDialog();
      break;
    case 'reimport-keystore':
      showToast('已验证并导入 PKCS#8 / JKS 业务签名密钥');
      break;
    case 'check-app-update':
      openModal(
        '发现新版本 v1.7.0 · 应用内自动更新',
        '已通过 GitHub 加速站 (https://ghproxy.net/) 匹配当前平台安装包',
        `
          <div class="kpi-card" style="margin-bottom:12px">
            <small>匹配平台附件 (macOS Universal PKG 安装器)</small>
            <strong class="mono">NPL-Console-v1.7.0-macos-universal.pkg (42.8 MB)</strong>
          </div>
          <p style="font-size:12px;line-height:1.7;color:var(--ink-secondary)">
            更新说明：<br>
            1. 全面升级「澄澈云台」高保真 UI 视觉体系与卡片细节；<br>
            2. 优化单据图片修复三栏流光连线与大尺寸 PDF 内存直载性能；<br>
            3. 支持接口结果表 SM4 批量导出脱敏核对。
          </p>
        `,
        `
          <button class="btn quiet" data-action="open-settings">稍后更新</button>
          <button class="btn primary" data-action="close-modal">${icon('download')} 立即流式下载并拉起安装</button>
        `
      );
      break;
    case 'save-settings':
      closeModal();
      renderApp();
      showToast('连接与多环境设置已安全保存至 ~/.config/npl-maintenance');
      break;

    case 'open-logs':
      showLogsDialog();
      break;
    case 'copy-log-path':
      copyText(`~/Library/Application Support/npl_maintenance/${id}/`, '日志目录路径');
      break;
    case 'open-portal':
      openModal(
        '内置加密门户网页 (WebPage)',
        '链接已通过业务私钥 RSA 解密并在应用内安全容器打开',
        `
          <div style="border:1px solid var(--line);border-radius:var(--r-card);overflow:hidden">
            <div style="padding:8px 14px;background:var(--bg-subtle);border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between">
              <span class="mono" style="font-size:11px">🔒 https://portal.npl-js.cmcc.internal/workbench (已由私钥解密)</span>
              <span class="badge green">内网门户</span>
            </div>
            <div style="padding:28px;text-align:center;background:var(--bg-elevated)">
              <h3 style="margin:0 0 8px">江苏移动无纸化业务内网综合门户</h3>
              <p class="muted" style="font-size:12px">当前处于应用内嵌 WebView 容器 · 支持一键切换内网门户 / 外网门户</p>
            </div>
          </div>
        `,
        `<button class="btn primary" data-action="close-modal">关闭门户视图</button>`
      );
      break;
    case 'open-mobile-more':
      openModal(
        '更多维护工具',
        '手机端快捷操作菜单',
        `
          <div style="display:flex;flex-direction:column;gap:6px">
            <button class="btn" style="justify-content:space-between" data-action="open-search"><span>${icon('search')} 查询工单</span><span>→</span></button>
            <button class="btn" style="justify-content:space-between" data-action="open-table-query"><span>${icon('table')} 五表数据查询 & SM4 解密</span><span>→</span></button>
            <button class="btn" style="justify-content:space-between" data-action="open-pod-logs"><span>${icon('terminal')} 容器日志文件下载</span><span>→</span></button>
            <button class="btn" style="justify-content:space-between" data-action="open-logs"><span>${icon('code')} 接口记录与运行日志</span><span>→</span></button>
            <button class="btn" style="justify-content:space-between" data-action="open-settings"><span>${icon('settings')} 连接与密钥设置</span><span>→</span></button>
          </div>
        `
      );
      break;
  }
});

/* 输入与下拉实时过滤绑定 */
document.addEventListener('input', (e) => {
  const t = e.target;
  if (t.id === 'order-filter-input') {
    state.orderFilter = t.value;
    renderApp();
    const el = document.getElementById('order-filter-input');
    if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
  } else if (t.id === 'field-filter-input') {
    state.fieldFilter = t.value;
    renderApp();
    const el = document.getElementById('field-filter-input');
    if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
  } else if (t.id === 'msg-key-input') {
    state.messageKeyFilter = t.value;
    renderApp();
    const el = document.getElementById('msg-key-input');
    if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
  } else if (t.id === 'msg-val-input') {
    state.messageValFilter = t.value;
    renderApp();
    const el = document.getElementById('msg-val-input');
    if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
  }
});

document.addEventListener('change', (e) => {
  const t = e.target;
  if (t.id === 'pdf-fit-select') {
    state.pdfFit = t.value;
    applyPdfZoom();
  } else if (t.id === 'msg-file-select') {
    state.messageFileIndex = +t.value;
    state.messageFrames = [];
    renderApp();
  } else if (t.id === 'msg-format-select') {
    state.messageFormat = t.value;
    renderApp();
  }
});

/* 全局快捷键：⌘K 打开搜索、\ 折叠顶部风格栏、Esc 退出全屏或关闭弹窗 */
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    showSearchDialog();
  } else if (e.key === '\\' && !['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)) {
    document.body.classList.toggle('studio-collapsed');
    if (state.editorTab) requestAnimationFrame(drawRepairConnections);
  } else if (e.key === 'Escape') {
    if (state.modal) closeModal();
    else if (state.pdfFullscreen) {
      state.pdfFullscreen = false;
      renderApp();
    }
  }
});

/* 初始化首次渲染 */
renderApp();
