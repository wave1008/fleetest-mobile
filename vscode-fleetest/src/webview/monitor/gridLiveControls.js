// グリッドビュー(1台だけ選択したときの拡大表示)のライブ操作: ツールバー(ホーム・タスク切替・拡大・縮小・
// 折りたたみ機なら折りたたむ・開く)と
// 画面の操作(クリック = タップ / Option+クリック = ダブルタップ / 500ms 以上ホールド = 長押し /
// ドラッグ = スワイプ / Shift+ドラッグ = 軌跡)。ライブ操作タブと同じ。送り先は host の
// MonitorLiveController.handleGridAction(ライブ操作タブと同じ serve。選択中のデバイスが違えば切り替える)。
// 契約: monitorWebviewMessages.ts の gridLiveAction / liveModel.ts の GridLiveAction・gridActionError。
// ツールバーの DOM は monitorHtml.ts(#grid-live-controls。文言は host 側 t() 済み)が持ち、ここで
// 1台表示の .lane-pair の中、拡大表示の右隣へ縦のカラムとして移す(laneLog.js の updateLaneVisibility が
// syncGridLiveControls を呼ぶ)。
// 画面(絵)の上のダブルクリックは2回のタップで、「このデバイスのみ選択」の切り替えは絵の外側だけ
// (laneLog.js が isGridLiveScreenTarget で除く)。
// 要素一覧・枠・入力するテキスト・操作記録のパネルは gridLivePanel.js(ここから postAction を渡す)。
// **テスト実行中でも操作を止めない**(ユーザー決定: 介入は利用者の自己責任)。run が使用中のデバイスへの操作は
// serve が台帳へ残し、そのシナリオの結果に「人の操作」として載る(HumanOperationLedger)。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { thinTracePoints } from './traceThinning.js';
import { setHoverTip } from './hoverTip.js';
import { exitSingleSelection, liveRemoteTargetFor, onMirrorFrame, showMirrorStill } from './deviceTiles.js';
import { DRAG_MIN_PX, LONG_PRESS_MS, TRACE_MAX_MS } from './liveTab.js';
import { isDeviceRunning, relayoutPreviewsForResize } from './laneLog.js';
import { bindFoldButtons } from './foldButtons.js';
import { applyGridLivePanelMessage, initGridLivePanel, noteMirrorFrame, noteScreenAction, syncGridLivePanel } from './gridLivePanel.js';

const parking = document.getElementById('grid-live-parking');
const controls = document.getElementById('grid-live-controls');
const errorEl = document.getElementById('grid-live-error');
const traceIndicator = document.getElementById('grid-live-trace-indicator');
// 「戻る」は選択を変えるだけでデバイスを触らないので busy の対象にしない
const buttons = [...controls.querySelectorAll('button')].filter((button) => button.id !== 'grid-live-btn-back');

const svgNS = 'http://www.w3.org/2000/svg';
const dragOverlay = document.createElementNS(svgNS, 'svg');
dragOverlay.setAttribute('class', 'grid-live-drag-overlay');
dragOverlay.setAttribute('aria-hidden', 'true');
const dragTrace = document.createElementNS(svgNS, 'polyline');
const dragStartDot = document.createElementNS(svgNS, 'circle');
dragStartDot.setAttribute('r', '6');
const dragLine = document.createElementNS(svgNS, 'line');
dragOverlay.append(dragLine, dragTrace, dragStartDot);

// 操作の対象(1台表示のデバイス)。1台表示でない間は null
let target = null;
// ライブ操作が今つないでいるデバイス(host の devices.selectedId)。actionError はこれが target と
// 一致するときだけ出す(ライブ操作タブで別のデバイスを操作した失敗をここに出さない)
let liveSelectedId = null;
let busy = false;
// busy の原因が画面を変えない観測か(host の busy.observing)。この間の画面の操作・ボタンは受け付ける
// (host が観測の終わりを待って撃つ)。捨てると、撮り直しの窓に押したタップが黙って空振りしていた
let busyObserving = false;
function operationBlocked() {
  return busy && !busyObserving;
}
let dragStart = null;
function applyButtonState() {
  for (const button of buttons) { button.disabled = operationBlocked(); }
}

// 拡大表示の絵の描き替わりをパネルへ渡す購読(gridLivePanel.js の waitingForImage)。**読み込み時に購読しない** ——
// このモジュールは deviceTiles.js の読み込みの途中で評価される(deviceTiles → laneLog → ここ)ので、その時点では
// 購読者の集合がまだ無い。最初の1台表示(実行時)で張る
let mirrorFrameSubscribed = false;

