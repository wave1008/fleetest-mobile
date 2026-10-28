// lanesの読み書きはこのモジュールに閉じる。deviceTiles.jsとはselectedDeviceIds/tiles/
// runningWorkers(いずれも再代入されないMap/Set)を介して相互参照する。
//
// レーンは2枚の DOM を持つ: el(実行ログ。常に #lanes-grid の直接の子) / previewEl(拡大表示。
// 選択中かつタイルがあるときだけ #preview-grid に置く)。**1台だけ選択のときだけ**、
// previewEl を .lane-pair で包んで #preview-grid に置く(gridLiveControls.js の操作カラムと
// gridLivePanel.js の操作パネルが、この中で拡大表示の右隣に並ぶ)。ログは複製しない = el は常に
// #lanes-grid 側にあり、1台選択でも実行ログビューのレーンで読む。

import { MAX_LANE_LINES, OVERALL_LANE_ID, overallLaneName, workerDisplayLabel } from "../../runLaneModel";
import { lanesGrid, previewGrid, gridViewTitle, lanesSelectionStatus, lanesRunStatus, logPane, outputPane, devicesPanel } from './domRefs.js';
import { tiles, selectedDeviceIds, attachDeviceMirror, detachDeviceMirror, openDeviceOpMenuForDevice, openSelectAllOnlyMenu, toggleSelectOnlyDevice } from './deviceTiles.js';
import { t } from '../i18n.js';
import { setHoverTip } from './hoverTip.js';
import { computePreviewGrid, computeSinglePreviewWidth } from './previewGridModel.js';
import { paintMachineBadge } from './machineColors.js';
import { isGridLiveScreenTarget, syncGridLiveControls } from './gridLiveControls.js';

// レーン id(worker id、または OVERALL_LANE_ID) -> DOM 要素・自動スクロール状態
const lanes = new Map();

// devices同期(タイルと同じ配列)のid順。レーンの列順は常にこれに合わせる。
// lanesConfigured(workersReady)はワーカー合流順(Android先行・iOS後合流)で届くため、
// DOM追加順のままだとタイルの並びと食い違う。
let deviceOrder = [];

// グリッドビューの見出しは固定文言(実行ログビュー側は静的 HTML が持つ)。
gridViewTitle.textContent = t('wvMonitor2.laneLog.titleDevices');

// **選択した台数**(ラインビュー側は全台 = deviceTiles.js の renderDeviceCount)。0 でも出す。
// **初期表示は main.js が init で呼ぶ updateLaneVisibility() 経由**。ここで直接呼ばないのは、
// selectedDeviceIds が deviceTiles.js の束縛で、相互 import の評価順によっては TDZ になるため
function renderSelectionCount() {
  lanesSelectionStatus.textContent = t('wvMonitor2.laneLog.selectedCount', {
    count: selectedDeviceIds.size,
  });
}

// lanesGrid(実行ログ)の子要素をdeviceOrder順に並べ直す(appendChildは既存ノードの移動)。
// previewGrid側は「直接の子」(.lane-pair に包まれていない previewEl)だけ並べ直す —— 1台表示の1枚は
// .lane-pair に包まれて previewGrid の子になっており、動かすと組が壊れる。
// deviceOrderに無いid(全体レーン等)は末尾・相対順維持。
// 機械バッジの段を出すか。**1つでも機械付きのレーンが居れば全レーンで確保する** ——
// 段の有無がレーンごとに混ざると見出しの高さが揃わない(タイルの .with-machine-row と同じ規律)
function syncLaneMachineRow() {
  const anyMachine = [...lanes.values()].some((lane) => lane.headerEl.querySelector('.lane-host'));
  lanesGrid.classList.toggle('with-machine-row', anyMachine);
}

