// エミュレータ操作の gRPC/adb 振り分け(既定 gRPC・ユーザー決定)。
// - serial がディスカバリ(EmulatorEndpoints)に無い = 実機 or 旧 emulator → 呼び出し側の adb 経路
// - gRPC が一度でも失敗した個体は同一ブート(pid)中は adb 固定(再試行で遅くしない。
//   再ブートで pid が変われば自動的に gRPC へ復帰)
// - 殺しスイッチ: 環境変数 FT_EMULATOR_CONTROL=adb で全面 adb(docs/verification/)
// 読み取りと再起動系は「gRPC で完了できなければ nil / false」を返し、呼び出し側が adb にフォールバックする。
// **座標ジェスチャだけは失敗で撃ち直さない**(`GestureDelivery`)。

import FTEmulatorGrpc
import Foundation
import FTCore

public enum EmulatorControl {

    /// gRPC 失敗を記憶した emulator プロセス pid(NSLock 保護。プロセス内メモ)
    private static let memoLock = NSLock()
    private nonisolated(unsafe) static var failedPids: Set<Int32> = []

    static var grpcDisabled: Bool {
        ProcessInfo.processInfo.environment["FT_EMULATOR_CONTROL"] == "adb"
    }

    /// PNG スクリーンショット。nil = gRPC 不可(呼び出し側が adb screencap へ)
    public static func screenshotPNG(serial: String) async -> Data? {
        await perform(serial: serial) { try await EmulatorGrpcSession.screenshotPNG(endpoint: $0) }
    }

    /// sleep/wake 1サイクル(KEY_SLEEP→dwell→KEY_POWER)。false = gRPC 不可
    public static func sleepWake(serial: String, dwellNs: UInt64) async -> Bool {
        await perform(serial: serial) {
            try await EmulatorGrpcSession.sleepWake(endpoint: $0, dwell: .nanoseconds(dwellNs))
        } != nil
    }

    /// 正規シャットダウン(adb 経路死亡でも届く)。false = gRPC 不可
    public static func shutdown(serial: String) async -> Bool {
        await perform(serial: serial) { try await EmulatorGrpcSession.shutdown(endpoint: $0) } != nil
    }

    /// getStatus.booted。nil = gRPC 不可(booted=false は「ブート未完」として有効値)
    public static func statusBooted(serial: String) async -> Bool? {
        await perform(serial: serial) { try await EmulatorGrpcSession.statusBooted(endpoint: $0) }
    }

    /// VM リセット(guest reboot 相当)。false = gRPC 不可
    public static func reset(serial: String) async -> Bool {
        await perform(serial: serial) { try await EmulatorGrpcSession.reset(endpoint: $0) } != nil
    }

    // 名前付きキーの keypress は置かない — emulator は sendKey を成功で受けてキーを捨てる
    // (無音 no-op。AndroidDriver.home() と DS-16.3)。キー系は adb keyevent。
    // gpio-keys に載る KEY_POWER/KEY_SLEEP だけは届くので sleepWake は gRPC のまま

    /// 座標ジェスチャの送出の結果。**adb へ落としてよいのは `.notSent` だけ** —— gRPC は down → move → up を1本ずつ送るので、
    /// 途中で失敗した手は端末へ届いていることがあり、adb で撃ち直すと二重に効く
    public enum GestureDelivery: Sendable, Equatable {
        case performed
        /// タッチを1つも送っていない(実機・殺しスイッチ・失敗を記憶した個体・ジェスチャの前の `getStatus` の失敗)
        case notSent
        case deliveryUnknown(detail: String)
    }

    /// 2点間ドラッグ(座標は screencap と同じ物理ピクセル)
    public static func drag(serial: String, fromX: Int32, fromY: Int32,
                            toX: Int32, toY: Int32, durationMs: Int) async throws -> GestureDelivery {
        try await performGesture(serial: serial) {
            try await EmulatorGrpcSession.drag(endpoint: $0, fromX: fromX, fromY: fromY,
                                               toX: toX, toY: toY, durationMs: durationMs)
        }
    }

    /// 座標ロングプレス
    public static func longPress(serial: String, x: Int32, y: Int32, durationMs: Int) async throws -> GestureDelivery {
        try await performGesture(serial: serial) {
            try await EmulatorGrpcSession.longPress(endpoint: $0, x: x, y: y, durationMs: durationMs)
        }
    }

    /// serial → AVD 名(gRPC 不要・ディスカバリファイル読みのみ。`adb emu avd name` の代替)。
    /// 殺しスイッチの対象外(adb を使わない読み取りで、失敗時は呼び出し側が adb に落ちるだけ)
    public static func avdName(serial: String) -> String? {
        EmulatorEndpoints.endpoint(serial: serial)?.avdID
    }

    // MARK: - 内部

    private static func perform<T: Sendable>(
        serial: String, _ op: (EmulatorEndpoint) async throws -> T
    ) async -> T? {
        guard !grpcDisabled,
              let endpoint = EmulatorEndpoints.endpoint(serial: serial),
              !isFailed(pid: endpoint.pid) else { return nil }
        do {
            return try await op(endpoint)
        } catch {
            markFailed(pid: endpoint.pid)
            ConsoleOut.err(
                "⚠️ emulator gRPC failed — falling back to adb (\(serial), pid \(endpoint.pid)): "
                + ErrorText.user(error))
            return nil
        }
    }

    private static func performGesture(serial: String,
                                       _ op: (EmulatorEndpoint) async throws -> Void) async throws -> GestureDelivery {
        guard !grpcDisabled,
              let endpoint = EmulatorEndpoints.endpoint(serial: serial),
              !isFailed(pid: endpoint.pid) else { return .notSent }
        let outcome = try await delivery { try await op(endpoint) }
        switch outcome {
        case .performed:
            break
        case .notSent:
            markFailed(pid: endpoint.pid)
            ConsoleOut.err("⚠️ emulator gRPC is not answering — falling back to adb (\(serial), pid \(endpoint.pid))")
        case .deliveryUnknown(let detail):
            markFailed(pid: endpoint.pid)
            ConsoleOut.err("⚠️ emulator gRPC failed during a gesture; later gestures use adb"
                + " (\(serial), pid \(endpoint.pid)): \(detail)")
        }
        return outcome
    }

    /// 送出の結果の写像(デバイス無しのテスト用に分ける)
    /// **取り消しは投げ直す**(呼び手が止めただけで gRPC の故障ではない = 個体を adb に固定しない)
    static func delivery(_ send: () async throws -> Void) async throws -> GestureDelivery {
        do {
            try await send()
            return .performed
        } catch is EmulatorGrpcSession.GestureNotStarted {
            return .notSent
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .deliveryUnknown(detail: ErrorText.user(error))
        }
    }

    private static func isFailed(pid: Int32) -> Bool {
        memoLock.lock()
        defer { memoLock.unlock() }
        return failedPids.contains(pid)
    }

    private static func markFailed(pid: Int32) {
        memoLock.lock()
        defer { memoLock.unlock() }
        failedPids.insert(pid)
    }
}
