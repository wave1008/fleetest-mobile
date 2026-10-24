// グリッドビュー(1台だけ選択したときの拡大表示)の操作パネル: 要素一覧・バウンディングボックス・
// 入力するテキスト・操作記録(ライブ操作タブと同等。インストール・レコーディング・アプリを起動は持たない)。
// gridLiveControls.js(ツールバー・画面の操作)から initGridLivePanel で postAction を受け、
// syncGridLiveControls から syncGridLivePanel、applyGridLiveMessage から applyGridLivePanelMessage が呼ばれる。
// DOM は monitorHtml.ts の #grid-live-panel。1台表示の間は .lane-pair の中の操作カラム(#grid-live-controls)の右隣に置く。
// 入力するテキストの行(#grid-live-type-row)だけは拡大表示の絵のすぐ下に置く(ユーザー決定)。
//
// **選択しただけでは serve へ接続しない(観測を自動で撃たない)** —— ブリッジの自動起動や実行中のテストへの
// 相乗りを避けるため。接続は最初の操作・「更新」・枠のトグル ON(開いた時点で既に ON のときを含む)のときに
// gridLiveAction 経由で起こる。
// 絵はモニター自身の配信なので、host の snapshot の image は使わず screen と elements だけ採る。

import { vscode, persistedState } from './vscodeApi.js';
import { BOXES_SETTLE_CAP_MS, SETTLE_REFRESH_MS } from './liveTab.js';
import {
  clockText, createOplogView, frameToDisplayRect, hitTestRef, renderElementRows,
} from './liveListViews.js';

const OPLOG_MAX_ROWS = 200; // デバイスごとの控えの上限(liveListViews.js の一覧の上限と同じ)

const panel = document.getElementById('grid-live-panel');
const parking = document.getElementById('grid-live-parking');
const refreshBtn = document.getElementById('grid-live-btn-refresh-snapshot');
const boxesToggle = document.getElementById('grid-live-show-boxes');
const elementsList = document.getElementById('grid-live-elements-list');
const elementsEmpty = document.getElementById('grid-live-elements-empty');
const typeInput = document.getElementById('grid-live-type-text');
// 入力欄の行は1台表示の間、拡大表示の絵のすぐ下(.lane-preview-frame の直後)に居る(syncGridLivePanel)。
// 拡大表示のダブルクリック(選択の切り替え。laneLog.js)と右クリック(デバイスのメニュー)へ伝えない ——
// 単語を選ぶダブルクリックで選択が変わり、貼り付けの右クリックでデバイスのメニューが開いてしまう
const typeRow = document.getElementById('grid-live-type-row');
typeRow.addEventListener('dblclick', (event) => event.stopPropagation());
typeRow.addEventListener('contextmenu', (event) => event.stopPropagation());
const oplogList = document.getElementById('grid-live-oplog-list');
const oplogClearBtn = document.getElementById('grid-live-btn-oplog-clear');

const svgNS = 'http://www.w3.org/2000/svg';
const boxesOverlay = document.createElementNS(svgNS, 'svg');
boxesOverlay.setAttribute('class', 'grid-live-boxes-overlay');
boxesOverlay.setAttribute('aria-hidden', 'true');
const hotBox = document.createElementNS(svgNS, 'rect');
hotBox.setAttribute('class', 'hot');
const hoverBox = document.createElement('div');
hoverBox.className = 'grid-live-hover-box';

const oplogView = createOplogView(oplogList, { persistKey: 'gridLiveOplogLabelWidth', defaultLabelWidth: 220 });
const oplogByDevice = new Map(); // id → [{ time, label, ok, mcp }]

// gridLiveControls.js の postAction(送れたら true)と deviceTiles.js の showMirrorStill。initGridLivePanel で受ける
// (ここから deviceTiles.js を import しない = noteMirrorFrame の doc)
let postAction = () => false;
let showStill = () => 'none';
// laneLog.js の isDeviceRunning(同じ理由で gridLiveControls.js から受ける)
let isRunning = () => false;