function reorderLanes() {
  if (deviceOrder.length === 0) {
    syncLaneMachineRow();
    return;
  }
  const rank = new Map(deviceOrder.map((id, index) => [id, index]));
  const ordered = [...lanes.keys()].sort(
    (a, b) => (rank.get(a) ?? Number.MAX_SAFE_INTEGER) - (rank.get(b) ?? Number.MAX_SAFE_INTEGER),
  );
  // **並びが既に正しければ付け直さない** —— devices サイクル(約 2 秒)ごとに呼ばれるので、毎回 appendChild で移動すると
  // レーンの本文のスクロール位置が先頭へ戻り(付け直した要素はスクロール位置を失う)、末尾で読んでいても勝手に上へ跳んだ
  const laneEls = ordered.map((id) => lanes.get(id).el);
  if (!sameChildOrder(lanesGrid, laneEls)) {
    for (const el of laneEls) { lanesGrid.appendChild(el); }
  }
  const previewEls = ordered.map((id) => lanes.get(id).previewEl).filter((el) => el.parentElement === previewGrid);
  if (!sameChildOrder(previewGrid, previewEls)) {
    for (const el of previewEls) { previewGrid.appendChild(el); }
  }
  syncLaneMachineRow();
}

/** parent の子のうち els に含まれるものが、els と同じ順で並んでいるか(ほかの子は無視する) */
function sameChildOrder(parent, els) {
  const wanted = new Set(els);
  const current = [...parent.children].filter((el) => wanted.has(el));
  return current.length === els.length && current.every((el, index) => el === els[index]);
}

// worker id(またはタイルが存在しない全体レーン)ごとの「実行中」状態。
export const runningWorkers = new Set();

/** そのデバイス(タイルの id = `platform:name`)がシナリオを回しているか。グリッドビューの操作パネルが実行中の自動の撮り直しを止めるのに使う */
export function isDeviceRunning(id) {
  return runningWorkers.has(id);
}

function setTileRunning(id, running) {
  if (running) {
    runningWorkers.add(id);
  } else {
    runningWorkers.delete(id);
  }
  const entry = tiles.get(id);
  if (entry) {
    entry.runningBadgeEl.style.display = running ? 'inline-block' : 'none';
  }
}

// platform不明(全体レーンやフォールバック)は中立色のピル。
// machine は複数の機械にまたがる実行でのみ付く。同名のデバイスが別の機械にも居るので、
// これを出さないと見出しが同じレーンが並んで区別できない(タイルの .badge-remote と同じ見た目)。
// devices サイクル(約2秒)ごとに呼ばれる。**中身が同じなら作り直さない** —— 作り直すとマウスを載せているピルが
// 消えてツールチップが点滅する(hoverTip.js)
function setLaneHeader(headerEl, name, platform, machine) {
  const key = JSON.stringify([name, platform || '', machine || '']);
  if (headerEl.dataset.headerKey === key) {
    return;
  }
  headerEl.dataset.headerKey = key;
  headerEl.textContent = '';
  const pill = document.createElement('span');
  pill.className = 'lane-name ' + (platform ? 'tile-name-' + platform : 'lane-name-neutral');
  pill.textContent = name;
  setHoverTip(pill, workerDisplayLabel(name, machine));
  headerEl.appendChild(pill);
  if (machine) {
    const host = document.createElement('span');
    host.className = 'badge badge-remote lane-host';
    host.textContent = machine;
    paintMachineBadge(host, machine);
    headerEl.appendChild(host);
  }
}

