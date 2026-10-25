// docs/README.md(保守者向け文書の索引と書き方)の整合検証。壊れても黙る形を落とす:
//   ① 索引と docs/ 直下の文書が食い違う(索引から辿れない文書・存在しない文書を指す行)
//   ② 節の ID(`MN-72` 等)への参照に、定義する見出しが無い / 同じ ID の見出しが2つある
//   ③ 正典・規則が名指しするコードの名前が無い(改名・撤去の後の残り)
//   ④ 正典・規則が e2e.sh 系を「絞って回す」手順として案内する(フックが必ず断る)
// 接頭辞の一覧は docs/README.md「節の ID」の表が唯一の定義元で、ここでは持たない。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const DOCS = path.join(ROOT, "docs");
const INDEX = readFileSync(path.join(DOCS, "README.md"), "utf8");

// 参照を探す範囲。TestProjects/(ユーザー資産)と生成物は見ない
const SCAN_ROOTS = ["CLAUDE.md", "AGENTS.md", ".claude/rules", "docs", "Sources", "Tests", "Scripts",
  "vscode-fleetest/src", "vscode-fleetest/test"];
const SCAN_EXT = /\.(md|swift|ts|mjs|js|py|sh|css)$/;
const SKIP_DIR = new Set(["node_modules", ".build", "Fixtures", "fixtures"]);

function walk(rel) {
  const full = path.join(ROOT, rel);
  let st;
  try { st = statSync(full); } catch { return []; }
  if (!st.isDirectory()) return SCAN_EXT.test(rel) ? [rel] : [];
  return readdirSync(full).filter((e) => !SKIP_DIR.has(e)).flatMap((e) => walk(path.join(rel, e)));
}

/** docs/ 直下と、分割先のサブフォルダ(user-docs と images 以外)の .md。docs/ からの相対パス。 */
function maintainerDocs(dir = DOCS) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const full = path.join(dir, e);
    if (statSync(full).isDirectory()) {
      if (dir === DOCS && (e === "user-docs" || e === "images")) continue;
      out.push(...maintainerDocs(full));
    } else if (e.endsWith(".md") && !(dir === DOCS && e === "README.md")) {
      out.push(path.relative(DOCS, full).split(path.sep).join("/"));
    }
  }
  return out.sort();
}

