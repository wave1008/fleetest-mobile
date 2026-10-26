#!/usr/bin/env python3
# 回帰(E2E / E2EX / E2EY)をマシン間の待ち行列で回す(docs/performance-tuning/guide.md PT-8.1 の案 A)。
# 仕事 = run 1 本ぶん(スイート × SUT × OS/モード)の既存スクリプトの呼び出し。1 台に 1 本ずつ、空いたマシンが次を取る
# (同じマシンで run を並べても CPU で頭打ち = PT-6)。仕事は所要の長い順(記録の無い仕事が先 = run の中の LPT と同じ)。
#
# 段:
#   1. 全マシンで SUT の鮮度を確かめて要ればビルド(各スクリプトの --build-only。マシン間は並列)。別のスイートの仕事を
#      取ったマシンで SUT のビルド(数分)が走ると短縮が消えるため
#   2. 待ち行列。各スクリプトは --as-part で呼ぶ = 検証済みの印・verification_watch の推奨・陽性対照はスクリプトでは扱わない
#      (一部だけで「全部成功」と書かないため)
#   3. 全部の仕事が緑のときだけ、この Mac の検証済みの印を書く(スクリプトが全体で回したときと同じ印・同じ digest)。
#      推奨(verification_watch.py stale)を出す。--negative なら陽性対照をこの Mac で回す
#
# 使えるマシン = この Mac + `fleetest remote machines list --json` の enabled のもの(無効のマシンは使わない)。
# リモートはアライン済みのコミットのランナーのクローン(~/fleetest-runner/fleetest-mobile)でスクリプトを起こす
# (Scripts/e2ex.sh の --on と同じ起こし方)。**先に commit → Scripts/align.sh**。
# 所要の記録は .fleetest/regress-durations.json(仕事 × マシン → 秒。最後の 1 回)。
#
# 使い方:
#   FT_FULL_TEST=1 Scripts/regress.py                     # 3 スイート・既定モード(iOS は inapp-boost)+ Android
#   FT_FULL_TEST=1 Scripts/regress.py --ios-xcuitest      # 上に加えて iOS の xcuitest モードの仕事も足す
#   FT_FULL_TEST=1 Scripts/regress.py --suites e2ex,e2ey  # スイートを絞る(--suts flutter,rn で SUT も。絞った回は印を書かない)
#   Scripts/regress.py --dry-run [--ios-xcuitest]         # 割り振りの見込み(案 B)だけ出す。デバイスを使わない
# 全体の実行なので Scripts/test-scope-guard.py が FT_FULL_TEST=1 を求める(--dry-run は除く)。
import argparse, heapq, json, os, shlex, subprocess, sys, threading, time
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLEETEST = os.path.join(ROOT, ".build", "debug", "fleetest")
LEDGER = os.path.join(ROOT, ".fleetest", "regress-durations.json")
REMOTE_CLONE = "~/fleetest-runner/fleetest-mobile"
SSH_UNREACHABLE = 255

# スイート → (スクリプト, SUT → 回す OS)。**各スクリプトの SUT の表と同じ**(片方だけ変えない)
SUITES = {
    "e2e": ("e2e.sh", {"cmp": ("ios", "android"), "ios-native": ("ios",), "android-native": ("android",),
                       "flutter": ("ios", "android"), "rn": ("ios", "android")}),
    "e2ex": ("e2ex.sh", {"cmp": ("ios", "android"), "flutter": ("ios", "android"), "rn": ("ios", "android"),
                         "android-native": ("android",), "ios-native": ("ios",)}),
    "e2ey": ("e2ey.sh", {"cmp": ("ios", "android"), "flutter": ("ios", "android"), "rn": ("ios", "android"),
                         "android-native": ("android",), "ios-native": ("ios",)}),
}


