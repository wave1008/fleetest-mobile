// liveDeps.ts
// MonitorLiveController(monitorLiveController.ts)への窓口。MonitorPanelDeps からライブ操作に
// 必要なフィールドだけを切り出したもの(実装: liveTabHost.ts の LiveTabHost)。

import type * as vscode from "vscode";
import type { FleetestConfig } from "./config";
import type { LiveToWebviewEnvelope } from "./liveModel";

export interface LiveDeps {
  readonly workspaceRoot: string;
  getConfig(): FleetestConfig;
  readonly outputChannel: vscode.OutputChannel;
  post(message: LiveToWebviewEnvelope): void;
  /** パネルが開いているか。scheduleServeRestart() の5秒後再起動タイマーが使う。 */
  isPanelActive(): boolean;
}
