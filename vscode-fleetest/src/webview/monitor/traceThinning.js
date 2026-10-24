// 「軌跡モード」(ライブ操作の1本指ドラッグを、離さない1本のタッチとして再生する)の点列の
// 間引き(純粋関数。DOM に触らない)。
//
// pointermove は環境によって数ms〜十数msごとに発火し、長い/速いドラッグでは数百〜千点を超えうる。
// そのまま送ると ft_gesture / GestureRequest の1指あたりの点数上限(TouchGesture.maxPointsPerFinger
// = 625)に触れる。2段で間引く:
//   ①直前に残した点から16ms未満の点は捨てる(間隔を敷き直すだけで軌跡の形はほぼ変えない)
//   ②それでも600点を超えていれば均等間引きで600点にする(形が単調に崩れる。①で足りない
//     極端に長い/密なドラッグだけがここに落ちる)
// **どちらの段も先頭・末尾は必ず残す**(始点・終点を欠くとタップ開始位置やリフト位置がずれる)。

const MIN_KEPT_INTERVAL_MS = 16;
const MAX_POINTS = 600;

/**
 * points: [{x, y, t}, ...]。t は先頭を0とする昇順のミリ秒。空・1点はそのまま返す。
 * 間引き後も t の昇順は保たれる(元の配列が昇順である前提)。
 */
export function thinTracePoints(points) {
  if (points.length <= 2) {
    return points;
  }
  const byInterval = [points[0]];
  let lastKeptT = points[0].t;
  for (let i = 1; i < points.length - 1; i++) {
    const p = points[i];
    if (p.t - lastKeptT >= MIN_KEPT_INTERVAL_MS) {
      byInterval.push(p);
      lastKeptT = p.t;
    }
  }
  byInterval.push(points[points.length - 1]);
  if (byInterval.length <= MAX_POINTS) {
    return byInterval;
  }
  const thinned = [];
  const step = (byInterval.length - 1) / (MAX_POINTS - 1);
  for (let i = 0; i < MAX_POINTS; i++) {
    thinned.push(byInterval[Math.round(i * step)]);
  }
  return thinned;
}

/**
 * 再生が elapsedMs まで進んだときの軌跡の前半(t <= elapsedMs の点 + 点と点の間を線形補間した現在位置)。
 * points は thinTracePoints と同じ形(t は先頭を0とする昇順)。elapsedMs < 0 は空・末尾の t 以上は全体を返す。
 */
export function tracePrefix(points, elapsedMs) {
  if (points.length === 0 || elapsedMs < 0) {
    return [];
  }
  const prefix = [points[0]];
  for (let i = 1; i < points.length; i++) {
    const p = points[i];
    if (p.t <= elapsedMs) {
      prefix.push(p);
      continue;
    }
    const prev = points[i - 1];
    const span = p.t - prev.t;
    const r = span > 0 ? (elapsedMs - prev.t) / span : 1;
    prefix.push({ x: prev.x + (p.x - prev.x) * r, y: prev.y + (p.y - prev.y) * r, t: elapsedMs });
    break;
  }
  return prefix;
}

/** 始点から minPx 以上離れた最初の点の t(= 指が動き始めた時刻)。最後まで離れなければ末尾の t。空は 0 */
export function firstMoveT(points, minPx) {
  if (points.length === 0) {
    return 0;
  }
  const start = points[0];
  for (const p of points) {
    if (Math.hypot(p.x - start.x, p.y - start.y) >= minPx) {
      return p.t;
    }
  }
  return points[points.length - 1].t;
}