class Job:
    def __init__(self, suite, sut, target):
        self.suite, self.sut, self.target = suite, sut, target   # target = ios-inapp-boost / ios-xcuitest / android
        self.key = f"{suite}/{sut}/{target}"
        self.requeued = False

    def args(self):
        script, _ = SUITES[self.suite]
        a = [f"Scripts/{script}", f"--{self.sut}", "--as-part"]
        a += ["--android"] if self.target == "android" else ["--ios", f"--{self.target}"]
        if self.suite == "e2e":
            a.append("--local")   # e2e.sh は --local が無いとフリートへ配る(ここではマシンごとに自分の台で回す)
        return a


def build_jobs(suites, xcuitest, suts=None):
    jobs = []
    for suite in suites:
        for sut, oses in SUITES[suite][1].items():
            if suts and sut not in suts:
                continue
            if "ios" in oses:
                jobs.append(Job(suite, sut, "ios-inapp-boost"))
                if xcuitest:
                    jobs.append(Job(suite, sut, "ios-xcuitest"))
            if "android" in oses:
                jobs.append(Job(suite, sut, "android"))
    return jobs


def machines():
    out = subprocess.run([FLEETEST, "remote", "machines", "list", "--json"], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"❌ fleetest remote machines list --json が失敗しました: {out.stderr.strip()}")
    doc = json.loads(out.stdout)
    found = []
    if doc.get("local", {}).get("enabled", True):
        found.append(("local", None))
    found += [(h["machine"], h["host"]) for h in doc.get("hosts", []) if h.get("enabled")]
    return found


def load_ledger():
    try:
        with open(LEDGER) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_ledger(ledger):
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    tmp = LEDGER + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ledger, f, indent=1, sort_keys=True)
    os.replace(tmp, LEDGER)


def estimate(ledger, job, machine):
    """その仕事のそのマシンでの所要の見込み[秒]。そのマシンの記録 → 他のマシンの記録の平均 → None(記録なし)"""
    rec = ledger.get(job.key, {})
    if machine in rec:
        return rec[machine]
    return sum(rec.values()) / len(rec) if rec else None


def pick(queue, ledger, machine):
    """空いたマシンが取る仕事: 記録の無い仕事が先、次にそのマシンでの見込みが長い順(LPT)"""
    def rank(job):
        e = estimate(ledger, job, machine)
        return (0, 0) if e is None else (1, -e)
    return min(queue, key=rank) if queue else None


def simulate(jobs, names, ledger):
    """案 B: 見込みで割り振った場合の各マシンの終わり(秒)。記録の無い仕事は記録のある仕事の平均で置く"""
    known = [e for j in jobs for m in names if (e := estimate(ledger, j, m)) is not None]
    fallback = sum(known) / len(known) if known else 150.0
    # 同時に空いたら一覧の順(この Mac が先頭)= 実際の実行で作業者が動き出す順
    free = [(0.0, i, m) for i, m in enumerate(names)]
    heapq.heapify(free)
    queue, plan = list(jobs), {m: [] for m in names}
    while queue:
        t, i, m = heapq.heappop(free)
        job = pick(queue, ledger, m)
        queue.remove(job)
        d = estimate(ledger, job, m) or fallback
        plan[m].append((job.key, d))
        heapq.heappush(free, (t + d, i, m))
    return plan


def command(machine, host, args):
    if host is None:
        return args, ROOT
    remote = f"cd {REMOTE_CLONE} && {' '.join(shlex.quote(a) for a in args)}"
    # ログイン shell(zsh -lc)= ~/.zprofile の PATH(Scripts/e2ex.sh の --on と同じ)。-tt = 手元が切れたら向こうへ HUP が届く
    return ["ssh", "-tt", "-o", "BatchMode=yes", host, f"zsh -lc {shlex.quote(remote)}"], ROOT


def run_logged(cmd, cwd, log_path, env):
    with open(log_path, "w") as log:
        return subprocess.run(cmd, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env).returncode


