// ライブ操作タブ(liveTab.js)とグリッドビューの操作パネル(gridLivePanel.js)が共有する、
// 当たり判定・要素一覧の行・操作記録の描画。DOM の id は持たず、呼び出し側が渡す要素に描く。

import { t } from '../i18n.js';
import { vscode, persistedState } from './vscodeApi.js';

// liveModel.ts の frameToDisplayRect と同じ計算(webview は CSP により import 不可のため複製。
// liveModel.ts 側を変更したらここも追随させること)。
export function frameToDisplayRect(frame, screen, display) {
  if (screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scaleX = display.width / screen.width;
  const scaleY = display.height / screen.height;
  return {
    x: frame.x * scaleX, y: frame.y * scaleY,
    width: frame.width * scaleX, height: frame.height * scaleY,
  };
}

// liveModel.ts の pointFromClick / hitTestElement と同じ規則(同上の理由で複製。liveModel.ts 側を
// 変更したらここも追随させること)。返すのは ref だけで足りる。
export function hitTestRef(elements, screen, clickX, clickY, display) {
  if (!screen || display.width <= 0 || display.height <= 0) { return null; }
  const x = Math.min(Math.max((clickX / display.width) * screen.width, 0), screen.width);
  const y = Math.min(Math.max((clickY / display.height) * screen.height, 0), screen.height);
  let best = null;
  let bestArea = Infinity;
  for (const element of elements) {
    const f = element.frame;
    if (x < f.x || x > f.x + f.width || y < f.y || y > f.y + f.height) { continue; }
    const area = f.width * f.height; // 重なりの中で最も具体的なもの = 面積最小
    if (area < bestArea) { bestArea = area; best = element.ref; }
  }
  return best;
}

/** 要素一覧の行を listEl に作り直し、ref → 行 の Map を返す。
 * 2カラム(矩形 | 本文)。列幅は .elements-list 側が決め、行は subgrid で乗る
 * = 矩形の幅が全行で揃い、本文の開始位置も揃う(liveModel.ts の frameText / line と対)。
 * **行のクリックでは何もしない** —— 一覧は読むためのもので、触れたつもりのないタップが
 * デバイスへ飛ばないようにする。onEnter / onLeave(element) はホバーの枠出しに使う。 */
export function renderElementRows(listEl, elements, { onEnter, onLeave }) {
  const rowByRef = new Map();
  listEl.innerHTML = '';
  for (const element of elements) {
    const row = document.createElement('div');
    row.className = 'element-row';
    const frameCell = document.createElement('span');
    frameCell.className = 'element-cell-frame';
    frameCell.textContent = element.frameText;
    const main = document.createElement('span');
    main.className = 'element-cell-main';
    main.textContent = element.line;
    row.append(frameCell, main);
    row.addEventListener('mouseenter', () => onEnter(element));
    row.addEventListener('mouseleave', () => onLeave(element));
    rowByRef.set(element.ref, row);
    listEl.appendChild(row);
  }
  return rowByRef;
}

const OPLOG_MAX_ROWS = 200; // DOM/メモリ肥大防止。超えたら最古行から捨てる
const MIN_OPLOG_LABEL_WIDTH = 60; // px。操作列を潰し切らない下限
function pad2(n) { return n < 10 ? '0' + n : '' + n; }
/** 操作記録の時刻列('HH:MM:SS') */
export function clockText(now = new Date()) {
  return pad2(now.getHours()) + ':' + pad2(now.getMinutes()) + ':' + pad2(now.getSeconds());
}

/** 操作記録(host の operationLog を追記)を listEl に描く。
 * 行は「時刻 / 操作 / MCP のコマンド」の3列(grid は CSS の .oplog-row / .oplog-head)。MCP 列は同じ操作を
 * ft_* で撃つ形(host の mcpCommandForServeCommand)で、**クリックでコピー**する(貼って使うもの)。
 * テスト実行由来の行には無い(空のまま = 列は揃える)。
 * **一覧は左右にもスクロールする**(MCP 列は省略しない = 行の幅は中身で決まり、.oplog-list が overflow:auto)。
 * 操作列の幅は見出し行(.oplog-head)の境目をドラッグして変える(--oplog-label-width)。
 * persistKey: 幅を vscode.setState に保存するキー。defaultLabelWidth: CSS の --oplog-label-width の既定と揃えること。
 * 見出し行は一覧の中に置く(外に置くと横スクロールで列がずれる)。clear / replace・行数の上限では消さない。 */
export function createOplogView(listEl, { persistKey, defaultLabelWidth }) {
  let labelWidth =
    typeof persistedState[persistKey] === 'number' && persistedState[persistKey] >= MIN_OPLOG_LABEL_WIDTH
      ? persistedState[persistKey]
      : defaultLabelWidth;
  function applyLabelWidth(width) {
    labelWidth = Math.max(MIN_OPLOG_LABEL_WIDTH, Math.round(width));
    listEl.style.setProperty('--oplog-label-width', labelWidth + 'px');
  }
  const head = document.createElement('div');
  head.className = 'oplog-head';
  const timeHead = document.createElement('span');
  timeHead.className = 'oplog-time';
  const labelHead = document.createElement('span');
  labelHead.className = 'oplog-label';
  labelHead.textContent = t('wvMonitor.live.oplogColOperation');
  const resizer = document.createElement('span');
  resizer.className = 'oplog-col-resizer';
  resizer.title = t('wvMonitor.live.oplogColResize');
  labelHead.appendChild(resizer);
  const mcpHead = document.createElement('span');
  mcpHead.className = 'oplog-mcp';
  mcpHead.textContent = t('wvMonitor.live.oplogColMcp');
  head.append(timeHead, labelHead, mcpHead);
  let resizePointerId = null;
  let resizeStartX = 0;
  let resizeStartWidth = 0;
  resizer.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) { return; }
    resizePointerId = event.pointerId;
    resizeStartX = event.clientX;
    resizeStartWidth = labelWidth;
    resizer.setPointerCapture(event.pointerId);
    resizer.classList.add('dragging');
    event.preventDefault();
  });
  resizer.addEventListener('pointermove', (event) => {
    if (resizePointerId !== event.pointerId) { return; }
    applyLabelWidth(resizeStartWidth + (event.clientX - resizeStartX));
  });
  const endResize = (event) => {
    if (resizePointerId !== event.pointerId) { return; }
    resizePointerId = null;
    resizer.classList.remove('dragging');
    resizer.releasePointerCapture(event.pointerId);
    vscode.setState(Object.assign({}, vscode.getState(), { [persistKey]: labelWidth }));
  };
  resizer.addEventListener('pointerup', endResize);
  resizer.addEventListener('pointercancel', endResize);
  listEl.appendChild(head);
  applyLabelWidth(labelWidth);

  function makeRow(label, ok, mcp, time) {
    const row = document.createElement('div');
    row.className = ok ? 'oplog-row' : 'oplog-row failed';
    const timeEl = document.createElement('span');
    timeEl.className = 'oplog-time';
    timeEl.textContent = time ?? clockText();
    const text = document.createElement('span');
    text.className = 'oplog-label';
    text.textContent = (ok ? '' : '✗ ') + label;
    const command = document.createElement('span');
    command.className = 'oplog-mcp';
    if (mcp) {
      command.textContent = mcp;
      command.title = mcp + '\n' + t('wvMonitor.live.oplogMcpCopy');
      command.addEventListener('click', () => { vscode.postMessage({ type: 'copyText', text: mcp }); });
    }
    row.append(timeEl, text, command);
    return row;
  }
  function trim() {
    // 見出し行(.oplog-head)は数えない・消さない
    const rows = listEl.querySelectorAll('.oplog-row');
    for (let i = 0; i < rows.length - OPLOG_MAX_ROWS; i++) {
      rows[i].remove();
    }
  }
  function clear() {
    for (const row of listEl.querySelectorAll('.oplog-row')) { row.remove(); }
  }
  return {
    /** time: 'HH:MM:SS'。省略時は今 */
    append(label, ok, mcp, time) {
      listEl.appendChild(makeRow(label, ok, mcp, time));
      trim();
      listEl.scrollTop = listEl.scrollHeight; // 最新行を見せる
    },
    clear,
    /** entries: [{ time, label, ok, mcp }]。呼び出し側が持つ控えで一覧を差し替える */
    replace(entries) {
      clear();
      for (const e of entries) { listEl.appendChild(makeRow(e.label, e.ok, e.mcp, e.time)); }
      trim();
      listEl.scrollTop = listEl.scrollHeight;
    },
  };
}