// 1台表示のデバイス。1台表示でない間は null
let target = null;
// ライブ操作の serve が今つないでいるデバイス(host の devices.selectedId)。snapshot はこれが target と
// 一致するときだけ採る
let liveSelectedId = null;
let busy = false;
let screen = null;
let elements = [];
let showBoxes = persistedState.gridLiveShowBoxes === true;

// 枠の鮮度。**画面を変える操作を送った時点で枠を消し、その操作の直接の結果の snapshot では描かない**
// (まだ遷移・慣性の途中の木で、描くと中間の座標で一度出て止まってからもう一度出る)。
// 根拠: liveTab.js は applySnapshot のたびに SETTLE_REFRESH_MS 後の撮り直しを1回撃つ(scheduleSettleRefresh)
// ので、操作の結果の次には整定後の木が必ず続く —— この依存があるので「次の snapshot」を待てる。
// 尽きたとき: 直接の結果から BOXES_SETTLE_CAP_MS 以内に次が来なければ、手元の最新の木で描く。
// 対象が実行中の間はライブ操作タブが自動の撮り直しを撃たない(liveTab.js の isSelectedDeviceRunning)ので
// 「次の snapshot」は来ず、常にこの打ち切りで描く。
// **「直接の結果」は host の合図(gridActionStarted)の後に届いた最初の snapshot だけ** —— host は撃つ前に
// デバイスの切り替え(開いたときの観測)や直前の処理の終わりを待つので、送った直後に届く snapshot は操作前の画面
// (取り違えると、本物の結果を「整定後」と読んで遷移の途中の位置に枠を一度描く)。
let boxesStale = true;        // true の間は枠を描かない(木を信用していない)
// 画面を変える操作の段: null = 無し / 'posted' = 送った(合図待ち。届く snapshot は操作前の画面)/
// 'started' = 合図を受けた(次の snapshot が直接の結果)
let opPhase = null;

// **枠は、その木と同じ瞬間の絵の上に描く**。木はライブ操作の観測で届くが、拡大表示の絵はモニター自身の配信・
// ポーリングで別経路 —— ブリッジの無いシミュレータのポーリングは1サイクル1台の順繰りで、台数ぶん遅い(実地: M1Max の
// iOS 6台で1台あたり約12秒に1枚。待つ方式では上限が先に切れ、古い絵の上に枠が出た)。そこで観測の一枚絵(snapshot の
// image)を拡大表示に出し(deviceTiles.js の showMirrorStill。以後の配信・ポーリングのフレームが届けば入れ替わる)、
// **その絵の読み込みが終わるまで**(onMirrorFrame → gridLiveControls.js → noteMirrorFrame)枠とホバー枠を描かない。
// 上限[ms]: 一枚絵のデコードは数十 ms なので、load / error が鳴らない異常の保険。尽きたら今の絵の上に描く
const IMAGE_WAIT_CAP_MS = 1000;
let imageWaitTimer = null; // null = 待っていない

function startImageWait() {
  cancelImageWait();
  imageWaitTimer = setTimeout(finishImageWait, IMAGE_WAIT_CAP_MS);
}
function cancelImageWait() {
  if (imageWaitTimer !== null) {
    clearTimeout(imageWaitTimer);
    imageWaitTimer = null;
  }
}
function finishImageWait() {
  if (imageWaitTimer === null) { return; }
  cancelImageWait();
  renderBoxes();
}
function waitingForImage() {
  return imageWaitTimer !== null;
}
/** 拡大表示の絵が描き替わった(gridLiveControls.js が deviceTiles.js の onMirrorFrame から渡す)。
 * **ここから deviceTiles.js を import しない** —— 循環 import の評価順が変わり、別のモジュールの初期化前の値を踏む */
export function noteMirrorFrame(id) {
  if (!target || id !== target.id) { return; }
  // 自分が出した一枚絵の読み込み(待ちの完了)は「絵が変わった」に数えない —— 数えると撮り直しが撮り直しを呼ぶ
  if (waitingForImage()) {
    finishImageWait();
    return;
  }
  notePictureChanged();
}