def main():
    ap = argparse.ArgumentParser(description="回帰をマシン間の待ち行列で回す(PT-8.1)")
    ap.add_argument("--suites", default="e2e,e2ex,e2ey")
    ap.add_argument("--suts", default="", help="SUT を絞る(cmp,ios-native,android-native,flutter,rn)。絞った回は検証済みの印を書かない")
    ap.add_argument("--ios-xcuitest", action="store_true", help="iOS の xcuitest モードの仕事も足す")
    ap.add_argument("--negative", action="store_true", help="最後に陽性対照(Scripts/e2e-negative.sh)をこの Mac で回す")
    ap.add_argument("--skip-build", action="store_true", help="最初の SUT の鮮度確認・ビルドの段を飛ばす")
    ap.add_argument("--dry-run", action="store_true", help="割り振りの見込みだけ出す(デバイスを使わない)")
    opts = ap.parse_args()
    suites = [s for s in opts.suites.split(",") if s]
    unknown = [s for s in suites if s not in SUITES]
    if unknown:
        sys.exit(f"❌ 知らないスイート: {unknown}(e2e / e2ex / e2ey)")

    suts = [s for s in opts.suts.split(",") if s]
    jobs = build_jobs(suites, opts.ios_xcuitest, suts)
    ledger = load_ledger()
    fleet = machines()
    names = [m for m, _ in fleet]

    if opts.dry_run:
        plan = simulate(jobs, names, ledger)
        for m in names:
            total = sum(d for _, d in plan[m])
            print(f"{m}: {len(plan[m])} 本・見込み {total / 60:.1f} 分")
            for key, d in plan[m]:
                print(f"   {key}  {d:.0f}s")
        print(f"全体の見込み: {max(sum(d for _, d in p) for p in plan.values()) / 60:.1f} 分(記録の無い仕事は平均で置いた)")
        return 0

    run_dir = os.path.join(ROOT, ".fleetest", "regress", datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.makedirs(run_dir, exist_ok=True)
    env = {**os.environ, "FT_FULL_TEST": "1"}
    started = time.time()
    print(f"==> マシン: {', '.join(names)} / 仕事: {len(jobs)} 本 / ログ: {run_dir}")

    # 段 1: SUT の鮮度確認とビルド(マシン間は並列・マシンの中はスイート順)
    dead = set()
    if not opts.skip_build:
        print("==> 段 1: 全マシンで SUT の鮮度を確かめ、要ればビルドします")

        def prebuild(machine, host):
            for suite in suites:
                script = SUITES[suite][0]
                # 成果物は iOS のモードに依らない(同じ .app)ので、モードは渡さない
                args = [f"Scripts/{script}", "--build-only"] + [f"--{s}" for s in suts] + (["--local"] if suite == "e2e" else [])
                cmd, cwd = command(machine, host, args)
                code = run_logged(cmd, cwd, os.path.join(run_dir, f"build-{suite}@{machine}.log"), env)
                if code == SSH_UNREACHABLE:
                    print(f"   ❌ {machine}: 届きません(以後この機械は使いません)")
                    dead.add(machine)
                    return
                if code != 0:
                    print(f"   ❌ {machine}: {suite} の SUT のビルドに失敗しました(build-{suite}@{machine}.log)。以後この機械は使いません")
                    dead.add(machine)
                    return
            print(f"   ✅ {machine}: SUT はそろっています")
        threads = [threading.Thread(target=prebuild, args=fm) for fm in fleet]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        print(f"   段 1 の所要 {time.time() - started:.0f}s")

    # 段 2: 待ち行列
    queue = list(jobs)
    lock = threading.Lock()
    results = {}

    def worker(machine, host):
        while True:
            with lock:
                if machine in dead:
                    return
                job = pick(queue, ledger, machine)
                if job is None:
                    return
                queue.remove(job)
            log = os.path.join(run_dir, f"{job.key.replace('/', '_')}@{machine}.log")
            t0 = time.time()
            print(f"▶ {job.key} @ {machine}")
            cmd, cwd = command(machine, host, job.args())
            code = run_logged(cmd, cwd, log, env)
            elapsed = time.time() - t0
            with lock:
                if code == SSH_UNREACHABLE:
                    # マシンに届かない = 仕事は回っていない。一度だけ待ち行列へ戻して他のマシンに任せる
                    dead.add(machine)
                    if not job.requeued:
                        job.requeued = True
                        queue.append(job)
                        print(f"   ⚠️ {machine} に届きません。{job.key} を待ち行列へ戻し、以後この機械は使いません")
                    else:
                        results[job.key] = (machine, False, elapsed, log)
                    return
                results[job.key] = (machine, code == 0, elapsed, log)
                ledger.setdefault(job.key, {})[machine] = round(elapsed)
                save_ledger(ledger)
                print(f"{'✅' if code == 0 else '❌'} {job.key} @ {machine}  {elapsed:.0f}s")

    print("==> 段 2: 待ち行列(空いたマシンが長い仕事から取る)")
    threads = [threading.Thread(target=worker, args=fm) for fm in fleet if fm[0] not in dead]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # 段 3: まとめ
    missing = [j.key for j in jobs if j.key not in results]
    failed = [k for k, (_, ok, _, _) in results.items() if not ok]
    print("")
    for j in jobs:
        if j.key in results:
            m, ok, e, log = results[j.key]
            print(f"{'✅' if ok else '❌'} {j.key} @ {m}  {e:.0f}s  {os.path.relpath(log, ROOT)}")
        else:
            print(f"⚠️ {j.key}: 回せませんでした(使えるマシンが残っていない)")
    print(f"全体の所要: {(time.time() - started) / 60:.1f} 分")

    all_green = not failed and not missing
    if all_green and not suts:
        # スクリプトが全体を回したときと同じ印。iOS の仕事をそのモードで全部回したスイートだけ書く(一部の SUT だけの回では書かない)
        marker_suffix = {"e2e": "e2e", "e2ex": "e2ex", "e2ey": "e2ey"}
        for suite in suites:
            for mode, target in (("inapp", "ios-inapp-boost"), ("xcuitest", "ios-xcuitest")):
                if not any(j.suite == suite and j.target == target for j in jobs):
                    continue
                digest = subprocess.run([FLEETEST, "api", "bridge-sources", "--bridge", mode, "--digest"],
                                        capture_output=True, text=True)
                if digest.returncode != 0 or not digest.stdout.strip():
                    continue
                marker = os.path.join(ROOT, ".fleetest", f"{mode}-{marker_suffix[suite]}-verified")
                with open(marker, "w") as f:
                    f.write(digest.stdout)
                print(f"→ {suite} の {mode} 経路を検証済みとして記録しました({os.path.relpath(marker, ROOT)})")
    if all_green:
        print("✅ 回帰 全て成功")
    else:
        print(f"❌ 回帰に失敗があります(赤 {len(failed)} 本・回せなかった {len(missing)} 本)")

    stale = subprocess.run(["python3", os.path.join(ROOT, "Scripts", "verification_watch.py"), "stale"],
                           capture_output=True, text=True).stdout.strip()
    if stale:
        print("💡 見ている部分が前回 ✅ のときから変わった検証があります(回すのはユーザーの指示があるときだけ):")
        for line in stale.splitlines():
            print(f"   - {line}")

    neg_failed = False
    if opts.negative:
        print("\n═══ 陽性対照(Scripts/e2e-negative.sh)═══")
        neg_failed = subprocess.run([os.path.join(ROOT, "Scripts", "e2e-negative.sh")], cwd=ROOT, env=env).returncode != 0
    return 0 if all_green and not neg_failed else 1


if __name__ == "__main__":
    sys.exit(main())