/** id: 1台表示のデバイス(1台表示でなければ null)。previewEl: その拡大表示の .lane-preview */
export function syncGridLiveControls(id, previewEl) {
  if (!mirrorFrameSubscribed && id !== null) {
    mirrorFrameSubscribed = true;
    onMirrorFrame(noteMirrorFrame);
  }
  if (target && (target.id !== id || target.previewEl !== previewEl)) {
    releaseTraceOverlay();
    cancelDrag();
    target.previewEl.removeEventListener('pointerdown', handlePointerDown);
    parking.appendChild(controls);
    dragOverlay.remove();
    target = null;
    showError('');
    refreshFoldButtons();
  }
  if (id === null || !previewEl) {
    syncGridLivePanel(null, null);
    return;
  }
  if (!target) {
    target = { id, previewEl };
    previewEl.addEventListener('pointerdown', handlePointerDown);
    refreshFoldButtons();
  }
  // 操作のカラムは .lane-pair の中で拡大表示の右隣(拡大表示 | 操作 | 操作パネル | 実行ログ)。laneLog.js の
  // syncLogMirror が組を作り直す(拡大表示を取り出して入れ直す)ので毎回位置を確かめる。**ずれているときだけ動かす**
  // (毎周動かすとマウスを載せたボタンのツールチップが点滅する)
  if (previewEl.parentElement && previewEl.nextElementSibling !== controls) {
    previewEl.after(controls);
  }
  // パネルはこのカラムの右隣(先にカラムを置いてから並べる = 2つが互いを押しのけて毎周入れ替わらない)
  syncGridLivePanel(id, previewEl, controls);
  // 拡大表示は作り直すときに中身を空にする(deviceTiles.js の attachDeviceMirror)ので毎回見る
  if (dragOverlay.parentElement !== previewEl) {
    previewEl.appendChild(dragOverlay);
  }
}

/** el が1台表示の絵(操作を受ける画面)の中か。laneLog.js のダブルクリック(選択の切り替え)が除くのに使う */
export function isGridLiveScreenTarget(el) {
  return !!target && el instanceof Element && target.previewEl.contains(el) && !!el.closest('.lane-preview-media');
}

/** host からの live メッセージ(main.js が liveTab.js と両方へ配る)。 */
export function applyGridLiveMessage(message) {
  applyGridLivePanelMessage(message);
  switch (message.type) {
    case 'devices':
      liveSelectedId = message.selectedId ?? null;
      break;
    case 'busy':
      busy = !!message.busy;
      busyObserving = busy && !!message.observing;
      applyButtonState();
      if (traceHold !== null) {
        if (busy && !busyObserving) {
          traceHold.sawBusy = true; // 軌跡の実行が始まった
        } else if (!busy && traceHold.sawBusy) {
          releaseTraceOverlay(); // なぞり終えた
        }
      }
      break;
    case 'actionError':
      if (target && liveSelectedId === target.id) {
        showError(message.message || '', !!message.neutral);
      }
      // busy を立てずに返った失敗 = 撃つ前に断られた(撃った後の失敗は busy の間に届く)
      if (message.message && !busy) { releaseTraceOverlay(); }
      break;
    case 'gridActionError':
      if (target && message.id === target.id) {
        releaseTraceOverlay();
        showError(message.message);
      }
      break;
  }
}

function showError(text, neutral = false) {
  if (errorEl.textContent === text && errorEl.classList.contains('neutral') === neutral) {
    return;
  }
  errorEl.textContent = text;
  errorEl.classList.toggle('neutral', neutral);
  // 行の出し入れで拡大表示の固定費(高さ)が変わる
  relayoutPreviewsForResize();
}

/** 送れたら true(操作の最中・1台表示でないときは送らない。観測の最中は送る = operationBlocked) */
function postAction(action) {
  if (!target || operationBlocked()) {
    return false;
  }
  showError('');
  const remote = liveRemoteTargetFor(target.id);
  vscode.postMessage({ type: 'gridLiveAction', id: target.id, action, ...(remote ? { remote } : {}) });
  // 「更新」以外は画面を変える操作 = パネルの枠を消す(gridLivePanel.js の枠の鮮度)
  if (action.type !== 'refreshSnapshot') { noteScreenAction(); }
  return true;
}
initGridLivePanel({ postAction, showStill: showMirrorStill, isRunning: isDeviceRunning });