// **操作と無関係に絵が変わったら、止まってから木を撮り直す**(ライブ操作タブの scheduleSettleRefresh と同じ考え方)。
// OS のダイアログ(位置情報の許可等)・遅れて出る画面は操作の結果と撮り直しより後に出るので、撮り直さないと前の画面の
// 木の枠が新しい絵の上に残る(実地: マップの位置情報の許可で、マップの画面の枠がダイアログの上に出た)。絵が変わった
// 時点で枠は消し(要素一覧は消さない)、SETTLE_REFRESH_MS 新しいフレームが来なければ撮り直す。止まらない絵
// (アニメーション)はライブ操作タブと同じ BOXES_SETTLE_CAP_MS で打ち切って撮る。
// 何もしないとき: 操作の途中(その流れが撮る)・ライブ操作が別のデバイスにつないでいる(接続しない規律)。
// **実行中は枠を消すが撮り直さない**(整定のための自動の撮り直しは撃たない = XCUITest ブリッジをシナリオと取り合わない。
// 実行中は絵がどんどん変わるので、古い木の枠を残すとずれたまま)
let pictureSettleTimer = null;
let pictureMotionSince = null; // 絵が動き始めた時刻(打ち切りの起点)。止まっていれば null

function cancelPictureSettle() {
  if (pictureSettleTimer !== null) {
    clearTimeout(pictureSettleTimer);
    pictureSettleTimer = null;
  }
  pictureMotionSince = null;
}

function notePictureChanged() {
  if (liveSelectedId !== target.id || opPhase !== null || awaitSettled) { return; }
  if (!boxesStale) {
    boxesStale = true;
    clearBoxes();
  }
  if (isRunning(target.id)) { return; }
  if (pictureSettleTimer !== null) { clearTimeout(pictureSettleTimer); }
  const now = performance.now();
  if (pictureMotionSince === null) { pictureMotionSince = now; }
  const delay = now - pictureMotionSince >= BOXES_SETTLE_CAP_MS ? 0 : SETTLE_REFRESH_MS;
  pictureSettleTimer = setTimeout(refreshAfterPictureSettled, delay);
}

function refreshAfterPictureSettled() {
  pictureSettleTimer = null;
  if (!target || liveSelectedId !== target.id || opPhase !== null || isRunning(target.id)) {
    pictureMotionSince = null;
    return;
  }
  if (busy) {
    // 処理中(ライブ操作タブの操作・撮り直し)。終わってから撃つ(その結果の木が先に来れば、ここで撮るのは重複だが害は無い)
    pictureSettleTimer = setTimeout(refreshAfterPictureSettled, SETTLE_REFRESH_MS);
    return;
  }
  pictureMotionSince = null;
  postAction({ type: 'refreshSnapshot' });
}

/** 観測の一枚絵を拡大表示に出す。読み込みを待つなら待ちを始め、既に出ている・出せないなら待たない */
function showSnapshotImage(message) {
  const shown = message.image ? showStill(target.id, message.image, message.capturedAtMs) : 'none';
  if (shown === 'loading') {
    startImageWait();
  } else {
    finishImageWait();
  }
}
let awaitSettled = false;     // 直接の結果を受けた。次の snapshot(整定後)か上限を待っている
let capTimer = null;

let hotRef = null;
const boxByRef = new Map();
let rowByRef = new Map();

boxesToggle.checked = showBoxes;
// トグルはグリッドビューの見出し行(台数の右)に居る。見出し行はどこを押しても開閉するので、トグルのクリックを
// 親へ伝えない(切り替えは change で受ける = label 経由の入力を二重に数えない。streamToggle.js と同じ)。
// 出すのは1台表示の間だけ(syncGridLivePanel)
const boxesToggleLabel = boxesToggle.closest('.grid-view-boxes-toggle');
boxesToggleLabel.addEventListener('click', (event) => event.stopPropagation());

/** gridLiveControls.js が postAction を渡す(循環 import を避けて関数で受ける) */
export function initGridLivePanel(deps) {
  postAction = deps.postAction;
  showStill = deps.showStill;
  isRunning = deps.isRunning;
}

function cancelCap() {
  if (capTimer !== null) {
    clearTimeout(capTimer);
    capTimer = null;
  }
}

