// 拡張が `--skip-build` を付けて呼ぶ `fleetest api <sub>` は、Swift 側でそのフラグを宣言していること。
// 宣言の無いサブコマンドへ渡すと ArgumentParser が未知の引数で落とし、拡張は JSON が読めないとだけ記録する
// (validate-profile がこの形で、設定 buildBeforeRun を OFF にした利用者ではプロファイルの検証が毎回失敗していた)。
// 呼び出しの組み立ては src/*.ts の `["api", "<sub>", …]` と同じ関数内の `"--skip-build"` で拾う。
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const REPO = path.join(ROOT, "..");
const SRC = path.join(ROOT, "src");
const SWIFT_DIR = path.join(REPO, "Sources/fleetest");

const SKIP_BUILD_DECL = /customLong\("skip-build"\)|var skipBuild\b/;

function swiftTexts() {
  return readdirSync(SWIFT_DIR).filter((f) => f.endsWith(".swift"))
    .map((name) => readFileSync(path.join(SWIFT_DIR, name), "utf8"));
}

/** `struct X: ParsableArguments` のうち本体に skipBuild の宣言がある型の名前(`@OptionGroup` で取り込まれる側。
 * run / api run は共通の宣言を RunCommonOptions に置くので、コマンドの本体だけを見ると宣言が見つからない)。 */
function optionGroupsWithSkipBuild(texts) {
  const names = new Set();
  for (const text of texts) {
    const marks = [...text.matchAll(/struct\s+(\w+)\s*:\s*ParsableArguments\b/g)];
    marks.forEach((m, i) => {
      const end = i + 1 < marks.length ? marks[i + 1].index : text.length;
      if (SKIP_BUILD_DECL.test(text.slice(m.index, end))) { names.add(m[1]); }
    });
  }
  return names;
}

/** commandName ごとに、その型の本体(次の commandName まで)に skipBuild の宣言があるか。本体が
 * `@OptionGroup var …: <型>` で取り込む型が宣言していれば、それも数える。 */
function swiftSubcommandsWithSkipBuild() {
  const result = new Map();
  const texts = swiftTexts();
  const groups = optionGroupsWithSkipBuild(texts);
  for (const text of texts) {
    const marks = [...text.matchAll(/commandName:\s*"([^"]+)"/g)];
    marks.forEach((m, i) => {
      const end = i + 1 < marks.length ? marks[i + 1].index : text.length;
      const body = text.slice(m.index, end);
      const viaGroup = [...body.matchAll(/@OptionGroup[^\n]*?:\s*(\w+)/g)].some((g) => groups.has(g[1]));
      const has = SKIP_BUILD_DECL.test(body) || viaGroup;
      result.set(m[1], (result.get(m[1]) ?? false) || has);
    });
  }
  return result;
}

/** src の各ファイルで、`"--skip-build"` を積む箇所の直前にある `["api", "<sub>"` を拾う。 */
function extensionSkipBuildCallers() {
  const callers = [];
  for (const name of readdirSync(SRC).filter((f) => f.endsWith(".ts"))) {
    const text = readFileSync(path.join(SRC, name), "utf8");
    for (const m of text.matchAll(/"--skip-build"/g)) {
      const before = text.slice(0, m.index);
      const api = [...before.matchAll(/\[\s*"api",\s*"([a-z-]+)"/g)].pop();
      if (api) callers.push({ file: name, sub: api[1] });
    }
  }
  return callers;
}

test("拡張が --skip-build を渡す api サブコマンドは、Swift 側でそのフラグを宣言している", () => {
  const swift = swiftSubcommandsWithSkipBuild();
  const callers = extensionSkipBuildCallers();
  assert.ok(callers.length >= 3, `走査が呼び出しに届いていない(${callers.length} 件)`);
  assert.ok(swift.size > 10, "走査が Sources/fleetest に届いていない");
  const missing = callers.filter((c) => swift.get(c.sub) !== true).map((c) => `${c.file}: api ${c.sub}`);
  assert.deepEqual(missing, [], "--skip-build を持たないサブコマンドへ渡している");
});

test("共通オプション(@OptionGroup)経由の宣言も数える —— run / api run の --skip-build は RunCommonOptions にある", () => {
  const swift = swiftSubcommandsWithSkipBuild();
  assert.equal(swift.get("run"), true, "run は RunCommonOptions の skipBuild を取り込んでいる");
  assert.ok(optionGroupsWithSkipBuild(swiftTexts()).has("RunCommonOptions"), "走査が RunCommonOptions に届いている");
});
