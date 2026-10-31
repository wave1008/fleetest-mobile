// RecordingSupport.swift
// デバイス録画(VideoRecordingCoordinator 系)が使う小さな共通部品。

import Foundation

/// ISO8601(小数秒付き・ミリ秒精度)。RunRecorder 等の他所と違いミリ秒まで要るのは、
/// 動画の startedAt/失敗ステップの at を壁時計と突き合わせる用途のため(単一プロセス内の
/// 複数録画・複数ステップが同一秒に収まりうる)。ISO8601DateFormatter はインスタンスを
/// 使い回さず都度生成する(このコードベースの既存慣習に合わせる。OcclusionVerifier.swift 参照)
public enum ISO8601Millis {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// string(from:) の逆変換(壁時計→ソース位置の区分計算に使う)。解析失敗時 nil
    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

/// 非同期処理(op)と期限(seconds)のレース。実体は `DeadlineRace.first`。**withTaskGroup は使わない**: 録画プロセスが
/// 生きている限り stderr 読み取り等の敗者 task が終わらず、スコープの終端の待ちで期限が効かなくなる
func raceWithDeadline<T: Sendable>(
    seconds: Double, onTimeout: T, _ op: @escaping @Sendable () async -> T
) async -> T {
    await DeadlineRace.first(seconds: seconds, onTimeout: onTimeout, op)
}