export function prefixesFrom(index) {
  const section = index.split(/^### 節の ID$/m)[1] ?? "";
  return [...section.matchAll(/^\| `([A-Z]{2,3})` \|/gm)].map((m) => m[1]);
}

export function idDefinitions(text, prefixes) {
  const re = new RegExp(`^#{2,6} ((?:${prefixes.join("|")})-\\d+(?:\\.\\d+)*) `, "gm");
  return [...text.matchAll(re)].map((m) => m[1]);
}

export function idReferences(text, prefixes) {
  const re = new RegExp(`\\b((?:${prefixes.join("|")})-\\d+(?:\\.\\d+)*)\\b`, "g");
  return [...text.matchAll(re)].map((m) => m[1]);
}

// 番号 0 は規約の例示用に予約(docs/README.md「節の ID」)
export const isExampleId = (id) => /^[A-Z]{2,3}-0(?:\.|$)/.test(id);

test("docs/README.md の索引と docs/ の保守者向け文書が一致する", () => {
  const listed = [...INDEX.split(/^## 書き方$/m)[0].matchAll(/^\| \[[^\]]+\]\(([^)#]+)\) \|/gm)].map((m) => m[1]);
  assert.deepEqual([...new Set(listed)].sort(), maintainerDocs());
});

test("接頭辞の表が読める", () => {
  const prefixes = prefixesFrom(INDEX);
  assert.ok(prefixes.includes("MN") && prefixes.length >= 5, `接頭辞の表が読めない: ${prefixes}`);
  assert.equal(new Set(prefixes).size, prefixes.length, "接頭辞が重複している");
});

test("節の ID は1回だけ定義され、参照された ID は全部定義がある", () => {
  const prefixes = prefixesFrom(INDEX);
  const defined = new Map();
  for (const doc of maintainerDocs()) {
    for (const id of idDefinitions(readFileSync(path.join(DOCS, doc), "utf8"), prefixes)) {
      defined.set(id, [...(defined.get(id) ?? []), doc]);
    }
  }
  const duplicated = [...defined].filter(([, docs]) => docs.length > 1).map(([id, docs]) => `${id}: ${docs.join(", ")}`);
  assert.deepEqual(duplicated, [], "同じ ID を定義する見出しが複数ある");

  const dangling = [];
  // このファイル自身は検出器の入力例を持つので走査しない
  const self = "vscode-fleetest/test/docsIndex.test.mjs";
  for (const file of SCAN_ROOTS.flatMap(walk).filter((f) => f !== self)) {
    for (const id of idReferences(readFileSync(path.join(ROOT, file), "utf8"), prefixes)) {
      if (!defined.has(id) && !isExampleId(id)) dangling.push(`${file}: ${id}`);
    }
  }
  assert.deepEqual([...new Set(dangling)], [], "定義の無い ID への参照(見出しを足すか参照を直す)");
});

/** H1 の直後の冒頭の表の種別(無ければ null)。 */
export function headerKind(text) {
  const m = text.match(/^# [^\n]+\n\n\| 種別 \| 範囲 \| 読む場面 \| 扱わないこと \|\n\|---\|---\|---\|---\|\n\| ([^|]+?) \|/);
  return m ? m[1] : null;
}

/** 台帳の項目(`### <ID> …`)のうち、直下に状態と確認の行を持たないもの。 */
export function ledgerItemsMissingState(text) {
  const bad = [];
  for (const m of text.matchAll(/^### ([A-Z]{2,3}-\d+)[^\n]*\n([^\n]*)\n([^\n]*)/gm)) {
    const okState = /^- 状態: (推測|経路確定|再現済み|据え置き)$/.test(m[2]);
    const okSeen = /^- 確認: \S/.test(m[3]);
    if (!okState || !okSeen) bad.push(m[1]);
  }
  return bad;
}

test("各文書の冒頭に規約の表があり、種別が索引と一致する", () => {
  const indexKinds = new Map([...INDEX.split(/^## 書き方$/m)[0]
    .matchAll(/^\| \[[^\]]+\]\(([^)#]+)\) \| ([^|]+?) \|/gm)].map((m) => [m[1], m[2]]));
  const mismatched = [];
  for (const doc of maintainerDocs()) {
    const kind = headerKind(readFileSync(path.join(DOCS, doc), "utf8"));
    if (kind !== indexKinds.get(doc)) mismatched.push(`${doc}: 冒頭=${kind} 索引=${indexKinds.get(doc)}`);
  }
  assert.deepEqual(mismatched, [], "冒頭の表が無い、または種別が索引と違う(docs/README.md「ファイルの冒頭」)");
});

test("台帳の項目は状態と確認の行を持つ", () => {
  const ledgers = [...INDEX.split(/^## 書き方$/m)[0].matchAll(/^\| \[[^\]]+\]\(([^)#]+)\) \| 台帳 \|/gm)].map((m) => m[1]);
  assert.ok(ledgers.includes("open-issues.md"), "索引から台帳が読めない");
  const bad = ledgers.flatMap((doc) => ledgerItemsMissingState(readFileSync(path.join(DOCS, doc), "utf8")).map((id) => `${doc}: ${id}`));
  assert.deepEqual(bad, [], "状態・確認の行が無い/状態の値が規約外(docs/README.md「台帳の項目」)");
});

/** 文書名の無い `§N`(どの文書の節か grep で決まらない。docs/README.md「節の ID」)。 */
export function bareSectionRefs(text) {
  return [...text.matchAll(/§\s?\d/g)].length;
}

/** `## 目次` の行が本文の `##` 見出しを全部載せていなければ、欠けた見出しを返す。 */
export function tocMissing(text) {
  const body = text.replace(/```[\s\S]*?```/g, "");
  const toc = body.split(/^## 目次$/m)[1]?.split(/^## /m)[0] ?? "";
  return [...body.matchAll(/^## (.+)$/gm)].map((m) => m[1])
    .filter((h) => h !== "目次" && !toc.includes(h.split(" ")[0].match(/^[A-Z]{2,3}-/) ? h.split(" ")[0] : h));
}

test("文書名の無い §N を書かない(ID で参照する)", () => {
  const roots = [...SCAN_ROOTS, ".claude/skills", "Runner", "InAppBridge", "AndroidRunner", "Package.swift"];
  const self = "vscode-fleetest/test/docsIndex.test.mjs";
  const hits = roots.flatMap(walk)
    .filter((f) => f !== self && !f.startsWith("docs/user-docs/"))
    .filter((f) => bareSectionRefs(readFileSync(path.join(ROOT, f), "utf8")) > 0);
  assert.deepEqual(hits, [], "§N が残っている(MN-72 等の ID へ書き換える)");
});

test("文書は 1600 行以内で、1000 行を超えるものは目次を持つ", () => {
  const bad = [];
  for (const doc of maintainerDocs()) {
    const text = readFileSync(path.join(DOCS, doc), "utf8");
    const n = text.split("\n").length;
    if (n > 1600) bad.push(`${doc}: ${n} 行(分割する)`);
    else if (n > 1000 && tocMissing(text).length) bad.push(`${doc}: 目次に無い見出し ${tocMissing(text).slice(0, 3).join(" / ")}`);
  }
  assert.deepEqual(bad, [], "docs/README.md「大きさ」");
});

test("分割したフォルダの README はフォルダ内の全 ## ID を載せる", () => {
  const prefixes = prefixesFrom(INDEX);
  const folders = [...new Set(maintainerDocs().filter((d) => d.includes("/")).map((d) => d.split("/")[0]))];
  assert.ok(folders.includes("maintainer-notes"), `分割したフォルダが読めない: ${folders}`);
  const missing = [];
  for (const folder of folders) {
    const readme = readFileSync(path.join(DOCS, folder, "README.md"), "utf8");
    for (const doc of maintainerDocs().filter((d) => d.startsWith(`${folder}/`) && !d.endsWith("/README.md"))) {
      const text = readFileSync(path.join(DOCS, doc), "utf8");
      for (const m of text.matchAll(new RegExp(`^## ((?:${prefixes.join("|")})-[\\d.]+) `, "gm"))) {
        if (!new RegExp(`^- ${m[1].replace(/\./g, "\\.")} `, "m").test(readme)) missing.push(`${folder}/README.md: ${m[1]}`);
      }
    }
  }
  assert.deepEqual(missing, [], "フォルダの README(目次)に節が載っていない");
});

/** 制約の節(`### `)のうち、冒頭の数行に `確認環境` の行を持たないもの(docs/README.md「正典と記録」の手順の書き方)。 */
export function constraintsMissingEnv(text) {
  const body = text.replace(/```[\s\S]*?```/g, "");
  const lines = body.split("\n");
  const missing = [];
  lines.forEach((l, i) => {
    if (!l.startsWith("### ")) return;
    if (!lines.slice(i + 1, i + 4).some((x) => x.startsWith("確認環境"))) missing.push(l.slice(4, 60));
  });
  return missing;
}

test("制約と回避の各節は確認環境の行を持つ", () => {
  const text = readFileSync(path.join(DOCS, "verification/constraints.md"), "utf8");
  assert.ok((text.match(/^### /gm) ?? []).length >= 5, "制約の節が読めない");
  assert.deepEqual(constraintsMissingEnv(text), [], "確認環境の行が無い(版を上げたとき見直す対象を選べない)");
  assert.deepEqual(constraintsMissingEnv("### A\n\n確認環境: 未記録\n### B\n本文\n"), ["B"]);
});

// ── 正典・規則が名指しするコードの名前 ──
// 改名・撤去の後に古い名前が正典に残る型を落とす。記録(種別「記録」)は過去の名前を持ってよいので見ない。
// 照合先は git 管理下のコード本文とファイル名(docs・TestProjects・reports・*.md は除く。このファイル自身も除く =
// 下の許可表が照合先に入ると素通しになる)。

/** コード外の名前(OS・外部製品・Shirates 側・経緯の文脈・書式の例)。理由ごとに並べる。 */
const EXTERNAL_CODE_NAMES = new Set([
  // OS・Apple の非公開実装・設定キー
  "ApplicationFirewall", "BootSessionIdentifier", "DiagnosticCollectionPolicy", "GenerativeExperiencesSafetyInferenceProvider",
  "JavaVirtualMachines", "MobileAsset", "ModuleCache", "RemoteVideoEncoder", "SwiftTestingInteropRecordHandler",
  "TextRecognition", "TodayFeedConfigDecoder", "V11E2EPipeline", "H14D",
  // sshd_config のキー
  "PasswordAuthentication", "PermitRootLogin", "PermitUserEnvironment", "StrictHostKeyChecking",
  // UI フレームワーク・エージェントの名前
  "FlingBehavior", "ReactEditText", "AskUserQuestion",
  // Shirates 側の名前(shirates-parity.md の対応表)
  "InScanResults", "TestElement.swipeTo",
  // 撤去済みと明記した文脈・監査の回の記録(当時の名前)
  "FastInput", "MonitorLease", "LocalConfig.currentMachineName",
  // 書式の例(`FlowStep.defaultXxx` = 既定値の置き場の型)
  "FlowStep.defaultXxx",
]);

/** backtick 内の CamelCase の名前(と `型.メンバ`)のうち、照合先に無いもの。 */
export function unknownCodeNames(text, corpus, allow = new Set()) {
  const missing = new Set();
  for (const m of text.matchAll(/`([^`\n]+)`/g)) {
    for (const [, type, member] of m[1].matchAll(/\b([A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+)(?:\.([a-z][A-Za-z0-9]+))?/g)) {
      if (!corpus.has(type)) { if (!allow.has(type)) missing.add(type); }
      else if (member && !corpus.has(member) && !allow.has(`${type}.${member}`)) missing.add(`${type}.${member}`);
    }
  }
  return [...missing];
}

function codeCorpus() {
  const self = "vscode-fleetest/test/docsIndex.test.mjs";
  const files = execFileSync("git", ["ls-files"], { cwd: ROOT, encoding: "utf8" }).split("\n")
    .filter((f) => f && f !== self && !/^(docs|TestProjects|reports)\//.test(f) && !f.endsWith(".md")
      && !/\.(png|jpe?g|gif|mp4|mov|apk|zip|ttf|otf|ico|icns|car|a|dylib|jar)$/i.test(f));
  return identifiersOf(files.join("\n") + "\n"
    + files.map((f) => { try { return readFileSync(path.join(ROOT, f), "utf8"); } catch { return ""; } }).join("\n"));
}

/** 本文中の識別子の照合口。完全一致が無ければ識別子の一部としても探す(docs は `*RightEdge` のように
 *  名前の一部を書く)。本文全体の部分一致にしないのは速さのため(識別子の一覧だけを走査する)。 */
export function identifiersOf(text) {
  const ids = new Set(text.match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? []);
  const joined = [...ids].join("\n");
  return { has: (name) => ids.has(name) || joined.includes(name) };
}

/** 正典・手順・台帳・索引の docs と、CLAUDE.md・AGENTS.md・規則ファイル(リポジトリ直下からの相対パス)。 */
function canonicalTexts() {
  const kinds = new Map([...INDEX.split(/^## 書き方$/m)[0]
    .matchAll(/^\| \[[^\]]+\]\(([^)#]+)\) \| ([^|]+?) \|/gm)].map((m) => [m[1], m[2]]));
  const docs = ["README.md", ...maintainerDocs()].filter((d) => kinds.get(d) !== "記録" && !d.startsWith("maintainer-notes/"))
    .map((d) => `docs/${d}`);
  return ["CLAUDE.md", "AGENTS.md", ...walk(".claude/rules"), ...docs];
}

test("正典と規則が名指しするコードの名前は実在する", () => {
  const corpus = codeCorpus();
  assert.ok(corpus.has("StepExecutor") && corpus.has("ScenarioSandbox"), "照合先のコードが読めない");
  const files = canonicalTexts();
  assert.ok(files.includes("docs/design/profiles.md") && files.includes(".claude/rules/remote.md")
    && !files.includes("docs/remote-runner/records.md"), `対象の文書が読めない: ${files.length}`);
  const bad = files.flatMap((f) => unknownCodeNames(readFileSync(path.join(ROOT, f), "utf8"), corpus, EXTERNAL_CODE_NAMES)
    .map((n) => `${f}: ${n}`));
  assert.deepEqual(bad, [], "コードに無い名前(改名・撤去の後の残り。外部の名前なら EXTERNAL_CODE_NAMES に理由ごと足す)");
});

// ── 絞った e2e.sh の案内 ──
// e2e.sh / e2ex.sh / e2ey.sh は SUT・OS・モードで絞ってもスイート全体を回し、Scripts/test-scope-guard.py が
// 引数に関係なく断る。正典・規則が「絞って回す」手順として案内すると、その手順は必ず止まる(2026-10-25 に
// CLAUDE.md・android.md・operations.md で見つかった)。絞った確認は `fleetest run --scenario`。
// 通すのは、置き場・モードの指定(全体のまま)と、全実施・実測・実例の文脈の行だけ。

/** 絞り込みの引数を付けた e2e 系スクリプトを、全実施・実測の文脈なしに案内している行。 */
export function narrowedSuiteAdvice(text) {
  const SUITE_WIDE = new Set(["--local", "--align", "--on", "--performance", "--negative", "--retrain-classifiers", "--record"]);
  const CONTEXT = /FT_FULL_TEST=1|全実施|実測|実例|再現|赤|20\d\d-\d\d-\d\d/;
  return text.split("\n").filter((line) => {
    if (CONTEXT.test(line)) return false;
    return [...line.matchAll(/e2e[xy]?\.sh((?:\s+(?:--[\w<>-]+|[A-Z][\w]*))+)/g)]
      .some((m) => m[1].trim().split(/\s+/).some((a) => a.startsWith("--") && !SUITE_WIDE.has(a)));
  });
}

test("正典と規則は e2e.sh 系を絞って回す手順として案内しない", () => {
  const bad = canonicalTexts().flatMap((f) => narrowedSuiteAdvice(readFileSync(path.join(ROOT, f), "utf8"))
    .map((l) => `${f}: ${l.trim().slice(0, 100)}`));
  assert.deepEqual(bad, [], "絞った確認は `fleetest run --project <P> --profile <prof> --scenario <クラス>` で書く(全実施の文脈なら FT_FULL_TEST=1 を添える)");
});

test("名前と絞り込みの検出器は両方向に拾う", () => {
  const corpus = identifiersOf("struct ScenarioSandbox { static let commonRules = [] }; let iosFastInput = 1");
  assert.deepEqual(unknownCodeNames("`ScenarioSandbox.baseRules` と `DockerBackend` と `ScenarioSandbox.commonRules` と `*FastInput`", corpus),
    ["ScenarioSandbox.baseRules", "DockerBackend"]);
  assert.deepEqual(unknownCodeNames("`DockerBackend`", corpus, new Set(["DockerBackend"])), []);
  assert.deepEqual(narrowedSuiteAdvice("触ったら `Scripts/e2e.sh --cmp --android` を回す\n`Scripts/e2e.sh --local` で回す\n"
    + "実測(`Scripts/e2e.sh --ios`)\nFT_FULL_TEST=1 Scripts/e2ey.sh --flutter\n`e2ex.sh --on M1Ultra`"),
    ["触ったら `Scripts/e2e.sh --cmp --android` を回す"]);
});

test("§ と目次の検出器は形の崩れを拾う", () => {
  assert.equal(bareSectionRefs("MN-72 と §3.1 と §メモ"), 1);
  assert.deepEqual(tocMissing("# T\n\n## 目次\n\n- MN-1 a\n\n## MN-1 a\n## MN-2 b\n"), ["MN-2 b"]);
  assert.deepEqual(tocMissing("# T\n\n## 目次\n\n- 見出し\n\n## 見出し\n"), []);
});

test("冒頭の表と台帳の検出器は形の崩れを拾う", () => {
  const head = "# T\n\n| 種別 | 範囲 | 読む場面 | 扱わないこと |\n|---|---|---|---|\n| 記録 | a | b | c |\n";
  assert.equal(headerKind(head), "記録");
  assert.equal(headerKind("# T\n\n本文\n"), null);
  assert.deepEqual(ledgerItemsMissingState("### OI-1 a\n- 状態: 推測\n- 確認: c87b8c8f(2026-10-07)\n"), []);
  assert.deepEqual(ledgerItemsMissingState("### OI-2 b\n- 状態: たぶん\n- 確認: x\n### OI-3 c\n本文\n"), ["OI-2", "OI-3"]);
});

test("検出器は定義・参照・重複を拾う(常に空を返す形を落とす)", () => {
  const p = ["MN", "DS"];
  assert.deepEqual(idDefinitions("## MN-7 見出し\n### DS-1.2 別\n## MN-8\n", p), ["MN-7", "DS-1.2"]);
  assert.deepEqual(idReferences("→ MN-7(x)と DS-1.2、XMN-9 は別", p), ["MN-7", "DS-1.2"]);
  assert.deepEqual(prefixesFrom("### 節の ID\n\n| `MN` | a |\n| `DS` | b |\n"), ["MN", "DS"]);
  assert.ok(isExampleId("MN-0") && isExampleId("DS-0.1") && !isExampleId("MN-07") && !isExampleId("MN-10"));
});
