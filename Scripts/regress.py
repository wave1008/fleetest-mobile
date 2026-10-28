#!/usr/bin/env python3
# 回帰(E2E / E2EX / E2EY)を全マシンで1回の `fleetest run --target …` として回す(PT-8.1 → RR-8.2 へ統合)。
# 配り方(空いたマシンが次の対象を取る・終わり際はシナリオ単位で手伝う・待つほうが早ければ待つ)は fleetest run が持つ。
# ここが持つのは run の外側だけ:
#   1. 全マシンで SUT の鮮度を確かめて要ればビルド(各スクリプトの --build-only。マシン間は並列)。
#      リモートはアライン済みのコミットのランナーのクローンで起こす = **先に commit → Scripts/align.sh**
#   2. 回帰の対象の一覧(スイート × SUT × OS/モード)を --target に並べて fleetest run を1回
#   3. スクリプトが run ごとにしていた後始末: in-app の証人(E2E-CMP)・画像分類器を使えなかったシナリオを赤にする・
#      全部緑のときだけ検証済みの印・推奨(verification_watch.py stale)・--negative なら陽性対照
# 使えるマシン = この Mac + `fleetest remote machines list --json` の enabled のもの。各プロファイルの devices[].machine が
# 並べたマシンのデバイスだけが使われる(E2EX / E2EY のプロファイルにもリモートの項目がある。スクリプトは --runner local で回す)。
#
# 使い方:
#   FT_FULL_TEST=1 Scripts/regress.py                     # 3 スイート・既定モード(iOS は inapp-boost)+ Android
#   FT_FULL_TEST=1 Scripts/regress.py --ios-xcuitest      # 上に加えて iOS の xcuitest モードの対象も足す
#   FT_FULL_TEST=1 Scripts/regress.py --suites e2ex,e2ey  # スイートを絞る(--suts flutter,rn で SUT も。絞った回は印を書かない)
#   Scripts/regress.py --dry-run [--ios-xcuitest]         # 対象の一覧と撃つコマンドだけ出す。デバイスを使わない
# 全体の実行なので Scripts/test-scope-guard.py が FT_FULL_TEST=1 を求める(--dry-run は除く)。
import argparse, glob, json, os, shlex, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLEETEST = os.path.join(ROOT, ".build", "debug", "fleetest")
REMOTE_CLONE = "~/fleetest-runner/fleetest-mobile"
SSH_UNREACHABLE = 255

# スイート → (スクリプト, プロジェクトの接頭辞, SUT → 回す OS)。**各スクリプトの SUT の表と同じ**(片方だけ変えない)
SUITES = {
    "e2e": ("e2e.sh", "E2E", {"cmp": ("ios", "android"), "ios-native": ("ios",), "android-native": ("android",),
                              "flutter": ("ios", "android"), "rn": ("ios", "android")}),
    "e2ex": ("e2ex.sh", "E2EX", {"cmp": ("ios", "android"), "flutter": ("ios", "android"), "rn": ("ios", "android"),
                                 "android-native": ("android",), "ios-native": ("ios",)}),
    "e2ey": ("e2ey.sh", "E2EY", {"cmp": ("ios", "android"), "flutter": ("ios", "android"), "rn": ("ios", "android"),
                                 "android-native": ("android",), "ios-native": ("ios",)}),
}
PROJECT_SUFFIX = {"cmp": "CMP", "ios-native": "iOS", "android-native": "Android", "flutter": "Flutter", "rn": "RN"}
# in-app ブリッジだけの証人(@Draft = 通常の実行には入らない)。同期相手: Scripts/e2e.sh の run_inapp_witness
WITNESS = ("E2E-CMP", "絵の追いつきを待ってから撮る.S0010")


def build_targets(suites, xcuitest, suts=None):
    """(スイート, プロジェクト, プロファイル) の一覧。プロファイル名は各スクリプトが回すものと同じ"""
    targets = []
    for suite in suites:
        _, prefix, table = SUITES[suite]
        for sut, oses in table.items():
            if suts and sut not in suts:
                continue
            project = f"{prefix}-{PROJECT_SUFFIX[sut]}"
            if "ios" in oses:
                targets.append((suite, project, "ios-inapp-boost"))
                if xcuitest:
                    targets.append((suite, project, "ios-xcuitest"))
            if "android" in oses:
                targets.append((suite, project, "android"))
    return targets


def run_args(targets, record=False):
    args = [FLEETEST, "run"]
    for _, project, profile in targets:
        args += ["--target", f"{project}:{profile}"]
    return args + ["--set", f"record={'true' if record else 'false'}"]   # 回帰は既定で録画しない(e2e.sh 等の --record と同じ)


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


