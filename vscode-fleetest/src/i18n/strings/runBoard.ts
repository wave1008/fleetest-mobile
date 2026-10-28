// 辞書(webview 側)。namespace: runBoard.
// 対象ソース: webview/monitor/runBoard.js(デバイスモニターの「run ボード」。DS-18)。
// webview バンドル(src/webview/i18n.js)から import される。**vscode 非依存**を保つこと。
// キーは "runBoard." 始まり。
import type { MessageDict } from "../core";

export const runBoardStrings = {
  "runBoard.title": { ja: "実行中 {count}", en: "Running {count}" },
  // ツールチップと aria-label が共有。**ON/OFF で入れ替えない**(ユーザー決定)——
  // このボタンは「いま開く」ではなく「開いた状態を保つ」モードのスイッチ
  "runBoard.expandAll": { ja: "全て展開を維持", en: "Keep all expanded" },
  "runBoard.runningDevicesTip": { ja: "シナリオを実行中のデバイスの数", en: "Devices running a scenario" },
  "runBoard.toggleTachometer": { ja: "タコメーターを表示", en: "Show the tachometer" },
  "runBoard.collapse": { ja: "run ボードを閉じる", en: "Collapse run board" },
  "runBoard.expand": { ja: "run ボードを開く", en: "Expand run board" },
  "runBoard.expandLanes": { ja: "デバイスごとの内訳を開く", en: "Show per-device lanes" },
  "runBoard.collapseLanes": { ja: "デバイスごとの内訳を閉じる", en: "Hide per-device lanes" },
  "runBoard.machineIdle": { ja: "空き", en: "Free" },
  "runBoard.machineUnknown": { ja: "実行状況を観測できていません", en: "Run status not observed" },
  "runBoard.issuerRun": { ja: "{issuer} の run", en: "{issuer}'s run" },
  "runBoard.building": { ja: "シナリオをビルド中", en: "Building scenarios…" },
  "runBoard.requeued": { ja: "⟳{count}", en: "⟳{count}" },
  "runBoard.laneDropouts": { ja: "レーン離脱 {count}", en: "{count} lane(s) dropped" },
  "runBoard.preparing": { ja: "デバイスの準備を開始します", en: "Starting device preparation…" },
  // 準備中の端末ごとの供給の段階(台帳の supply)。1つだけ出す(選び方は runBoardModel.currentSupplyStep・台数は出さない)
  "runBoard.supplyServices": { ja: "サーバーを起動中", en: "Starting the servers…" },
  "runBoard.supplyRunnerBuild": { ja: "ランナーをビルド中", en: "Building the runner…" },
  "runBoard.supplyBooting": { ja: "デバイスを起動中", en: "Booting devices…" },
  "runBoard.supplyBridge": { ja: "ブリッジを起動中", en: "Starting the bridge…" },
  "runBoard.supplyInstalling": { ja: "アプリをインストール中", en: "Installing the app…" },
  "runBoard.supplyConfiguring": { ja: "デバイスを設定しています", en: "Configuring devices…" },
  // 全台の準備が終わり、実行が始まる直前(準備中のときだけ。実行中には添えない)
  "runBoard.supplyStarting": { ja: "テストを開始しています", en: "Starting tests…" },
  "runBoard.compiling": { ja: "Vision コンパイル中", en: "Compiling Vision…" },
  "runBoard.laneIdle": { ja: "⏹ 待機", en: "⏹ Waiting" },
  "runBoard.remainingUnknown": { ja: "—", en: "—" },
  "runBoard.remainingTime": { ja: "残 ~{time}", en: "~{time} left" },
  "runBoard.remainingOverage": {
    ja: "残 ~0:00(+{time} 超過)",
    en: "~0:00 left (+{time} over)",
  },
  "runBoard.encodingVideo": { ja: "動画を編集中 {done}/{total}", en: "Encoding videos {done}/{total}" },
  // アクション/秒メーター(見出し「実行中 N」の右)。ja の「マシン」は利用者向け表記
  "runBoard.tachometerUnit": { ja: "アクション/秒", en: "actions/s" },
  "runBoard.tachometerAria": { ja: "タコメーター {value} アクション/秒", en: "Tachometer {value} actions/s" },
  "runBoard.tachometerTipTotal": { ja: "{value} アクション/秒", en: "{value} actions/s" },
  "runBoard.tachometerTipMachine": { ja: "{machine}: {value}", en: "{machine}: {value}" },
  "runBoard.tachometerTipUnobserved": { ja: "観測できていないマシン: {machines}", en: "Not observed: {machines}" },
  "runBoard.tachometerTipDefinition": {
    ja: "直近 3 秒にデバイスへ送った操作の数 ÷ 3(メーターと連動)",
    en: "Operations sent to devices in the last 3 seconds ÷ 3 (follows the meter)",
  },
  "runBoard.tachometerTipScale": {
    ja: "1目盛り = 1アクション/秒",
    en: "One segment = 1 action/s",
  },
  // マシンの行のサーバー(DS-18.10)。{projects} はプロジェクト名を servicesProjectSeparator でつないだもの
  "runBoard.servicesProjectSeparator": { ja: "・", en: ", " },
  "runBoard.servicesRunning": { ja: "サーバー稼働中 {projects}", en: "Servers up: {projects}" },
  "runBoard.servicesStarting": { ja: "サーバーを起動中 {projects}", en: "Servers starting: {projects}" },
  "runBoard.servicesStopping": { ja: "サーバーを停止中 {projects}", en: "Servers stopping: {projects}" },
  "runBoard.servicesOrphan": { ja: "サーバー(持ち主なし) {projects}", en: "Servers without owner: {projects}" },
  "runBoard.servicesOwnerTip": {
    ja: "{project} / {profile}: fleetest services up で常駐しています(pid {pid})。止めるには fleetest services down --project {project} --profile {profile}",
    en: "{project} / {profile}: kept up by fleetest services up (pid {pid}). Stop with fleetest services down --project {project} --profile {profile}",
  },
  "runBoard.servicesRunStoppingTip": {
    ja: "{project} / {profile}: 終わった run(pid {pid})がサーバーを止めています",
    en: "{project} / {profile}: the finished run (pid {pid}) is stopping the servers",
  },
  "runBoard.servicesOrphanTip": {
    ja: "{project} / {profile}: 起動したプロセス(pid {pid})は終了しています。残ったコンテナは fleetest services reset --project {project} --profile {profile} で片付けます",
    en: "{project} / {profile}: the process that started them (pid {pid}) has exited. Remove what is left with fleetest services reset --project {project} --profile {profile}",
  },
} satisfies MessageDict;