/** 木を捨てる。**操作の段(opPhase)は残す** —— 操作の途中でデバイスを切り替えると host は clearSnapshot を
 * 送ってから撃つので、ここで段を消すと開いたときの観測を直接の結果と取り違える。段を捨てるのは対象が変わるとき
 * (discardAll)だけ */
function discardSnapshot() {
  screen = null;
  elements = [];
  cancelImageWait();
  cancelPictureSettle();
  cancelCap();
  awaitSettled = false;
  boxesStale = true;
  clearBoxes();
  renderElements();
}

function discardAll() {
  opPhase = null;
  discardSnapshot();
}

/** 1台表示の拡大表示(previewEl)にこのパネルを付ける。id が null(1台表示でない)なら置き場へ戻して状態を捨てる。 */
/** anchorEl: このパネルを右隣に置く要素(gridLiveControls.js の操作カラム)。無ければ拡大表示の直後 */
export function syncGridLivePanel(id, previewEl, anchorEl = previewEl) {
  if (target && (target.id !== id || target.previewEl !== previewEl)) {
    const changedDevice = target.id !== id;
    detachPreview();
    target = null;
    if (changedDevice || id === null) {
      discardAll();
    }
  }
  if (id === null || !previewEl) {
    if (panel.parentElement !== parking) { parking.appendChild(panel); }
    if (typeRow.parentElement !== parking) { parking.appendChild(typeRow); }
    boxesToggleLabel.hidden = true;
    return;
  }
  boxesToggleLabel.hidden = false;
  if (!target) {
    target = { id, previewEl };
    previewEl.addEventListener('pointermove', handlePreviewMove);
    previewEl.addEventListener('pointerleave', handlePreviewLeave);
    oplogView.replace(oplogByDevice.get(id) ?? []);
    renderElements();
    refreshBusy();
    // **枠のトグルが既に ON なら開いた時点で木を取りに行く**(トグルを ON にしたときと同じ扱い。ON は利用者の
    // 明示の意思 = 選択しただけでは撮らない規律の例外)。撮らないと描く木が無く、ON なのに枠が出ない。
    // 送るのは次のマイクロタスク —— 呼び手(gridLiveControls.js の syncGridLiveControls)はこの関数の後で
    // 自分の target を立てるので、ここで送ると postAction が「1台表示でない」として捨てる
    if (showBoxes && !screen) {
      queueMicrotask(() => {
        if (target && target.id === id && showBoxes && !screen) {
          postAction({ type: 'refreshSnapshot' });
        }
      });
    }
  }
  // laneLog.js の syncLogMirror が組を作り直す(拡大表示を取り出して入れ直す)ので毎回位置を確かめる
  const anchor = anchorEl && anchorEl.parentElement === previewEl.parentElement ? anchorEl : previewEl;
  if (previewEl.parentElement && anchor.nextElementSibling !== panel) {
    anchor.after(panel);
  }
  // 拡大表示は作り直すときに中身を空にする(deviceTiles.js の attachDeviceMirror)ので毎回見る。
  // 入力欄は絵のすぐ下。**ずれているときだけ動かす**(入力中に動かすとフォーカスが外れる)。高さの固定費は
  // 呼び手の後の段組み(laneLog.js の relayoutPreviewGrid → layoutSinglePreview)が実測する
  const frame = previewEl.querySelector('.lane-preview-frame');
  if (frame && frame.nextElementSibling !== typeRow) { frame.after(typeRow); }
  if (boxesOverlay.parentElement !== previewEl) { previewEl.appendChild(boxesOverlay); }
  if (hoverBox.parentElement !== previewEl) { previewEl.appendChild(hoverBox); }
  observeMedia();
  renderBoxes();
}

function detachPreview() {
  target.previewEl.removeEventListener('pointermove', handlePreviewMove);
  target.previewEl.removeEventListener('pointerleave', handlePreviewLeave);
  boxesOverlay.remove();
  hoverBox.remove();
  if (panel.parentElement !== parking) { parking.appendChild(panel); }
  if (typeRow.parentElement !== parking) { parking.appendChild(typeRow); }
}

function refreshBusy() {
  refreshBtn.disabled = busy;
}