// updateLabel=trueはdevices同期等のレーン構成時のみ。appendLaneLineから呼ぶ時にtrueにすると、
// フォールバック名(生のworker id)で構成済み表示名を上書きしてしまう。
function ensureLane(id, name, platform, updateLabel, machine) {
  let lane = lanes.get(id);
  if (lane) {
    if (updateLabel) {
      setLaneHeader(lane.headerEl, name, platform, machine);
    }
    return lane;
  }
  const el = document.createElement('div');
  el.className = 'lane';
  const header = document.createElement('div');
  header.className = 'lane-header';
  setLaneHeader(header, name, platform, machine);
  const body = document.createElement('div');
  body.className = 'lane-body';
  // 行が足されるたびに自分で末尾へスクロールする欄の印。右クリックのメニューはこの中の scroll では閉じない
  // (deviceTiles.js / runProfileDevicesTab.js。プログラムのスクロールでも scroll イベントが出て、選ぶ前に閉じていた)
  body.dataset.autoScrollLog = '';
  el.append(header, body);
  lanesGrid.appendChild(el);

  // 拡大表示(選択したデバイスのぶんだけ #preview-grid に置く。中身(タイルの絵の複製)は
  // deviceTiles.js が入れる)。
  const preview = document.createElement('div');
  preview.className = 'lane-preview';
  preview.style.display = 'none';
  // グリッドビューのダブルクリック: そのデバイスだけの選択にする。
  // 「このデバイスのみ選択」の直後にもう一度押すと、その前の選択へ戻す(deviceTiles.js)
  // **1台表示の絵の上は除く** —— そこのクリックはタップ(gridLiveControls.js)なので、ダブルクリックは2回のタップ。
  // 修飾キー付きも除く(Command+クリック = ダブルタップを続けて押すと dblclick も来る)
  preview.addEventListener('dblclick', (event) => {
    if (event.altKey || event.shiftKey || event.metaKey || isGridLiveScreenTarget(event.target)) { return; }
    toggleSelectOnlyDevice(id);
  });
  preview.addEventListener('contextmenu', (event) => {
    if (openDeviceOpMenuForDevice(id, event.clientX, event.clientY)) {
      // document の contextmenu リスナが開いた直後に閉じる(タイル側と同じ理由)。
      // 止めるとペイン側の抑止にも届かないので、ここでも preventDefault する
      event.preventDefault();
      event.stopPropagation();
    }
  });

  lane = { el, previewEl: preview, headerEl: header, bodyEl: body, atBottom: true, lineCount: 0 };
  body.addEventListener('scroll', () => {
    lane.atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 24;
  });
  lanes.set(id, lane);
  updateLaneVisibility();
  return lane;
}

// レーンを畳むときは拡大表示の登録も外す(残すと deviceTiles.js が DOM から外れた要素へ
// 描き続ける)。lanes からの delete は呼び手が行う(反復中の削除を呼び手側で制御するため)。
function removeLane(id, lane) {
  detachDeviceMirror(id);
  lane.el.remove();
  lane.previewEl.remove();
}

function appendLaneLine(laneId, text) {
  const lane = ensureLane(laneId, laneId === OVERALL_LANE_ID ? overallLaneName() : laneId, undefined, false);
  const wasAtBottom = lane.atBottom;
  const line = document.createElement('div');
  line.className = 'lane-line';
  line.textContent = text;
  lane.bodyEl.appendChild(line);
  lane.lineCount += 1;
  while (lane.lineCount > MAX_LANE_LINES) {
    const first = lane.bodyEl.firstChild;
    if (!first) {
      break;
    }
    lane.bodyEl.removeChild(first);
    lane.lineCount -= 1;
  }
  if (wasAtBottom) {
    lane.bodyEl.scrollTop = lane.bodyEl.scrollHeight;
  }

  if (laneId === OVERALL_LANE_ID) {
    syncOverallLinesClass();
  }
}

function clearAllLanes() {
  for (const [id, lane] of lanes) {
    removeLane(id, lane);
  }
  lanes.clear();
  for (const id of [...runningWorkers]) {
    setTileRunning(id, false);
  }
  lanesRunStatus.textContent = '';
  updateLaneVisibility();
}

