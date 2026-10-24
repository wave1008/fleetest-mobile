// panelRelocalize.test.mjs
// 各 webview パネルの relocalize()(fleetest.language 変更時に extension.ts が呼ぶ)の実行時検証。
// コントローラクラス自体はこのテストのためだけに export されている(生成経路は register*Panel の
// み。各 *Panel.ts 冒頭コメント参照)。
//
// Monitor の relocalize() は内部で vscode.Uri.joinPath(...)(renderHtml)や
// vscode.workspace.createFileSystemWatcher(...)(Monitor のサブコントローラ
// MonitorProfilesController がコンストラクタで呼ぶ)を実行する。esbuild の vscodeStubPlugin
// (monitorUpdate.test.mjs 冒頭コメント参照)は `import * as vscode from "vscode"` を CJS→ESM
// 変換する際に __toESM の __copyProps が Proxy の実プロパティ(length/name/prototype のみ)しか
// 写さないため、`vscode.Uri`/`vscode.workspace` 等はどのファイルでも undefined になり、触れた
// 時点で必ず例外になる(実測: TypeError: Cannot read properties of undefined)。
// そのため実行時テストで検証できるのは「vscode に触れない経路」だけ:
// - LiveTabHost(グリッドビューのライブ操作のサブコントローラ)は自分の WebviewPanel を持たず、
//   MonitorPanelController から狭い deps(LiveTabHostDeps)だけを注入されるので、vscode に
//   触れずに単体で構成できる(Monitor 本体はコンストラクタ自体が
//   vscode.workspace.createFileSystemWatcher を呼ぶため、コンストラクタすら実行できない。
//   Monitor 本体は対象外)。
// Monitor の relocalize()(html 再構築 → deviceStream.restartAllStreams() の順)は
// test/panelRelocalizeSourceContract.test.mjs がソース走査で検証する(同ファイル冒頭コメント参照)。
// 「結果ダッシュボード」は単独パネルを廃止しモニターパネルのタブへ統合済み(旧 dashboardPanel.ts)。
// relocalize は Monitor 側の1本にまとまったため、ここに Dashboard 専用のテストは無い。

import assert from "node:assert/strict";
import { test } from "node:test";

import { LiveTabHost } from "../src/liveTabHost";

const outputChannel = { appendLine() {} };
const getConfig = () => ({ binaryPath: "/usr/local/bin/fleetest", project: "P", profile: "" });

function newLiveTabHost() {
  const deps = {
    post: () => {},
    isPanelOpen: () => false,
  };
  return new LiveTabHost(deps, getConfig, "/tmp/proj", outputChannel);
}

test("LiveTabHost: 狭い deps だけで構成でき、止める・破棄するが例外なく終わる(serve を起こしていなくても)", () => {
  const host = newLiveTabHost();
  assert.doesNotThrow(() => host.stopProcesses());
  assert.doesNotThrow(() => host.dispose());
});

test("LiveTabHost.resumeServeAfterSweep(): 畳んでいなくても何も起こさない(refreshDevices を撃たない)", async () => {
  const host = newLiveTabHost();
  let refreshed = 0;
  host.live.refreshDevices = () => {
    refreshed += 1;
  };
  host.resumeServeAfterSweep();
  await host.suspendServeForSweep();
  host.resumeServeAfterSweep();
  assert.equal(refreshed, 0);
  host.dispose();
});
