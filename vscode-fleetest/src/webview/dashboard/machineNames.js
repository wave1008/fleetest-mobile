// 記録の host(ホスト名)→ この Mac の登録名(machine)の表示読み替え。
// 対応表は payload.machines(facts キャッシュ由来)で、main.js が data 受信のたびに差し替える。
// 表に無い host(古い記録・未観測の機械)はホスト名のまま出す(事実を落とさない)。
// 記録・runID は host のまま —— ここは表示だけ(RR-0 の用語規律)。

import { LOCAL_MACHINE_LABEL, settingsMachineOrder } from '../monitor/machineColors.js';
import { compareMachineOrder } from '../../monitorDeviceModel';

let aliasByHost = new Map();

export function setMachineAliases(rows) {
  aliasByHost = new Map(rows.map((row) => [row.host, row.machine]));
}

export function machineLabel(host) {
  return aliasByHost.get(host) || host;
}

/** 表示名(手元は 'local')の比較。モニターと同じ機械の順(compareMachineOrder = local → 設定タブの順 → 名前順) */
export function compareMachineLabels(a, b) {
  const local = (label) => (label === LOCAL_MACHINE_LABEL ? '' : label);
  return compareMachineOrder(local(a), local(b), settingsMachineOrder());
}

/** hosts → 表示名の配列(compareMachineLabels の順)。並べ替えはデータの次の描画で効く(ラン一覧は即時には描き直さない) */
export function machineLabels(hosts) {
  return hosts.map(machineLabel).sort(compareMachineLabels);
}