// workersReady はワーカー構成の全置換だが、**全体レーン(__overall__)は消さない** ——
// worker を持たないイベント(供給フェーズの進行)の受け皿で workersReady には現れないため、
// 消すと「起動しています (3/8)」の行が最初のワーカー合流で丸ごと消える
// (syncLanesToDevices が同じ理由で __overall__ を除外しているのと対)。
function configureLanes(laneInfos) {
  const nextIds = new Set(laneInfos.map((l) => l.id));
  for (const [id, lane] of [...lanes]) {
    if (id !== OVERALL_LANE_ID && !nextIds.has(id)) {
      removeLane(id, lane);
      lanes.delete(id);
    }
  }
  for (const info of laneInfos) {
    ensureLane(info.id, info.name, info.platform, true, info.machine);
  }
  reorderLanes();
  updateLaneVisibility();
}

// 1台だけ選択のときに previewEl を包む組。一度に1台ぶんだけ持つ(id が変わるたびに作り直す)。
let singlePair = null;

// pairId は「ちょうど1台選択・かつタイルがある」ときだけそのデバイス id、それ以外は null。
function syncSinglePair(pairId) {
  if (singlePair && singlePair.id === pairId) {
    return;
  }
  if (singlePair) {
    const oldLane = lanes.get(singlePair.id);
    if (oldLane) {
      // previewEl を組から外して #preview-grid の直接の子へ戻す(消えていなければ引き続き表示対象)
      previewGrid.appendChild(oldLane.previewEl);
    }
    singlePair.wrapper.remove();
    singlePair = null;
  }
  if (pairId === null) {
    return;
  }
  const wrapper = document.createElement('div');
  wrapper.className = 'lane-pair';
  wrapper.append(lanes.get(pairId).previewEl);
  previewGrid.appendChild(wrapper);
  singlePair = { id: pairId, wrapper };
}

export function updateLaneVisibility() {
  // 実行ログビューに出すのは**ラインビューで選択したデバイスだけ**(ユーザー決定)。
  // 選択0台なら1本も出さない。**全体レーン(__overall__)はデバイスではない**ので選択に関わらず残す ——
  // ここに供給フェーズの進行(worker を持たないイベント)が積まれるので、消すと run の進みが読めなくなる。
  const activeIds = [...lanes.keys()].filter((id) => id === OVERALL_LANE_ID || selectedDeviceIds.has(id));
  for (const [id, lane] of lanes) {
    const visible = activeIds.includes(id);
    const wasHidden = lane.el.style.display === 'none';
    lane.el.style.display = visible ? 'flex' : 'none';
    if (visible && wasHidden && lane.atBottom) {
      // 隠れている間に積まれた行の末尾へ(隠れている間は scrollHeight が 0 で追従できない)
      lane.bodyEl.scrollTop = lane.bodyEl.scrollHeight;
    }
  }
  lanesGrid.style.gridTemplateColumns = 'repeat(' + Math.max(1, activeIds.length) + ', minmax(0, 1fr))';

  // グリッドビュー: 選択中かつタイルがあるレーンだけ拡大表示する(選択0台では何も出さない)。
  const previewEnabled = selectedDeviceIds.size > 0;
  const singleDevice = selectedDeviceIds.size === 1;
  const previewIds = [];
  for (const [id, lane] of lanes) {
    const showPreview = previewEnabled && selectedDeviceIds.has(id) && tiles.has(id);
    lane.previewEl.style.display = showPreview ? 'flex' : 'none';
    if (showPreview) {
      attachDeviceMirror(id, lane.previewEl);
      previewIds.push(id);
    } else {
      detachDeviceMirror(id);
    }
  }

  // **1台だけ選択のときだけ**、拡大表示を .lane-pair で包む(操作カラム・操作パネルの置き場)。
  const singleId = singleDevice && previewIds.length === 1 ? previewIds[0] : null;
  syncSinglePair(singleId);

  // 1台表示の対象を除く拡大表示をデバイス順で並べる(対象は .lane-pair の中にいるので動かさない)。
  const rank = new Map(deviceOrder.map((id, index) => [id, index]));
  const directPreviewIds = previewIds
    .filter((id) => id !== singleId)
    .sort((a, b) => (rank.get(a) ?? Number.MAX_SAFE_INTEGER) - (rank.get(b) ?? Number.MAX_SAFE_INTEGER));
  for (const id of directPreviewIds) {
    const lane = lanes.get(id);
    previewGrid.appendChild(lane.previewEl);
    // 1台だけのときの幅指定(layoutSinglePreview)を残さない
    lane.previewEl.style.width = '';
  }

  previewGrid.classList.toggle('single-device', singleId !== null);
  // 1台表示のときだけライブ操作のツールバーを付ける(段組みの実測より前 = 高さを固定費に数える)
  syncGridLiveControls(singleId, singleId !== null ? lanes.get(singleId).previewEl : null);
  relayoutPreviewGrid(previewIds);

  renderSelectionCount();
  devicesPanel.classList.toggle('no-selection', selectedDeviceIds.size === 0);
  syncOverallLinesClass();
}

