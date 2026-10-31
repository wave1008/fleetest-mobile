// EmulatorController への単発 RPC 群。呼び出し毎に接続を張って閉じる
// (loopback なので接続コストは ~ms。常駐接続の管理より確実さを優先)。
// 失敗は throw で返し、gRPC→adb のフォールバック判断は呼び出し側(FTAndroid.EmulatorControl)が行う。

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public enum EmulatorGrpcSession {

    public static let defaultTimeout: Duration = .seconds(10)

    /// ジェスチャの前の `getStatus` が失敗した = **タッチを1つも送っていない**と確定している印。
    /// これだけが adb へ撃ち直してよい根拠(`EmulatorControl.GestureDelivery`)。接続の失敗も、ここで同じ接続の RPC として出る
    public struct GestureNotStarted: Error {
        public let cause: any Error
        public init(cause: any Error) { self.cause = cause }
    }

    /// タッチを送り始めた後に失敗した印。`fingerReleased == false` = 指を上げる up も届かず、指が画面に残っている可能性がある
    /// (残った指は別プロセスの次の gRPC ジェスチャを1回まるごと吸った: 探索 b F1)。`EmulatorControl.delivery` が文言にする
    public struct GestureInterrupted: Error {
        public let cause: any Error
        public let fingerReleased: Bool
        public init(cause: any Error, fingerReleased: Bool) {
            self.cause = cause
            self.fingerReleased = fingerReleased
        }
    }

    /// gRPC の失敗の code と message(`ErrorText.user` は RPCError を NSError の既定の文へ落とし中身が読めない)。gRPC の失敗でなければ nil
    public static func rpcFailureText(_ error: any Error) -> String? {
        guard let rpc = error as? RPCError else { return nil }
        return "gRPC \(rpc.code): \(rpc.message)"
    }

    /// 失敗後の up の期限。loopback の単発 RPC(接続 ~ms)なので、固まった Emulator を待ち続けない上限として置く。
    /// 尽きたら指が残るが、元の失敗はそのまま呼び手へ返す
    static let fingerReleaseTimeout: Duration = .seconds(2)

    /// PNG スクリーンショット(adb screencap -p の代替。実測 48ms vs 140〜250ms)。
    /// 注意: blank 判定に PNG バイト数を使わないこと(emulator 側エンコーダは一様黒でも
    /// 51KB を出す=adb 較正の 30KB 閾値をすり抜ける。判定はホスト側でデコードして画素一様性で
    /// 行う(AndroidHealthProbe.uniformFrame)。RGBA8888 直取りは約10MB の単一メッセージが
    /// grpc-swift トランスポートに切断され使えない(実測。node の grpc-js は受かる))
    public static func screenshotPNG(endpoint: EmulatorEndpoint,
                                     timeout: Duration = defaultTimeout) async throws -> Data {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var format = Android_Emulation_Control_ImageFormat()
            format.format = .png
            let image = try await client.getScreenshot(format, metadata: metadata, options: options)
            return image.image
        }
    }

    /// evdev キーコードの keypress(down+up)。
    /// 罠: **届くのは guest に入力デバイスがあるキーだけ** — gpio-keys の KEY_POWER(116)/
    /// KEY_SLEEP(142) は届き、KEY_WAKEUP(143) は不発(実測)。API 36 arm64 の AVD は
    /// キーボードデバイスを持たないので HOME/APP_SWITCH/ENTER 相当も届かない(実測。
    /// DS-16.3)。wake には KEY_POWER を使うこと(sleepWake() が正しい並びを内蔵)
    public static func sendEvdevKeypress(endpoint: EmulatorEndpoint, keyCode: Int32,
                                         timeout: Duration = defaultTimeout) async throws {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var event = Android_Emulation_Control_KeyboardEvent()
            event.codeType = .evdev
            event.eventType = .keypress
            event.keyCode = keyCode
            _ = try await client.sendKey(event, metadata: metadata, options: options)
        }
    }

    /// sleep/wake 1サイクル(blank-screen 修復。KEY_SLEEP=142 → dwell → KEY_POWER=116。
    /// KEY_SLEEP は非トグルで確実に Asleep、直後の KEY_POWER トグルは確実に wake になる)
    public static func sleepWake(endpoint: EmulatorEndpoint, dwell: Duration) async throws {
        try await sendEvdevKeypress(endpoint: endpoint, keyCode: 142)
        try await Task.sleep(for: dwell)
        try await sendEvdevKeypress(endpoint: endpoint, keyCode: 116)
    }

    // 名前付きキー(KeyboardEvent.key = "GoHome"/"AppSwitch"/"Enter")の keypress は置かない —
    // proto は Android 固有動作を明記しているが guest には届かず、RPC だけ成功する
    // (実測。FTAndroid.AndroidDriver.home() と DS-16.3)

    /// 2点間ドラッグ(`input swipe` の代替)。down → ~16ms 刻みの補間 move → up を
    /// 1接続内で送る(pressure 0 の up を必ず送らないと identifier が残留する。proto 契約)。
    /// 座標は screencap と同じ物理ピクセル
    public static func drag(endpoint: EmulatorEndpoint,
                            fromX: Int32, fromY: Int32, toX: Int32, toY: Int32,
                            durationMs: Int) async throws {
        try await withController(endpoint: endpoint,
                                 timeout: .milliseconds(durationMs + 10_000)) { client, metadata, options in
            func touch(_ x: Int32, _ y: Int32, pressure: Int32) async throws {
                _ = try await client.sendTouch(touchEvent(x: x, y: y, pressure: pressure),
                                               metadata: metadata, options: options)
            }
            try await requireController(client, metadata: metadata, options: options, clearingStrayFingerAt: (fromX, fromY))
            var last = (x: fromX, y: fromY)
            do {
                let steps = max(2, durationMs / 16)
                try await touch(fromX, fromY, pressure: 1)
                for i in 1...steps {
                    let progress = Double(i) / Double(steps)
                    last = (Int32((Double(fromX) + Double(toX - fromX) * progress).rounded()),
                            Int32((Double(fromY) + Double(toY - fromY) * progress).rounded()))
                    try await touch(last.x, last.y, pressure: 1)
                    try await Task.sleep(for: .milliseconds(durationMs / steps))
                }
                last = (toX, toY)
                try await touch(toX, toY, pressure: 0)
            } catch {
                let released = await releaseFinger(endpoint: endpoint, x: last.x, y: last.y)
                throw GestureInterrupted(cause: error, fingerReleased: released)
            }
        }
    }

    /// 座標ロングプレス(同一点 `input swipe` の代替): down → duration 保持 → up
    public static func longPress(endpoint: EmulatorEndpoint, x: Int32, y: Int32,
                                 durationMs: Int) async throws {
        try await withController(endpoint: endpoint,
                                 timeout: .milliseconds(durationMs + 10_000)) { client, metadata, options in
            try await requireController(client, metadata: metadata, options: options, clearingStrayFingerAt: (x, y))
            do {
                _ = try await client.sendTouch(touchEvent(x: x, y: y, pressure: 1), metadata: metadata, options: options)
                try await Task.sleep(for: .milliseconds(durationMs))
                _ = try await client.sendTouch(touchEvent(x: x, y: y, pressure: 0), metadata: metadata, options: options)
            } catch {
                let released = await releaseFinger(endpoint: endpoint, x: x, y: y)
                throw GestureInterrupted(cause: error, fingerReleased: released)
            }
        }
    }

    private static func touchEvent(x: Int32, y: Int32, pressure: Int32) -> Android_Emulation_Control_TouchEvent {
        var touch = Android_Emulation_Control_Touch()
        touch.x = x
        touch.y = y
        touch.identifier = 0
        touch.pressure = pressure
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        return event
    }

    private static func requireController(
        _ client: Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>,
        metadata: Metadata, options: CallOptions, clearingStrayFingerAt point: (x: Int32, y: Int32)
    ) async throws {
        do {
            _ = try await client.getStatus(.init(), metadata: metadata, options: options)
        } catch {
            throw GestureNotStarted(cause: error)
        }
        // 前のプロセスが指を下ろしたまま死ぬと、ゲスト側に identifier 0 の指が残り、次のジェスチャの down はその指の MOVE として
        // 消費されて丸ごと不発になる(実測: 残った指のまま ft_drag が「sent」で drag=0)。**pressure 0 の up を先に1本**送って上げる。
        // 指が無いときの up は何も起こさない(実測: Android 15 Emulator で getevent に何も出ず・TouchStates 空・ボタンの上でも押下にならない)。
        // 失敗は握る(本物の送りが同じ失敗で落ち、そちらが正しい失敗として返る)
        _ = try? await client.sendTouch(touchEvent(x: point.x, y: point.y, pressure: 0), metadata: metadata, options: options)
    }

    /// 途中で失敗したジェスチャの指を上げる(up を送らないと identifier が残り、次の入力に重なる)。**別の接続・別のタスクで送る** ——
    /// 失敗の原因が接続の切断でも、呼び手のタスクの取り消しでも届くように。up が届いたか(true)を返す。失敗しても投げない(元の失敗を呼び手へ返す)
    @discardableResult
    public static func releaseFinger(endpoint: EmulatorEndpoint, x: Int32, y: Int32) async -> Bool {
        await Task {
            do {
                try await withController(endpoint: endpoint, timeout: fingerReleaseTimeout) { client, metadata, options in
                    _ = try await client.sendTouch(touchEvent(x: x, y: y, pressure: 0), metadata: metadata, options: options)
                }
                return true
            } catch { return false }
        }.value
    }

    /// getStatus.booted(sys.boot_completed の代替候補。semantics 差があるため
    /// 呼び出し側は false を「未ブート」でなく「不明」として扱い getprop に落とすこと)
    public static func statusBooted(endpoint: EmulatorEndpoint,
                                    timeout: Duration = defaultTimeout) async throws -> Bool {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            let status = try await client.getStatus(.init(), metadata: metadata, options: options)
            return status.booted
        }
    }

    /// 正規シャットダウン(UI の X と同じ)。`adb emu kill` と違い adb 経路死亡でも届く
    public static func shutdown(endpoint: EmulatorEndpoint,
                                timeout: Duration = defaultTimeout) async throws {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var state = Android_Emulation_Control_VmRunState()
            state.state = .shutdown
            _ = try await client.setVmState(state, metadata: metadata, options: options)
        }
    }

    /// VM リセット(guest reboot 相当。emulator プロセスは維持)。`adb reboot` 不達時の代替
    public static func reset(endpoint: EmulatorEndpoint,
                             timeout: Duration = defaultTimeout) async throws {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var state = Android_Emulation_Control_VmRunState()
            state.state = .reset
            _ = try await client.setVmState(state, metadata: metadata, options: options)
        }
    }

    // MARK: - 内部

    private static func withController<T: Sendable>(
        endpoint: EmulatorEndpoint,
        timeout: Duration,
        _ body: @Sendable @escaping (
            Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>,
            Metadata,
            CallOptions
        ) async throws -> T
    ) async throws -> T {
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: endpoint.grpcPort),
            transportSecurity: .plaintext)
        var metadata: Metadata = [:]
        metadata.addString("Bearer \(endpoint.token)", forKey: "authorization")
        // RPC 全体のデッドライン(ハング中のエミュレータで永久待ちしない)
        var options = CallOptions.defaults
        options.timeout = timeout
        let capturedMetadata = metadata
        let capturedOptions = options
        return try await withGRPCClient(transport: transport) { grpcClient in
            let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: grpcClient)
            return try await body(controller, capturedMetadata, capturedOptions)
        }
    }
}