/** 画面を変える操作(refreshSnapshot 以外)を送った。gridLiveControls.js の postAction から呼ぶ */
export function noteScreenAction() {
  if (!target) { return; }
  cancelCap();
  cancelImageWait();
  cancelPictureSettle();
  awaitSettled = false;
  opPhase = 'posted';
  boxesStale = true;
  clearBoxes(); // 要素一覧は消さない(読んでいる最中に行が消えると追えない)
}

/** 撃つ前に終わった操作(host が断った・撃たなかった): 画面は変わっていないので手元の木で描き直す */
function abandonPendingOp() {
  opPhase = null;
  if (screen) {
    boxesStale = false;
    renderBoxes();
  }
}

/** host の live メッセージ(gridLiveControls.js の applyGridLiveMessage から) */
export function applyGridLivePanelMessage(message) {
  switch (message.type) {
    case 'devices': {
      const wasSelected = target !== null && liveSelectedId === target.id;
      liveSelectedId = message.selectedId ?? null;
      // 別のデバイスへつなぎ替わった: 前のデバイスの木を持ち越さない
      if (wasSelected && (!target || liveSelectedId !== target.id)) {
        discardSnapshot();
      }
      break;
    }
    case 'clearSnapshot':
      discardSnapshot();
      break;
    case 'snapshot':
      if (target && liveSelectedId === target.id) { adoptSnapshot(message); }
      break;
    case 'busy': {
      const wasBusy = busy;
      busy = !!message.busy;
      refreshBusy();
      // 操作が終わったのに直接の結果が来なかった(失敗): 次の snapshot か上限で描く
      if (wasBusy && !busy && opPhase === 'started') {
        opPhase = null;
        beginSettleWait();
      }
      break;
    }
    case 'gridActionStarted':
      if (target && message.id === target.id && opPhase === 'posted') { opPhase = 'started'; }
      break;
    case 'gridActionError':
      // 撃つ前に断られた(レコーディング中・処理中・開けない)
      if (target && message.id === target.id && opPhase === 'posted') { abandonPendingOp(); }
      break;
    case 'actionError':
      // 撃ち始めてすぐ断られた(画面サイズが無い・空の入力・処理中)= busy を立てずに返った。撃った後の失敗は busy の
      // 間に届くので、ここでは数えない(成功時の空文字の「消す」も busy の間)
      if (message.message && !busy && opPhase === 'started') { abandonPendingOp(); }
      break;
    case 'focusTypeInput':
      if (target && liveSelectedId === target.id) {
        typeInput.focus();
        typeInput.select();
      }
      break;
    case 'operationLog':
      if (typeof message.deviceId === 'string') { recordOperation(message); }
      break;
    default:
      break;
  }
}

function recordOperation(message) {
  const entry = {
    time: clockText(), label: message.label, ok: !!message.ok,
    mcp: typeof message.mcp === 'string' ? message.mcp : '',
  };
  const entries = oplogByDevice.get(message.deviceId) ?? [];
  entries.push(entry);
  if (entries.length > OPLOG_MAX_ROWS) { entries.splice(0, entries.length - OPLOG_MAX_ROWS); }
  oplogByDevice.set(message.deviceId, entries);
  if (target && target.id === message.deviceId) {
    oplogView.append(entry.label, entry.ok, entry.mcp, entry.time);
  }
}

oplogClearBtn.addEventListener('click', () => {
  if (target) { oplogByDevice.delete(target.id); }
  oplogView.clear();
});

// ---- スナップショット ------------------------------------------------------------

function adoptSnapshot(message) {
  screen = message.screen;
  elements = message.elements;
  // 絵は**どの観測でも**出す(操作の直接の結果も = 遅い経路でも絵が先に変わる)。枠を描くのはその絵が出てから
  showSnapshotImage(message);
  if (opPhase === 'started') {
    // 操作の直接の結果: 描かず、次(整定後)の木か上限を待つ
    opPhase = null;
    beginSettleWait();
  } else if (opPhase === 'posted') {
    // 合図より前 = 操作前の画面(開いたときの観測・直前の撮り直し)。一覧は入れ替えるが枠は描かない
    boxesStale = true;
  } else {
    cancelCap();
    awaitSettled = false;
    boxesStale = false;
  }
  renderElements();
}

