// 同期のブロッキング処理(Shell.run の外部コマンド・大きなファイルの読み)を協調スレッドプールの外で撃つ器。
// **`Task.detached` はプールの外ではない**(同じ協調スレッドプールで動き、ブロッキングがスレッドを1本塞ぐ = MN-27 の飢餓)。
// 専用の Thread を起こし、戻り値を継続で1回だけ渡す(RegionText.modelCompileOnce / ParentDeathWatch.arm と同じ作法)

import Foundation

public enum BlockingWork {
    public static func offPool<T: Sendable>(name: String, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = name
            thread.start()
        }
    }

    public static func offPool<T: Sendable>(name: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await offPool(name: name) { Result { try work() } }.get()
    }
}
