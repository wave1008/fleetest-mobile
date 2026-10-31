#!/usr/bin/env python3
# 修正の関門: 所見の再現手順(Scripts/replay-cases/*.json)を fleetest-mcp へ撃ち、SUT の表示で答え合わせする。
# 手順と規律は docs/verification/testing.md「修正の関門」。ケースの形は Scripts/replay-cases/README.md。
#   Scripts/replay.py --udid <iOS の udid> | --serial <Android の serial> [--case <id>] [--rounds N] [--mcp <path>]
#                     [--suite baseline] [--record <ndjson>]
# --suite baseline は回をまたいで比べる固定の課題(既定は再生ケース)。--record は形ごとの結果を1行ずつ足す(比較の元データ)。
# 終了コード: 0 = 全部通った / 1 = 通らない形がある / 2 = 回せなかった(宛先・ケース・MCP の問題)
# 宛先は明示の1台だけ(他の run の端末へ向かわせない)。MCP はこのプロセスの子で、終わるときに必ず止める(使用中の印を残さない)。
import argparse, glob, json, os, re, select, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "Scripts", "replay-cases")
DEFAULT_MCP = os.path.join(ROOT, ".build", "out", "Products", "Debug", "fleetest-mcp")
PERSONAL_DEVICES = ("iPhone wave", "iPhone snb")   # 個人の端末の登録名。操作しない(ft_status の device は実機だと機種名だけなので ft_list_devices で引く)
CALL_TIMEOUT = 180   # 秒。ft_launch の起こし直しの上限より長く。尽きたら「回せなかった」
REF = re.compile(r"^\$ref:(.+)$")


class CannotRun(Exception):
    pass


class MCP:
    def __init__(self, path):
        if not os.path.exists(path):
            raise CannotRun(f"fleetest-mcp がありません: {path}")
        self.process = subprocess.Popen([path], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0)
        self.buffer = b""
        self.next_id = 0
        try:
            self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "replay", "version": "1"}})
            self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except BaseException:
            self.close()
            raise

    def write(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode())

    def request(self, method, params):
        self.next_id += 1
        self.write({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        deadline = time.time() + CALL_TIMEOUT
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    reply = json.loads(line)
                except ValueError:
                    continue
                if reply.get("id") == self.next_id:
                    return reply
            ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.time()))
            if not ready:
                raise CannotRun(f"{method} が {CALL_TIMEOUT} 秒返りません")
            chunk = os.read(self.process.stdout.fileno(), 1 << 22)
            if not chunk:
                raise CannotRun("fleetest-mcp が終了しました")
            self.buffer += chunk

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments}).get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", []))
        return text, bool(result.get("isError"))

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def resolve_refs(arguments, tree):
    """`$ref:<id>` を直近の ft_snapshot の木の ref 番号へ置き換える(ref は木ごとに振り直される)"""
    resolved = {}
    for key, value in arguments.items():
        match = REF.match(value) if isinstance(value, str) else None
        if match:
            found = re.search(rf"\[(\d+)\][^\n]*id={re.escape(match.group(1))}\b", tree)
            if not found:
                raise ValueError(f"木に id={match.group(1)} がありません")
            value = int(found.group(1))
        resolved[key] = value
    return resolved


def refuse_unless_test_device(mcp, identifier):
    """確かめられない宛先には撃たない。行に名前と識別子が並ぶ ft_list_devices の本文を引く"""
    listing, is_error = mcp.tool("ft_list_devices", {})
    if is_error:
        raise CannotRun(f"端末の一覧を読めません: {listing[:240]}")
    lines = [line for line in listing.splitlines() if identifier in line]
    if not lines:
        raise CannotRun(f"端末の一覧に {identifier} がありません(個人の端末でないと確かめられない)")
    if any(name in line for line in lines for name in PERSONAL_DEVICES):
        raise CannotRun("個人の端末なので回しません")


def upper_bound(rounds):
    """失敗 0/rounds のときの失敗率の 95% 信頼の上限"""
    return 1 - 0.05 ** (1 / rounds)


def kill_app(target, bundle_id):
    """故障の注入: 宛先の1台のアプリだけを止める(ツールの ft_terminate を通すと印が残って別の経路になる)"""
    if "udid" in target:
        cmd = ["xcrun", "simctl", "terminate", target["udid"], bundle_id]
    else:
        cmd = ["adb", "-s", target["serial"], "shell", "am", "force-stop", bundle_id]
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    if done.returncode != 0:
        raise CannotRun(f"故障の注入が失敗: {done.stderr.strip()[-200:]}")