def command(host, args):
    if host is None:
        return args
    remote = f"cd {REMOTE_CLONE} && {' '.join(shlex.quote(a) for a in args)}"
    # ログイン shell(zsh -lc)= ~/.zprofile の PATH(Scripts/e2ex.sh の --on と同じ)。-tt = 手元が切れたら向こうへ HUP が届く
    return ["ssh", "-tt", "-o", "BatchMode=yes", host, f"zsh -lc {shlex.quote(remote)}"]


def run_logged(cmd, log_path, env):
    with open(log_path, "w") as log:
        return subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env).returncode


def prebuild_all(fleet, suites, suts, run_dir, env):
    """全マシンで SUT の鮮度確認とビルド(マシン間は並列・マシンの中はスイート順)。失敗したマシンの名前を返す"""
    failed = {}

    def prebuild(machine, host):
        for suite in suites:
            script = SUITES[suite][0]
            # 成果物は iOS のモードに依らない(同じ .app)ので、モードは渡さない
            args = [f"Scripts/{script}", "--build-only"] + [f"--{s}" for s in suts] + (["--local"] if suite == "e2e" else [])
            log = os.path.join(run_dir, f"build-{suite}@{machine}.log")
            code = run_logged(command(host, args), log, env)
            if code != 0:
                why = "届きません" if host is not None and code == SSH_UNREACHABLE else f"{suite} の SUT のビルドに失敗しました"
                failed[machine] = f"{why}({os.path.relpath(log, ROOT)})"
                return
        print(f"   ✅ {machine}: SUT はそろっています")
    threads = [threading.Thread(target=prebuild, args=fm) for fm in fleet]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return failed


def degraded_scenarios(projects, since):
    """見本はあるのに画像分類器を学習・読み込みできなかったシナリオ(注記 vision-classifier-unavailable)。
    checkIsON/OFF は黙って a11y へ倒れ、a11y で読める部品では緑のまま通るので赤にする(同期相手: Scripts/e2e.sh の run_profile)"""
    found = []
    for project in sorted(projects):
        for path in glob.glob(os.path.join(ROOT, "TestProjects", project, "results", "runs", "**", "scenarios", "*.json"),
                              recursive=True):
            if os.path.getmtime(path) < since:
                continue
            with open(path, errors="replace") as f:
                if '"vision-classifier-unavailable"' in f.read():
                    found.append(os.path.relpath(path, ROOT))
    return found


