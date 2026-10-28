// gridMarquee.js
// グリッドビュー(「選択したデバイス」)の範囲選択: 左ドラッグで矩形を引き、囲んだデバイスだけの選択に絞る
// (「このデバイスのみ選択」の複数台版。ユーザー決定)。幾何はラインビューと同じ marqueeModel.js。
//
// 規律:
//   ① **選択はドラッグを離したときに1回だけ変える** —— ドラッグ中に選択を変えるとグリッドの段組みが組み直され、
//      矩形の下の拡大表示が動いてしまう。ドラッグ中は囲んだデバイスに印(.marquee-hit)を付けるだけ
//   ② **1台表示(.single-device)では始めない** —— その画面の上のドラッグはスワイプ(gridLiveControls.js)
//   ③ 押せる部品(ボタン・入力欄)の上から始めたドラッグは範囲選択にしない
//   ④ 範囲選択で終わったドラッグの直後の click は飲み込む(拡大表示のクリック処理へ渡さない)。印は pointerdown で必ず倒す

import { previewGrid } from './domRefs.js';
import { isDragDistance, marqueeRect, idsInMarquee } from './marqueeModel.js';
import { selectOnlyDevices } from './deviceTiles.js';

let pointerId = null;
let origin = null;
let active = false;
let lastRect = null;
let suppressClick = false;
let overlay = null;

function ensureOverlay() {
  if (!overlay) {
    overlay = document.createElement('div');
    // 見た目はラインビューの範囲選択と同じ(.tile-marquee)。位置は viewport 基準(.grid-marquee = fixed)
    overlay.className = 'tile-marquee grid-marquee';
    document.body.appendChild(overlay);
  }
  return overlay;
}

/** 今グリッドビューに出ている拡大表示(id と画面上の矩形) */
function visiblePreviews() {
  return [...previewGrid.querySelectorAll('.lane-preview[data-device-id]')]
    .filter((el) => el.style.display !== 'none')
    .map((el) => ({ el, id: el.dataset.deviceId, rect: el.getBoundingClientRect() }));
}

function markHits(hitIds) {
  const hits = new Set(hitIds);
  for (const { el, id } of visiblePreviews()) {
    el.classList.toggle('marquee-hit', hits.has(id));
  }
}

function reset() {
  pointerId = null;
  origin = null;
  active = false;
  lastRect = null;
  previewGrid.classList.remove('marquee-dragging');
  if (overlay) { overlay.style.display = 'none'; }
  markHits([]);
}

previewGrid.addEventListener('pointerdown', (event) => {
  suppressClick = false;
  if (event.button !== 0 || previewGrid.classList.contains('single-device')) { return; }
  if (event.target instanceof Element && event.target.closest('button, input, select, textarea, a')) { return; }
  pointerId = event.pointerId;
  origin = { x: event.clientX, y: event.clientY };
  active = false;
});

window.addEventListener('pointermove', (event) => {
  if (event.pointerId !== pointerId || !origin) { return; }
  if (!active) {
    if (!isDragDistance(event.clientX - origin.x, event.clientY - origin.y)) { return; }
    active = true;
    previewGrid.classList.add('marquee-dragging');
    ensureOverlay().style.display = 'block';
  }
  lastRect = marqueeRect(origin, { x: event.clientX, y: event.clientY });
  const box = ensureOverlay();
  box.style.left = lastRect.left + 'px';
  box.style.top = lastRect.top + 'px';
  box.style.width = lastRect.width + 'px';
  box.style.height = lastRect.height + 'px';
  markHits(idsInMarquee(lastRect, visiblePreviews()));
});

window.addEventListener('pointerup', (event) => {
  if (event.pointerId !== pointerId) { return; }
  if (active && lastRect) {
    const ids = idsInMarquee(lastRect, visiblePreviews());
    suppressClick = true;
    reset();
    // 何も囲まなかったら選択は変えない(グリッドビューを空にしない)
    if (ids.length > 0) { selectOnlyDevices(ids); }
    return;
  }
  reset();
});
window.addEventListener('pointercancel', (event) => {
  if (event.pointerId === pointerId) { reset(); }
});

previewGrid.addEventListener('click', (event) => {
  if (!suppressClick) { return; }
  suppressClick = false;
  event.stopPropagation();
  event.preventDefault();
}, true);
