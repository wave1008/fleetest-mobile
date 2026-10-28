// サーバーの控えの機械共通の索引(DS-18.10)。`<home>/.fleetest/services-leases/<控えのファイル名>` の中身は控えの絶対パス1行。
// 控えはリポジトリの `.fleetest/hooks/` にあり、ランナー機では発行者ごとの work の下 = クローンで動く監視からは見えないので、
// 監視(`api monitor` の `monitorRuns.services`)はこの索引から引く。
// 書くのは `ServicesLeaseStore.write`・消すのは `ServicesLeaseStore.remove` の1箇所ずつ(`ServicesLeaseIndexTests`)。
// 先の無い索引は書き手が新しい索引を作るときに掃く(読み手は掃かない = DS-18.1 の③)。

import FTServices
import Foundation

enum ServicesLeaseIndex {
    static func directory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".fleetest/services-leases", isDirectory: true)
    }

    /// 控えを書くたびに呼ぶ。同じ中身の索引があれば何もしない(控えは段階が変わるたびに書き直される)
    static func register(leaseURL: URL, home: String) {
        let dir = directory(home: home)
        let pointer = dir.appendingPathComponent(leaseURL.lastPathComponent)
        let target = leaseURL.standardizedFileURL.path
        if (try? String(contentsOf: pointer, encoding: .utf8)) == target { return }
        sweepDangling(home: home)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? target.write(to: pointer, atomically: true, encoding: .utf8)
    }

    /// 控えを消すときに呼ぶ。**その控えを指している索引だけ**消す(同じファイル名の別の控えを指す索引は残す)
    static func unregister(leaseURL: URL, home: String) {
        let pointer = directory(home: home).appendingPathComponent(leaseURL.lastPathComponent)
        guard (try? String(contentsOf: pointer, encoding: .utf8)) == leaseURL.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: pointer)
    }

    /// 索引が指していて、いま実在する控えのパス(ファイル名順)。読み手は消さない
    static func leaseURLs(home: String) -> [URL] {
        pointers(home: home).compactMap { $0.target }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func sweepDangling(home: String) {
        for entry in pointers(home: home) {
            guard let target = entry.target else {
                try? FileManager.default.removeItem(at: entry.pointer)
                continue
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: entry.pointer)
            }
        }
    }

    private static func pointers(home: String) -> [(pointer: URL, target: URL?)] {
        let dir = directory(home: home)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { ServicesLeaseFile.parse(fileName: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { pointer in
                let text = (try? String(contentsOf: pointer, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let target = text.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                return (pointer, target)
            }
    }
}