def main():
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description="回帰を全マシンで1回の fleetest run --target として回す")
    ap.add_argument("--suites", default="e2e,e2ex,e2ey")
    ap.add_argument("--suts", default="", help="SUT を絞る(cmp,ios-native,android-native,flutter,rn)。絞った回は検証済みの印を書かない")
    ap.add_argument("--ios-xcuitest", action="store_true", help="iOS の xcuitest モードの対象も足す")
    ap.add_argument("--negative", action="store_true", help="最後に陽性対照(Scripts/e2e-negative.sh)をこの Mac で回す")
    ap.add_argument("--skip-build", action="store_true", help="最初の SUT の鮮度確認・ビルドの段を飛ばす")
    ap.add_argument("--record", action="store_true", help="録画する(既定は --set record=false)")
    ap.add_argument("--dry-run", action="store_true", help="対象の一覧と撃つコマンドだけ出す(デバイスを使わない)")
    opts = ap.parse_args()
    suites = [s for s in opts.suites.split(",") if s]
    unknown = [s for s in suites if s not in SUITES]
    if unknown:
        sys.exit(f"❌ 知らないスイート: {unknown}(e2e / e2ex / e2ey)")
    suts = [s for s in opts.suts.split(",") if s]
    targets = build_targets(suites, opts.ios_xcuitest, suts)
    if not targets:
        sys.exit("❌ 回す対象がありません(--suites / --suts を見直してください)")
    witness = "e2e" in suites and ("e2e", WITNESS[0], "ios-inapp-boost") in targets

    if opts.dry_run:
        for suite, project, profile in targets:
            print(f"{suite}: {project}:{profile}")
        print(" ".join(shlex.quote(a) for a in run_args(targets, opts.record)))
        if witness:
            print(f"+ in-app の証人: {WITNESS[0]} / {WITNESS[1]}")
        return 0

    run_dir = os.path.join(ROOT, ".fleetest", "regress", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(run_dir, exist_ok=True)
    env = {**os.environ, "FT_FULL_TEST": "1"}
    started = time.time()
    fleet = machines()
    print(f"==> マシン: {', '.join(m for m, _ in fleet)} / 対象: {len(targets)} / ログ: {run_dir}")

    if not opts.skip_build:
        print("==> 段 1: 全マシンで SUT の鮮度を確かめ、要ればビルドします")
        failed = prebuild_all(fleet, suites, suts, run_dir, env)
        print(f"   段 1 の所要 {time.time() - started:.0f}s")
        if failed:
            # 欠けたマシンを外して回す口は fleetest run に無い(設定タブでマシンを無効にすれば外れる)
            for machine, why in failed.items():
                print(f"   ❌ {machine}: {why}")
            print("❌ SUT をそろえられないマシンがあるので回しません(直すか、設定タブでそのマシンを無効にしてください)")
            return 1

    # 配信を張ったままなら警告だけ出す(止めない)。赤があった回は最後にもう一度言う
    streaming = subprocess.run(["python3", os.path.join(ROOT, "Scripts", "streaming_check.py")],
                               capture_output=True, text=True).stdout
    print(streaming, end="")
    print("==> 段 2: fleetest run(空いたマシンが次の対象を取る)")
    run_started = time.time()
    run_ok = subprocess.run(run_args(targets, opts.record), cwd=ROOT, env=env).returncode == 0
    witness_ok = True
    if witness:
        print(f"\n═══ {WITNESS[0]} / ios-inapp-boost(in-app の証人: {WITNESS[1]})═══")
        witness_ok = subprocess.run([FLEETEST, "run", "--project", WITNESS[0], "--profile", "ios-inapp-boost",
                                     "--scenario", WITNESS[1], "--runner", "local", "--set", "record=false"],
                                    cwd=ROOT, env=env).returncode == 0
        print(f"{'✅' if witness_ok else '❌'} {WITNESS[0]} / ios-inapp-boost(証人)")
    degraded = degraded_scenarios({p for _, p, _ in targets}, run_started)
    if degraded:
        print("❌ 見本はあるのに画像分類器を使えなかったシナリオがあります(理由はシナリオ末尾の ⚠️ 行)")
        for path in degraded:
            print(f"   {path}")
    print(f"全体の所要: {(time.time() - started) / 60:.1f} 分")

    all_green = run_ok and witness_ok and not degraded
    if all_green and not suts:
        # スクリプトが全体を回したときと同じ印。iOS の対象をそのモードで全部回したスイートだけ書く
        for suite in suites:
            for mode, profile in (("inapp", "ios-inapp-boost"), ("xcuitest", "ios-xcuitest")):
                if not any(s == suite and p == profile for s, _, p in targets):
                    continue
                digest = subprocess.run([FLEETEST, "api", "bridge-sources", "--bridge", mode, "--digest"],
                                        capture_output=True, text=True)
                if digest.returncode != 0 or not digest.stdout.strip():
                    continue
                marker = os.path.join(ROOT, ".fleetest", f"{mode}-{suite}-verified")
                with open(marker, "w") as f:
                    f.write(digest.stdout)
                print(f"→ {suite} の {mode} 経路を検証済みとして記録しました({os.path.relpath(marker, ROOT)})")
    print("✅ 回帰 全て成功" if all_green else "❌ 回帰に失敗があります")
    if not all_green and streaming:
        print("   ⚠️ この回帰はモニターの配信を張ったまま回しました。Android の赤は配信の負荷の可能性があります(開始時の警告・OI-4)")

    stale = subprocess.run(["python3", os.path.join(ROOT, "Scripts", "verification_watch.py"), "stale"],
                           capture_output=True, text=True).stdout.strip()
    if stale:
        print("💡 見ている部分が前回 ✅ のときから変わった検証があります(回すのはユーザーの指示があるときだけ):")
        # 書式は Scripts/e2e.sh の末尾と同じ(片方だけ変えない)
        for line in stale.splitlines():
            unit, _, why = line.partition("\t")
            why = "未記録" if why == "never" else "変更あり"
            if unit.startswith("negative:"):
                rest = unit[len("negative:"):]
                project, path = rest.split("/", 1)[0], rest.rsplit("/", 1)[-1]
                print(f"   - 陽性対照 {rest}({why})→ Scripts/e2e-negative.sh --project {project} --file {path}")
            else:
                print(f"   - {unit}({why})→ Scripts/{unit}.sh")

    neg_failed = False
    if opts.negative:
        print("\n═══ 陽性対照(Scripts/e2e-negative.sh)═══")
        neg_failed = subprocess.run([os.path.join(ROOT, "Scripts", "e2e-negative.sh")], cwd=ROOT, env=env).returncode != 0
    return 0 if all_green and not neg_failed else 1


if __name__ == "__main__":
    sys.exit(main())