function beginSettleWait() {
  awaitSettled = true;
  boxesStale = true;
  cancelCap();
  capTimer = setTimeout(() => {
    capTimer = null;
    if (!awaitSettled) { return; }
    awaitSettled = false;
    boxesStale = false;
    renderBoxes();
  }, BOXES_SETTLE_CAP_MS);
}

// ---- 要素一覧 / ホバー / 枠 ------------------------------------------------------

function renderElements() {
  const hasTree = screen !== null;
  elementsEmpty.style.display = hasTree ? 'none' : '';
  elementsList.style.display = hasTree ? '' : 'none';
  setHot(null, false);
  hoverBox.style.display = 'none';
  rowByRef = hasTree
    ? renderElementRows(elementsList, elements, {
      // 枠を出している間は hot(赤)へ一本化 —— 単一枠(青)と重ねると同じ要素に2つ枠が出る
      onEnter: (element) => { if (boxesShown()) { setHot(element.ref, false); } else { showHover(element); } },
      onLeave: () => { if (boxesShown()) { setHot(null, false); } else { hideHover(); } },
    })
    : new Map();
  if (!hasTree) { elementsList.innerHTML = ''; }
  renderBoxes();
}

function boxesShown() {
  return showBoxes && !boxesStale && !waitingForImage();
}

function mediaEl() {
  return target ? target.previewEl.querySelector('.lane-preview-media') : null;
}

// 枠の SVG を絵の矩形にぴったり重ねる(gridLiveControls.js の placeOverlay と同じ求め方。.lane-preview の padding box 基準)。
// 返すのは絵の表示サイズ。測れない(非表示・絵が無い)ときは null
function placeOverlay() {
  const media = mediaEl();
  if (!media) { return null; }
  const host = target.previewEl;
  const mediaRect = media.getBoundingClientRect();
  if (!(mediaRect.width > 0) || !(mediaRect.height > 0)) { return null; }
  const hostRect = host.getBoundingClientRect();
  const left = mediaRect.left - hostRect.left - host.clientLeft;
  const top = mediaRect.top - hostRect.top - host.clientTop;
  boxesOverlay.style.left = left + 'px';
  boxesOverlay.style.top = top + 'px';
  boxesOverlay.style.width = mediaRect.width + 'px';
  boxesOverlay.style.height = mediaRect.height + 'px';
  boxesOverlay.setAttribute('viewBox', `0 0 ${mediaRect.width} ${mediaRect.height}`);
  return { width: mediaRect.width, height: mediaRect.height, left, top };
}

function clearBoxes() {
  setHot(null, false);
  boxByRef.clear();
  hotBox.remove();
  boxesOverlay.classList.remove('visible');
  boxesOverlay.replaceChildren();
  elementsList.classList.remove('boxes-on');
}

function renderBoxes() {
  // 行の見た目(赤枠を出すか)は CSS(.boxes-on)。枠が実際に出ているかと一致させる
  elementsList.classList.toggle('boxes-on', boxesShown());
  if (boxesStale) { return; } // 消した後は次の木を待つ(サイズ変化からの引き直しで古い枠を蘇らせない)
  if (waitingForImage()) { return; } // 絵がまだ前の画面(枠は操作の時点で消してある)
  boxByRef.clear();
  hotBox.remove();
  if (!showBoxes || !screen || elements.length === 0 || !target) {
    boxesOverlay.classList.remove('visible');
    boxesOverlay.replaceChildren();
    return;
  }
  const display = placeOverlay();
  if (!display) { return; }
  const shapes = elements.map((element) => {
    const box = frameToDisplayRect(element.frame, screen, display);
    const node = document.createElementNS(svgNS, 'rect');
    node.setAttribute('x', box.x);
    node.setAttribute('y', box.y);
    node.setAttribute('width', Math.max(box.width, 1));
    node.setAttribute('height', Math.max(box.height, 1));
    boxByRef.set(element.ref, node);
    return node;
  });
  boxesOverlay.replaceChildren(...shapes);
  boxesOverlay.classList.add('visible');
  applyHot();
}

