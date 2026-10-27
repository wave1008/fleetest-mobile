// Scripts/regress.py(回帰を全マシンで1回の `fleetest run --target …` として回す包み)の約束を固定する:
// ①包みの SUT の表(SUITES)は各スクリプトの既定の SUT の一覧と同じ(片方だけ変えると対象が黙って欠ける・知らない SUT を撃つ)
// ②対象(プロジェクト:プロファイル)は各スクリプトが回すものと同じで、fleetest run の --target に並ぶ

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const REGRESS = join(ROOT, 'Scripts/regress.py')

/** regress.py をモジュールとして読み込み、Python の式を評価して JSON で返す */
function py(expr) {
  const code = [
    'import importlib.util, json, sys',
    `spec = importlib.util.spec_from_file_location("regress", ${JSON.stringify(REGRESS)})`,
    'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)',
    `print(json.dumps(${expr}))`,
  ].join('\n')
  return JSON.parse(execFileSync('python3', ['-c', code], { encoding: 'utf8' }))
}

/** スクリプトの `[ -n "$SUTS" ] || SUTS="…"` の既定の一覧 */
function scriptSuts(script) {
  const source = readFileSync(join(ROOT, 'Scripts', script), 'utf8')
  const m = source.match(/\[ -n "\$SUTS" \] \|\| SUTS="([^"]+)"/)
  assert.ok(m, `${script} から既定の SUT の一覧を読めない`)
  return m[1].split(/\s+/).sort()
}

test('包みの SUT の表は各スクリプトの既定の SUT の一覧と同じ', () => {
  const suites = py('{k: [v[0], sorted(v[2].keys())] for k, v in m.SUITES.items()}')
  for (const [suite, [script, suts]] of Object.entries(suites)) {
    assert.deepEqual(suts, scriptSuts(script), `${suite}(${script})`)
  }
})

test('対象は SUT ごとに回す OS・モードの数だけでき、xcuitest は指定したときだけ足す', () => {
  const plain = py('[f"{p}:{q}" for _, p, q in m.build_targets(["e2ey"], False)]')
  assert.ok(plain.includes('E2EY-RN:ios-inapp-boost') && plain.includes('E2EY-RN:android'))
  assert.ok(!plain.some((k) => k.endsWith('ios-xcuitest')))
  assert.ok(!plain.includes('E2EY-Android:ios-inapp-boost'), 'Android だけの SUT に iOS の対象を作らない')
  const withXcui = py('[p for _, p, _ in m.build_targets(["e2ey"], True)]')
  assert.equal(withXcui.length - plain.length, 4, 'iOS を持つ 4 SUT に xcuitest の対象を1つずつ')
  const narrowed = py('[f"{p}:{q}" for _, p, q in m.build_targets(["e2e", "e2ex"], False, ["flutter"])]')
  assert.deepEqual(narrowed.sort(), ['E2E-Flutter:android', 'E2E-Flutter:ios-inapp-boost',
    'E2EX-Flutter:android', 'E2EX-Flutter:ios-inapp-boost'])
})

test('対象のプロファイルはそのプロジェクトに実在する', () => {
  const all = py('[[p, q] for _, p, q in m.build_targets(["e2e", "e2ex", "e2ey"], True)]')
  for (const [project, profile] of all) {
    const path = join(ROOT, 'TestProjects', project, 'profiles', 'runs', `${profile}.json`)
    assert.ok(readFileSync(path, 'utf8').length > 0, path)
  }
})

test('fleetest run の引数: 対象ごとに --target・回帰は録画しない', () => {
  const args = py('m.run_args(m.build_targets(["e2e"], False, ["cmp"]))').slice(1)
  assert.deepEqual(args, ['run', '--target', 'E2E-CMP:ios-inapp-boost', '--target', 'E2E-CMP:android',
    '--set', 'record=false'])
})
