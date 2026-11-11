import XCTest
@testable import KongPrismCore

final class PolicyTests: XCTestCase {
    func testNodeAvoidance() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failing = [CoreLogStats.NodeFailures(node: "JP2", count: 9, hosts: ["claude.ai"]),
                       CoreLogStats.NodeFailures(node: "HK1", count: 6, hosts: [])]
        let first = NodeAvoidance.decide(failing: failing, current: ["OLD": now.addingTimeInterval(-1)], handPicked: "HK1",
                                         inUse: ["JP2"], now: now)
        XCTAssertEqual(Set(first.avoided.keys), ["JP2"], "过期的移除；手选的 HK1 不避开")
        XCTAssertEqual(first.avoided["JP2"], now.addingTimeInterval(3600))
        XCTAssertEqual(first.newlyAvoided.map(\.node), ["JP2"])
        XCTAssertTrue(first.reloadNow)

        let again = NodeAvoidance.decide(failing: failing, current: first.avoided, handPicked: nil, inUse: ["US1"], now: now.addingTimeInterval(60))
        XCTAssertEqual(again.newlyAvoided.map(\.node), ["HK1"], "已在避开的不重复计入")
        XCTAssertEqual(again.avoided["JP2"], now.addingTimeInterval(3600), "不延长")
        XCTAssertFalse(again.reloadNow, "HK1 没在被使用：不重启内核")
    }

    func testUpdatePause() {
        XCTAssertEqual(UpdatePause.duration(retryAfter: nil), 3 * 3600)
        XCTAssertEqual(UpdatePause.duration(retryAfter: 120), 600)
        XCTAssertEqual(UpdatePause.duration(retryAfter: 7200), 7200)
        XCTAssertEqual(UpdatePause.duration(retryAfter: 10 * 86_400), 86_400)
    }

    func testLaunchHealth() {
        XCTAssertEqual(LaunchHealth.abnormalCount(previous: 0, lastRunEndedAbnormally: true, previousVersion: "0.7.0", currentVersion: "0.7.0"), 1)
        XCTAssertEqual(LaunchHealth.abnormalCount(previous: 1, lastRunEndedAbnormally: true, previousVersion: "0.7.0", currentVersion: "0.7.0"), 2)
        XCTAssertEqual(LaunchHealth.abnormalCount(previous: 1, lastRunEndedAbnormally: true, previousVersion: "0.6.0", currentVersion: "0.7.0"), 0)
        XCTAssertEqual(LaunchHealth.abnormalCount(previous: 1, lastRunEndedAbnormally: false, previousVersion: "0.7.0", currentVersion: "0.7.0"), 0)
        XCTAssertTrue(LaunchHealth.shouldOfferRollback(abnormalCount: 2, currentVersion: "0.7.0", lastGoodVersion: "0.6.0", backupVersion: "0.6.0"))
        XCTAssertFalse(LaunchHealth.shouldOfferRollback(abnormalCount: 1, currentVersion: "0.7.0", lastGoodVersion: "0.6.0", backupVersion: "0.6.0"))
        XCTAssertFalse(LaunchHealth.shouldOfferRollback(abnormalCount: 3, currentVersion: "0.7.0", lastGoodVersion: "0.7.0", backupVersion: "0.6.0"),
                       "这个版本运行过一分钟以上：不是更新造成的")
        XCTAssertFalse(LaunchHealth.shouldOfferRollback(abnormalCount: 2, currentVersion: "0.7.0", lastGoodVersion: "0.6.0", backupVersion: nil))
        XCTAssertFalse(LaunchHealth.shouldOfferRollback(abnormalCount: 2, currentVersion: "0.7.0", lastGoodVersion: "0.6.0", backupVersion: "0.5.1"))
    }

    func testLogAnonymizer() {
        let line = "+0800 2026-11-11 18:52:48 ERROR [2221668915 0ms] connection: open connection to mtalk.google.com:5228 using outbound/trojan[中国香港-PRO-IPLC-HK2-1-流量倍率:1]: dial tcp 113.46.237.225:6002: no route to internet"
        let out = LogAnonymizer.anonymize(line + "\n" + line.replacingOccurrences(of: "113.46.237.225", with: "45.141.47.97") + "\nread tcp 10.4.32.159:50980->113.46.237.225:465")
        XCTAssertFalse(out.contains("113.46.237.225"))
        XCTAssertFalse(out.contains("45.141.47.97"))
        XCTAssertTrue(out.contains("dial tcp ip-1:6002"))
        XCTAssertTrue(out.contains("dial tcp ip-2:6002"))
        XCTAssertTrue(out.contains("10.4.32.159:50980->ip-1:465"), "同一地址同一代号；局域网地址保留")
        XCTAssertTrue(out.contains("mtalk.google.com:5228"), "域名保留")
        XCTAssertTrue(out.contains("2026-11-11 18:52:48"), "时间不受影响")
        XCTAssertEqual(LogAnonymizer.anonymize("dial tcp [2001:db8::1]:443 and [::1]:9099"), "dial tcp [ip-1]:443 and [::1]:9099")
        XCTAssertEqual(LogAnonymizer.anonymize("sing-box 1.14.4"), "sing-box 1.14.4")
    }
}
