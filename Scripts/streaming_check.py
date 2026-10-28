#!/usr/bin/env python3
# 回帰の開始時に、モニターの配信が張られていれば警告する(止めない = ユーザー決定)。
# 呼び手: Scripts/regress.py・e2e.sh・e2ex.sh・e2ey.sh。終了コードは常に 0(判定できなくても回帰は止めない)。
# 数えるのはプロセス表だけ: この機械の配信ヘルパー(fleetest-androidstream / fleetest-simstream)と、
# 拡張がリモートのデバイスへ張る `fleetest remote exec <マシン> -- api device-stream`。
# 配信を張ったままの Android Emulator は描画が数秒遅れ、テキストの可視性検証の notRendered や hold の時間切れの赤が出る(OI-4)
import collections
import re
import subprocess
import sys


def count_streams(commands):
    """プロセスのコマンド行の一覧 → {表示名: 本数}(純粋関数)"""
    counts = collections.Counter()
    for line in commands:
        exe = line.split(" ", 1)[0].rsplit("/", 1)[-1]
        if exe == "fleetest-androidstream":
            counts["この機械の Android"] += 1
        elif exe == "fleetest-simstream":
            counts["この機械の iOS"] += 1
        else:
            m = re.search(r"\bremote exec (\S+) -- api device-stream\b", line)
            if m:
                counts[m.group(1)] += 1
    return counts


def main():
    try:
        out = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return 0
    if out.returncode != 0:
        return 0
    counts = count_streams(out.stdout.splitlines())
    if not counts:
        return 0
    parts = "・".join(f"{name} {n} 台" for name, n in sorted(counts.items()))
    print(f"⚠️ モニターの配信が張られています({parts})。止めずに回します。")
    print("   配信の負荷で Android Emulator の描画が数秒遅れ、テキストの可視性検証(notRendered)や hold の時間切れの赤が出ることがあります(OI-4)。")
    print("   止めるなら、モニターの「ライブ更新」をオフにするか、fleetest monitor pause --for <分> を打ってから回してください。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