document.getElementById('grid-live-btn-back').addEventListener('click', () => exitSingleSelection());
document.getElementById('grid-live-btn-home').addEventListener('click', () => postAction({ type: 'home' }));
document.getElementById('grid-live-btn-app-switcher').addEventListener('click', () => postAction({ type: 'appSwitcher' }));
document.getElementById('grid-live-btn-zoom-in').addEventListener('click', () => postAction({ type: 'pinch', zoomIn: true }));
document.getElementById('grid-live-btn-zoom-out').addEventListener('click', () => postAction({ type: 'pinch', zoomIn: false }));
const refreshFoldButtons = bindFoldButtons(
  buttons.filter((button) => button.dataset.fold),
  () => target?.id ?? null,
  (state) => postAction({ type: 'fold', state }),
);
// ボタンの押下を拡大表示のダブルクリック(選択の切り替え)へ伝えない
controls.addEventListener('dblclick', (event) => event.stopPropagation());

// 軌跡の表示灯: Shift を押している間だけ点ける(liveTab.js の setTraceIndicator と同じ)
setHoverTip(traceIndicator, traceIndicator.title);
function setTraceIndicator(on) {
  traceIndicator.classList.toggle('active', !!on);
}
window.addEventListener('keydown', (event) => { if (event.key === 'Shift') { setTraceIndicator(true); } });
window.addEventListener('keyup', (event) => { if (event.key === 'Shift') { setTraceIndicator(false); } });
window.addEventListener('blur', () => setTraceIndicator(false));

function clampToRect(event, rect) {
  return {
    x: Math.min(Math.max(event.clientX - rect.left, 0), rect.width),
    y: Math.min(Math.max(event.clientY - rect.top, 0), rect.height),
  };
}

function handlePointerDown(event) {
  if (event.button !== 0 || !target) {
    return;
  }
  const media = event.target instanceof Element ? event.target.closest('.lane-preview-media') : null;
  if (!media) {
    return;
  }
  // 絵の上の押下は操作として扱う(テキスト選択を始めない)
  event.preventDefault();
  event.stopPropagation();
  if (operationBlocked()) {
    return;
  }
  const rect = media.getBoundingClientRect();
  if (!(rect.width > 0) || !(rect.height > 0)) {
    return;
  }
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  // **押した時点の修飾キーを採る**(liveTab.js の handleScreenPointerDown と同じ理由)
  releaseTraceOverlay(); // 前の軌跡の線は、次のドラッグで消す
  dragStart = {
    id: target.id, media, pointerId: event.pointerId, downAt: performance.now(), x, y,
    doubleTap: event.altKey, trace: event.shiftKey, moveAt: null,
    points: [{ x, y, t: 0 }],
  };
  // 構成中のジェスチャを見せる(デバイス側のスワイプは離したときに1回で実行される。liveTab.js の drag-overlay と同じ)
  placeOverlay(rect);
  updateOverlay(x, y);
}

// 軌跡の SVG を絵の矩形にぴったり重ねる(.lane-preview の padding box 基準)
function placeOverlay(mediaRect) {
  const host = target.previewEl;
  const hostRect = host.getBoundingClientRect();
  dragOverlay.style.left = (mediaRect.left - hostRect.left - host.clientLeft) + 'px';
  dragOverlay.style.top = (mediaRect.top - hostRect.top - host.clientTop) + 'px';
  dragOverlay.style.width = mediaRect.width + 'px';
  dragOverlay.style.height = mediaRect.height + 'px';
  dragOverlay.setAttribute('viewBox', `0 0 ${mediaRect.width} ${mediaRect.height}`);
}

// 軌跡モードは送る中身(指の軌跡)をそのまま描く。直線を描くと送るものと見えるものが食い違う
function updateOverlay(x, y) {
  dragStartDot.setAttribute('cx', dragStart.x);
  dragStartDot.setAttribute('cy', dragStart.y);
  dragLine.setAttribute('x1', dragStart.x);
  dragLine.setAttribute('y1', dragStart.y);
  dragLine.setAttribute('x2', x);
  dragLine.setAttribute('y2', y);
  dragOverlay.classList.toggle('trace', dragStart.trace);
  if (dragStart.trace) {
    dragTrace.setAttribute('points', dragStart.points.map((p) => p.x + ',' + p.y).concat([x + ',' + y]).join(' '));
  }
  dragOverlay.classList.add('visible');
}

function cancelDrag() {
  dragStart = null;
  if (traceHold === null) { dragOverlay.classList.remove('visible'); }
}