def round_problems(mcp, target, form):
    """1周撃って、答え合わせの食い違いを返す(空 = 通った)"""
    problems, tree, reply = [], "", ""
    for step in form["steps"]:
        name, arguments = step
        if name == "$killApp":
            kill_app(target, arguments["bundleId"])
            time.sleep(arguments.get("seconds", 1))
            continue
        try:
            arguments = resolve_refs(arguments, tree)
        except ValueError as error:
            return [str(error)]
        text, is_error = mcp.tool(name, {**arguments, **target})
        reply = text
        if name == "ft_snapshot":
            tree = text
        if is_error and not form.get("allowErrors"):
            return [f"{name} が失敗: {text[:240]}"]
    problems += [f"応答にあってはいけない: {s}" for s in form.get("replyReject", []) if s in reply]
    problems += [f"応答に無い: {s}" for s in form.get("replyExpect", []) if s not in reply]
    if form.get("replyOnly"):
        return problems
    time.sleep(form.get("settleSeconds", 1))
    final, is_error = mcp.tool("ft_snapshot", target)
    if is_error:
        return [f"答え合わせの ft_snapshot が失敗: {final[:240]}"]
    problems += [f"無い: {s}" for s in form.get("expect", []) if s not in final]
    problems += [f"あってはいけない: {s}" for s in form.get("reject", []) if s in final]
    return problems


def run_case(mcp, target, case, rounds_override, record=None):
    failed_forms = 0
    for name, arguments in case.get("setup", []):
        text, is_error = mcp.tool(name, {**arguments, **target})
        if is_error:
            raise CannotRun(f"{case['id']} の準備 {name} が失敗: {text[:240]}")
    for form in case["forms"]:
        rounds = rounds_override or case.get("rounds", 10)
        failures = []
        for i in range(rounds):
            for name, arguments in case.get("reset", []):
                text, is_error = mcp.tool(name, {**arguments, **target})
                if is_error:
                    raise CannotRun(f"{case['id']} の戻し {name} が失敗: {text[:240]}")
            time.sleep(case.get("resetSeconds", 0.3))
            problems = round_problems(mcp, target, form)
            if problems:
                failures.append((i + 1, problems))
        label = f"{case['id']} / {form['name']}"
        if record:
            record({"case": case["id"], "form": form["name"], "rounds": rounds, "failures": len(failures)})
        if failures:
            failed_forms += 1
            print(f"❌ {label}: {len(failures)}/{rounds} 周で食い違い")
            for i, problems in failures[:3]:
                print(f"   周 {i}: {'; '.join(problems)}")
        else:
            print(f"✅ {label}: 0/{rounds}(95% 上限 {upper_bound(rounds):.1%})")
            if not case.get("redConfirmed") and case.get("suite") != "baseline":
                print(f"   ⚠️ 直しを外した版で赤を確かめていないケース: この緑は直った証拠にならない。{case.get('redNote', '')}")
    return failed_forms


def recorder(path):
    """--record の先へ足す関数。行にコミットとマシンの状態を添える(同じ条件の回だけを比べるため)"""
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    state = subprocess.run([sys.executable, os.path.join(ROOT, "Scripts", "machine-state.py")],
                           capture_output=True, text=True).stdout.strip()

    def write(row):
        with open(path, "a") as f:
            f.write(json.dumps({**row, "commit": head, "machine": json.loads(state) if state else None},
                               ensure_ascii=False) + "\n")
    return write


def load_cases(selected, platform, suite=None):
    cases = []
    for path in sorted(glob.glob(os.path.join(CASES, "*.json"))):
        with open(path) as f:
            case = json.load(f)
        if selected and case["id"] not in selected:
            continue
        if case["platform"] == platform and case.get("suite") == suite:
            cases.append(case)
    missing = set(selected or []) - {c["id"] for c in cases}
    if missing:
        raise CannotRun(f"この OS のケースにありません: {sorted(missing)}")
    return cases


def main():
    parser = argparse.ArgumentParser(description="所見の再現手順を撃って答え合わせする")
    device = parser.add_mutually_exclusive_group(required=True)
    device.add_argument("--udid")
    device.add_argument("--serial")
    parser.add_argument("--case", action="append", help="ケースの id(繰り返し可。省くとその OS の全ケース)")
    parser.add_argument("--rounds", type=int, help="形ごとの周回(省くとケースの rounds)")
    parser.add_argument("--mcp", default=DEFAULT_MCP)
    parser.add_argument("--suite", choices=["baseline"], help="baseline = 回をまたいで比べる固定の課題")
    parser.add_argument("--record", help="形ごとの結果を足す ndjson")
    options = parser.parse_args()
    platform = "ios" if options.udid else "android"
    target = {"platform": platform, **({"udid": options.udid} if options.udid else {"serial": options.serial})}
    mcp = None
    try:
        cases = load_cases(options.case, platform, options.suite)
        if not cases:
            raise CannotRun(f"{platform} のケースがありません")
        mcp = MCP(options.mcp)
        refuse_unless_test_device(mcp, options.udid or options.serial)
        status, is_error = mcp.tool("ft_status", target)
        if is_error:
            raise CannotRun(f"宛先に届きません: {status[:240]}")
        record = recorder(options.record) if options.record else None
        failed = sum(run_case(mcp, target, case, options.rounds, record) for case in cases)
    except (CannotRun, OSError, ValueError) as error:   # 子の死(BrokenPipe)・壊れた応答も「回せなかった」= 赤と区別する
        print(f"⚠️ 回せませんでした: {error}")
        return 2
    finally:
        if mcp:
            mcp.close()
    print("✅ 全部通りました" if not failed else f"❌ {failed} 形が通りません")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