function applyHot() {
  hotBox.remove();
  if (hotRef === null) { return; }
  rowByRef.get(hotRef)?.classList.add('hot');
  const source = boxByRef.get(hotRef);
  if (!source) { return; } // 枠を出していないときは行だけ光る
  for (const attribute of ['x', 'y', 'width', 'height']) {
    hotBox.setAttribute(attribute, source.getAttribute(attribute));
  }
  boxesOverlay.appendChild(hotBox); // 最後に足す = 最前面
}

/** scrollList: 一覧を送ってよいか。絵の側で指したときだけ true(行を直接ホバーしている最中に送ると
 * カーソルの下で一覧が動く)。'nearest' = 既に見えていれば動かさない */
function setHot(ref, scrollList) {
  if (ref === hotRef) { return; }
  if (hotRef !== null) { rowByRef.get(hotRef)?.classList.remove('hot'); }
  hotRef = ref;
  applyHot();
  if (ref !== null && scrollList) {
    rowByRef.get(ref)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
}

function showHover(element) {
  if (waitingForImage()) { return; } // 新しい木の位置を古い絵の上に出さない
  const display = placeOverlay();
  if (!screen || !display) { return; }
  const box = frameToDisplayRect(element.frame, screen, display);
  hoverBox.style.left = (display.left + box.x) + 'px';
  hoverBox.style.top = (display.top + box.y) + 'px';
  hoverBox.style.width = box.width + 'px';
  hoverBox.style.height = box.height + 'px';
  hoverBox.style.display = 'block';
}

function hideHover() {
  hoverBox.style.display = 'none';
}

// 絵の上のホバー = その点の要素(枠と一覧の行を対で光らせる)。枠自身には当てない
// (オーバーレイは pointer-events なし = 絵への操作を吸わない)ので、ここで当たり判定する。
// 枠が OFF でも行は光らせる。違うのは赤枠(CSS の .boxes-on)と一覧送りだけ。
function handlePreviewMove(event) {
  const media = event.target instanceof Element ? event.target.closest('.lane-preview-media') : null;
  if (!media || !screen) {
    setHot(null, false);
    return;
  }
  const rect = media.getBoundingClientRect();
  setHot(hitTestRef(elements, screen, event.clientX - rect.left, event.clientY - rect.top,
    { width: rect.width, height: rect.height }), showBoxes);
}

function handlePreviewLeave() {
  setHot(null, false);
}

let resizeObserver = null;
let observedMedia = null;
function observeMedia() {
  if (typeof ResizeObserver === 'undefined') { return; }
  if (!resizeObserver) { resizeObserver = new ResizeObserver(() => renderBoxes()); }
  const media = mediaEl();
  if (media && media !== observedMedia) {
    if (observedMedia) { resizeObserver.unobserve(observedMedia); }
    resizeObserver.observe(media);
    observedMedia = media;
  }
}
window.addEventListener('resize', () => renderBoxes());

// ---- 操作 ------------------------------------------------------------------------

refreshBtn.addEventListener('click', () => { postAction({ type: 'refreshSnapshot' }); });

boxesToggle.addEventListener('change', () => {
  showBoxes = boxesToggle.checked;
  vscode.setState(Object.assign({}, vscode.getState(), { gridLiveShowBoxes: showBoxes }));
  // ホバー中に切り替えると行ホバーの出し先(単一枠 ⇄ hot)が入れ替わる。両方畳んでから引き直す
  setHot(null, false);
  hideHover();
  // 木が無い/古い(信用していない)ときは撮り直して、届いたら描く。直接の結果・整定を待っている最中は
  // その経路が描くので足さない
  if (showBoxes && opPhase === null && !awaitSettled && (boxesStale || !screen)) {
    postAction({ type: 'refreshSnapshot' });
  }
  renderBoxes();
});

// テキスト送信は Enter のみ。IME 変換中(日本語変換の確定)の Enter は送らない: isComposing が true、
// 環境により keyDown が keyCode 229 で届くため両方除外する。busy 中も送らない(多重送信を防ぐ)
typeInput.addEventListener('keydown', (event) => {
  if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229) { return; }
  if (busy) { return; }
  event.preventDefault();
  if (postAction({ type: 'typeText', text: typeInput.value })) {
    typeInput.value = '';
  }
});