// **軌跡は離した後も、デバイスがなぞり終えるまで線を残す**(ユーザー決定)—— デバイスは描いた時間ぶんかけて同じ軌跡を
// 再生するので、離した瞬間に消すと何をなぞっているのか分からない。消すのは: その操作の busy(observing なし)が立って
// 解けたとき・撃つ前に断られたとき(gridActionError / busy の外の actionError)・次のドラッグ・対象の変更。
// 上限[ms]: 終わりの知らせが来ない異常の保険 = 軌跡の長さ + host の待ち(切り替え・観測の終わり = SERVE_REQUEST_TIMEOUT_MS
// 20 秒)+ serve の応答待ち(同 20 秒)
const TRACE_HOLD_MARGIN_MS = 40000;
let traceHold = null; // { timer, sawBusy } = 実行の終わりを待って線を残している

function holdTraceOverlay(durationMs) {
  releaseTraceOverlay();
  traceHold = { sawBusy: false, timer: setTimeout(releaseTraceOverlay, durationMs + TRACE_HOLD_MARGIN_MS) };
}
function releaseTraceOverlay() {
  if (traceHold === null) { return; }
  clearTimeout(traceHold.timer);
  traceHold = null;
  if (dragStart === null) { dragOverlay.classList.remove('visible'); }
}

window.addEventListener('pointermove', (event) => {
  setTraceIndicator(event.shiftKey);
  if (!dragStart || event.pointerId !== dragStart.pointerId) {
    return;
  }
  const rect = dragStart.media.getBoundingClientRect();
  const { x, y } = clampToRect(event, rect);
  if (dragStart.moveAt === null && Math.hypot(x - dragStart.x, y - dragStart.y) >= DRAG_MIN_PX) {
    dragStart.moveAt = performance.now();
  }
  if (!dragStart.trace) {
    updateOverlay(x, y);
    return;
  }
  const elapsed = performance.now() - dragStart.downAt;
  if (elapsed > TRACE_MAX_MS && dragStart.moveAt !== null) {
    // なぞっている最中に上限を超えたら中止して言う(離すまで気付けないと操作が無駄になる)
    cancelDrag();
    showError(t('wvMonitor.live.traceTooLong', { max: TRACE_MAX_MS / 1000 }));
    return;
  }
  dragStart.points.push({ x, y, t: Math.round(elapsed) });
  updateOverlay(x, y);
});

window.addEventListener('pointerup', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) {
    return;
  }
  const start = dragStart;
  cancelDrag();
  if (!target || target.id !== start.id) {
    return;
  }
  const rect = start.media.getBoundingClientRect();
  const { x, y } = clampToRect(event, rect);
  const display = { displayWidth: rect.width, displayHeight: rect.height };
  const upAt = performance.now();
  if (Math.hypot(x - start.x, y - start.y) < DRAG_MIN_PX) {
    // 動かさずに離した: Option ならダブルタップ、LONG_PRESS_MS 以上押していれば長押し、それ以外はタップ
    // (Shift だけのクリックもタップ = ライブ操作タブと同じ)
    const holdMs = Math.max(0, Math.round(upAt - start.downAt));
    if (start.doubleTap) {
      postAction({ type: 'doubleTapPoint', clickX: x, clickY: y, ...display });
    } else if (holdMs >= LONG_PRESS_MS) {
      postAction({ type: 'pressPoint', clickX: x, clickY: y, ...display, holdMs });
    } else {
      postAction({ type: 'tapPoint', clickX: x, clickY: y, ...display });
    }
  } else if (start.trace) {
    const endT = Math.max(1, Math.round(upAt - start.downAt));
    const points = start.points.concat([{ x, y, t: endT }]);
    if (postAction({ type: 'tracePoints', points: thinTracePoints(points), ...display })) {
      // 描いた軌跡をそのまま残す(holdTraceOverlay の doc)
      dragTrace.setAttribute('points', points.map((p) => p.x + ',' + p.y).join(' '));
      dragOverlay.classList.add('trace', 'visible');
      holdTraceOverlay(endT);
    }
  } else {
    const moveAt = start.moveAt ?? upAt;
    postAction({
      type: 'dragPoints',
      fromX: start.x, fromY: start.y, toX: x, toY: y, ...display,
      pressMs: Math.max(0, Math.round(moveAt - start.downAt)),
      dragMs: Math.max(1, Math.round(upAt - moveAt)),
    });
  }
});

window.addEventListener('pointercancel', () => cancelDrag());