// 選択0台の案内は、全体レーンに行があるときは出さない(供給の進行と重なるため)。
// クラスにするのは出し入れを CSS 側に持たせるため(.pane-empty の注記)。
function syncOverallLinesClass() {
  const overall = lanes.get(OVERALL_LANE_ID);
  devicesPanel.classList.toggle('log-has-overall-lines', (overall?.lineCount ?? 0) > 0);
}

// 直近の段組み計算に使った引数(ResizeObserver / アスペクト確定からの再計算で使い回す)。
let previewLayoutIds = [];

// 拡大表示は「絵が一番大きくなる」段組みにする(計算は previewGridModel.js。行も列も 1fr の
// 等分なので、あとは grid-template を書くだけ)。
function relayoutPreviewGrid(previewIds) {
  previewLayoutIds = previewIds;
  const previewing = previewIds.length > 0;
  previewGrid.classList.toggle('previewing', previewing);
  if (!previewing) {
    previewGrid.style.gridTemplateColumns = '';
    previewGrid.style.gridTemplateRows = '';
    return;
  }
  // 一番横に広いデバイスに合わせる(狭いデバイスはその枠の中で letterbox される)。
  let aspect = 0;
  for (const id of previewIds) {
    const value = parseFloat(tiles.get(id)?.tileAspect);
    if (value > aspect) {
      aspect = value;
    }
  }
  if (previewGrid.classList.contains('single-device')) {
    previewGrid.style.gridTemplateColumns = 'minmax(0, 1fr)';
    previewGrid.style.gridTemplateRows = 'minmax(0, 1fr)';
    layoutSinglePreview(previewIds[0], aspect);
    return;
  }
  const gridStyle = getComputedStyle(previewGrid);
  const grid = computePreviewGrid({
    // classList の変更後に読むこと(拡大表示中はスクロールバーを出さないぶん幅が広い)
    paneWidth: previewGrid.clientWidth,
    paneHeight: previewGrid.clientHeight,
    count: previewIds.length,
    aspect,
    gap: parseFloat(gridStyle.rowGap),
    chromeHeight: measurePreviewChromeHeight(),
  });
  previewGrid.style.gridTemplateColumns = 'repeat(' + grid.columns + ', minmax(0, 1fr))';
  previewGrid.style.gridTemplateRows = 'repeat(' + grid.rows + ', minmax(0, 1fr))';
}

// 1台だけのときの拡大表示の幅。枠の固定費は実測する(定数を置かない)
function layoutSinglePreview(id, aspect) {
  const lane = lanes.get(id);
  const frame = lane && lane.previewEl.querySelector('.lane-preview-frame');
  if (!lane || !frame) {
    return;
  }
  const width = computeSinglePreviewWidth({
    paneWidth: previewGrid.clientWidth,
    paneHeight: previewGrid.clientHeight,
    aspect,
    chromeHeight: lane.previewEl.offsetHeight - frame.clientHeight,
    chromeWidth: lane.previewEl.offsetWidth - frame.clientWidth,
  });
  lane.previewEl.style.width = width === null ? '' : width + 'px';
}

