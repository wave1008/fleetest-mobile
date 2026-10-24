// liveTabHost.ts
// デバイスモニター(monitorPanel.ts)のグリッドビュー(1台選択)のライブ操作の窓口。MonitorPanelController が
// 他のサブコントローラ(MonitorDeviceStreamController 等)と同じパターンで1つ生成する(自分の
// WebviewPanel は持たない)。実処理は monitorLiveController.ts の MonitorLiveController(LiveDeps
// 経由で疎結合)、webview 側は src/webview/monitor/gridLiveControls.js・gridLivePanel.js。

import type * as vscode from "vscode";
import type { FleetestConfig } from "./config";
import type { LiveDeps } from "./liveDeps";
import { type GridLiveAction, remoteDeviceOption } from "./liveModel";
import { MonitorLiveController } from "./monitorLiveController";
import type { MonitorFromWebviewMessage, MonitorToWebviewMessage } from "./monitorWebviewMessages";

type GridRemoteTarget = NonNullable<Extract<MonitorFromWebviewMessage, { type: "gridLiveAction" }>["remote"]>;

/** MonitorPanelController からの窓口(MonitorPanelDeps と同じ、必要なものだけを束ねる狭い形)。 */
export interface LiveTabHostDeps {
  post(message: MonitorToWebviewMessage): void;
  /** デバイスモニターの webview パネルが生成済みか(表示中かは問わない)。 */
  isPanelOpen(): boolean;
}

/** export はテスト(panelRelocalize.test.mjs)が差し替えで契約を検証するため。
 * 生成経路は MonitorPanelController のコンストラクタのみ(シングルトン方針は変えない)。 */
export class LiveTabHost implements vscode.Disposable {
  private readonly innerDeps: LiveDeps;
  readonly live: MonitorLiveController;

  constructor(
    private readonly deps: LiveTabHostDeps,
    getConfig: () => FleetestConfig,
    workspaceRoot: string,
    outputChannel: vscode.OutputChannel,
  ) {
    this.innerDeps = {
      workspaceRoot,
      getConfig,
      outputChannel,
      post: (message) => this.deps.post(message),
      isPanelActive: () => this.deps.isPanelOpen(),
    };
    this.live = new MonitorLiveController(this.innerDeps);
  }

  /** グリッドビュー(1台表示)のツールバー・修飾キー操作。remote は他の機械のタイルのときだけ
   * (そのデバイスはこの Mac の list-devices に居ないので、開くのに要る属性をタイルから運ぶ)。 */
  gridAction(id: string, action: GridLiveAction, remote?: GridRemoteTarget): void {
    if (remote) {
      this.live.registerRemoteDevice(remoteDeviceOption({
        id, name: remote.name, platform: remote.platform, state: remote.state, kind: remote.kind,
        udid: remote.udid ?? null, serial: remote.serial ?? null, machine: remote.machine,
      }));
    }
    void this.live.handleGridAction(id, action);
  }

  /** 「全て終了」の前後(monitorPanel.ts の confirmThenBulkDown)。理由は
   * MonitorLiveController.suspendServeForSweep の doc。 */
  suspendServeForSweep(): Promise<void> {
    return this.live.suspendServeForSweep();
  }

  resumeServeAfterSweep(): void {
    this.live.resumeServeAfterSweep();
  }

  /** モニターの webview パネルが破棄された(close/再作成前)ときに呼ぶ。コントローラ自体は
   * MonitorPanelController と同じ寿命で残り続ける(deviceStream.dispose() と同じ規律)。 */
  stopProcesses(): void {
    this.live.stopProcesses();
  }

  dispose(): void {
    this.live.dispose();
  }
}
