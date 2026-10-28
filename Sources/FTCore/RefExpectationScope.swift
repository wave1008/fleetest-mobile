/// ステップ実行器が撃つ ref に期待する要素(ロケータの解決に使った木の要素)をドライバ層へ運ぶ TaskLocal。
/// AppDriver のシグネチャ(ラッパーが10個以上)を変えないための経路(`SettleOverride` と同じ形)。
/// ドライバ(BridgeClient・AndroidDriver)は**自分の最新の ref の表**と照らし、食い違えば撃たずに `DriverError.staleRef` を投げる
/// = `StepExecutor.executeActionRetryingUndelivered` が撮り直して引き直す。ステップ実行器が古い木の ref を撃つ誤り(MN-92.4 の型)は、
/// BridgeClient が自分の表から添える `expect` では断てない(ブリッジの表も同じ最新の木なので必ず一致する)。
/// 包むのは executeAction の中で撃つ ref だけ(外で撃つ staleRef は撃ち直しの対象にならず失敗になる)
public enum RefExpectationScope {
    @TaskLocal public static var expected: RefExpectation?

    /// `element` を期待として `body` を撃つ
    public static func firing<T>(_ element: ElementInfo, _ body: () async throws -> T) async rethrows -> T {
        try await $expected.withValue(RefExpectation(element)) { try await body() }
    }

    /// 期待とドライバの最新の表の要素が矛盾するか。どちらかが無ければ矛盾しない(表に無い ref は従来どおりドライバ・ブリッジが断る)。
    /// **型の "other" はどちら側でも照合しない** —— ホストの木の正規化(`SnapshotDedupe.wrapperScrollMerge`)が other を
    /// 下の容器の型へ書き換えるので、表(正規化前)と食い違う。ブリッジ側の判定(`StaleRefGuard.contradicts`)は正規化前どうしなので厳密なまま
    public static func contradicts(_ expect: RefExpectation?, latest: RefExpectation?) -> Bool {
        guard let expect, let latest else { return false }
        if let a = expect.identifier, !a.isEmpty, let b = latest.identifier, !b.isEmpty, a != b { return true }
        let a = ElementInfo.normalizedType(expect.type)
        let b = ElementInfo.normalizedType(latest.type)
        return a != b && a != "other" && b != "other"
    }

    /// 撃たずに断るときの `DriverError.staleRef` の detail(一次情報だけ)
    public static func refusalDetail(ref: Int, expected: RefExpectation, latest: RefExpectation) -> String {
        func describe(_ e: RefExpectation) -> String {
            e.identifier.flatMap { $0.isEmpty ? nil : "\(e.type) #\($0)" } ?? e.type
        }
        return "ref [\(ref)] now points at \(describe(latest)) in the latest snapshot, not the \(describe(expected)) "
            + "the step resolved"
    }
}