// 1セルのうち絵以外(タグ段 + その下の間隔)の高さ。定数を置かず実測する(style.css を
// 変えたときに片方だけ古くなるのを防ぐ)。レイアウト未確定なら 0。
function measurePreviewChromeHeight() {
  const preview = previewGrid.querySelector('.lane-preview');
  const frame = preview && preview.querySelector('.lane-preview-frame');
  if (!preview || !frame) {
    return 0;
  }
  return Math.max(0, preview.clientHeight - frame.clientHeight);
}

// ペインの大きさが変わったら組み直す(セパレーターのドラッグ・ウィンドウ/パネルの
// リサイズを1箇所で拾う)。段組みを書き換えても previewGrid 自身の大きさは変わらないので
// 再入しない。jsdom には ResizeObserver が無いので存在するときだけ張る。
export function relayoutPreviewsForResize() {
  if (previewLayoutIds.length === 0) {
    return;
  }
  relayoutPreviewGrid(previewLayoutIds);
}
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => relayoutPreviewsForResize()).observe(previewGrid);
}

// 実行ログ・グリッドの両ペインでは既定メニュー(Cut/Copy/Paste)を出さない。選択が1台も無いときだけ
// 「すべて選択」を出す。出さないときは document へ伝播させる(開いているメニューを閉じる)。
// 出したときは止める(直後に閉じられるため)
function handlePaneContextMenu(event) {
  event.preventDefault();
  if (openSelectAllOnlyMenu(event.clientX, event.clientY)) {
    event.stopPropagation();
  }
}
logPane.addEventListener('contextmenu', handlePaneContextMenu);
outputPane.addEventListener('contextmenu', handlePaneContextMenu);

// 実行開始(cleared)で一旦消えても、次のdevicesサイクルで復元される。
// タイル側(deviceTiles.js applyDevices)と対で、devicesに無いレーンは削除して数を同期する。
// 全体レーン(__overall__)はworker無しイベントの受け皿でdevicesに現れないため削除しない。
export function syncLanesToDevices(devices) {
  const deviceIds = new Set(devices.map((device) => device.id));
  for (const [id, lane] of [...lanes]) {
    if (id !== OVERALL_LANE_ID && !deviceIds.has(id)) {
      removeLane(id, lane);
      lanes.delete(id);
    }
  }
  for (const device of devices) {
    ensureLane(device.id, device.name, device.platform, true, device.machine);
  }
  deviceOrder = devices.map((device) => device.id);
  reorderLanes();
  updateLaneVisibility();
}

export function applyLaneAction(action) {
  switch (action.type) {
    case 'cleared':
      clearAllLanes();
      break;
    case 'lanesConfigured':
      configureLanes(action.lanes);
      break;
    case 'line':
      appendLaneLine(action.laneId, action.text);
      break;
    case 'status':
      // 見出しの状況行。デバイスを選択している間もここは見えるので、供給の進行が消えない
      lanesRunStatus.textContent = action.text;
      break;
    case 'workerRunning':
      setTileRunning(action.workerId, action.running);
      break;
    case 'runFinished':
      // 完了の集計は出さない(ユーザー決定)。直前の進行表示を残さないよう空に戻すだけ
      lanesRunStatus.textContent = '';
      break;
    default:
      break;
  }
}

export function applyLaneHydrate(snapshot) {
  clearAllLanes();
  if (snapshot.lanes.length > 0) {
    configureLanes(snapshot.lanes);
  }
  for (const laneId of Object.keys(snapshot.linesByLane)) {
    for (const text of snapshot.linesByLane[laneId]) {
      appendLaneLine(laneId, text);
    }
  }
  for (const workerId of snapshot.runningWorkers) {
    setTileRunning(workerId, true);
  }
}
