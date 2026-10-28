// monitorRunLogModel.ts
// monitorRunLog(他者の run のデバイス別ログ)を実行ログのレーンへ積む純粋ロジック。vscode 非依存。

import type { MonitorRunLogEvent } from "./monitorDeviceModel";
import { appendLaneLines, type LaneAction, type RunLaneState } from "./runLaneModel";

/** owner が selfOwner(この拡張ホストの streamOwnerValue())と一致する行は、拡張が起こした run =
 * bus 経路で既に出ているので捨てる。owner 無し・別の値は積む。**行数では打ち切らない**
 * (保持上限は bus 経路と同じ runLaneModel.MAX_LANE_LINES のまま)。 */
export function reduceMonitorRunLog(
  state: RunLaneState,
  event: MonitorRunLogEvent,
  selfOwner: string,
): LaneAction[] {
  if (event.owner === selfOwner) {
    return [];
  }
  return appendLaneLines(state, event.device, event.lines);
}
