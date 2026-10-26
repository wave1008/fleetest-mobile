// Scripts/regress.py(回帰をマシン間の待ち行列で回すまとめ役・PT-8.1)の2つの約束を固定する:
// ①まとめ役の SUT の表(SUITES)は各スクリプトの既定の SUT の一覧と同じ(片方だけ変えると仕事が黙って欠ける・知らない SUT を撃つ)
// ②空いたマシンが取る仕事は、記録の無い仕事が先・次にそのマシンでの見込みが長い順(LPT)

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

test('まとめ役の SUT の表は各スクリプトの既定の SUT の一覧と同じ', () => {
  const suites = py('{k: [v[0], sorted(v[1].keys())] for k, v in m.SUITES.items()}')
  for (const [suite, [script, suts]] of Object.entries(suites)) {
    assert.deepEqual(suts, scriptSuts(script), `${suite}(${script})`)
  }
})

test('仕事は SUT ごとに回す OS・モードの数だけでき、xcuitest は指定したときだけ足す', () => {
  const plain = py('[j.key for j in m.build_jobs(["e2ey"], False)]')
  assert.ok(plain.includes('e2ey/rn/ios-inapp-boost') && plain.includes('e2ey/rn/android'))
  assert.ok(!plain.some((k) => k.endsWith('ios-xcuitest')))
  assert.ok(!plain.includes('e2ey/android-native/ios-inapp-boost'), 'Android だけの SUT に iOS の仕事を作らない')
  const withXcui = py('[j.key for j in m.build_jobs(["e2ey"], True)]')
  assert.equal(withXcui.length - plain.length, 4, 'iOS を持つ 4 SUT に xcuitest の仕事を1本ずつ')
  const narrowed = py('[j.key for j in m.build_jobs(["e2e", "e2ex"], False, ["flutter"])]')
  assert.deepEqual(narrowed.sort(), ['e2e/flutter/android', 'e2e/flutter/ios-inapp-boost',
    'e2ex/flutter/android', 'e2ex/flutter/ios-inapp-boost'])
})

test('仕事の引数: スイートのスクリプト・SUT・OS とモード・--as-part(e2e.sh は --local も)', () => {
  const args = py('[j.args() for j in m.build_jobs(["e2e"], True, ["cmp"])]')
  assert.deepEqual(args, [
    ['Scripts/e2e.sh', '--cmp', '--as-part', '--ios', '--ios-inapp-boost', '--local'],
    ['Scripts/e2e.sh', '--cmp', '--as-part', '--ios', '--ios-xcuitest', '--local'],
    ['Scripts/e2e.sh', '--cmp', '--as-part', '--android', '--local'],
  ])
})

test('空いたマシンは記録の無い仕事を先に、次にそのマシンでの見込みが長い仕事を取る', () => {
  const ledger = '{"e2ey/cmp/android": {"local": 100}, "e2ey/rn/android": {"local": 300, "M1Max": 50}}'
  const keys = '["e2ey/cmp/android", "e2ey/rn/android", "e2ey/flutter/android"]'
  const jobs = `[j for j in m.build_jobs(["e2ey"], False) if j.key in ${keys}]`
  assert.equal(py(`m.pick(${jobs}, ${ledger}, "local").key`), 'e2ey/flutter/android', '記録の無い仕事が先')
  const known = `[j for j in ${jobs} if j.key != "e2ey/flutter/android"]`
  assert.equal(py(`m.pick(${known}, ${ledger}, "local").key`), 'e2ey/rn/android', 'このマシンで長い仕事')
  assert.equal(py(`m.pick(${known}, ${ledger}, "M1Max").key`), 'e2ey/cmp/android',
    'そのマシンの記録が短ければ、他のマシンの記録(cmp = 100)のほうが長い')
})
