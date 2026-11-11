// swift-tools-version:5.9
import PackageDescription

// KongPrism：基于 sing-box 内核的 macOS 菜单栏代理客户端。
// - KongPrismCore：订阅解析（节点链接 / Clash YAML / sing-box JSON）、配置生成、版本比较。
//   只依赖 Foundation，全部有单元测试。
// - KongPrism：菜单栏 App（内核进程、系统代理、节点切换、设置、在线更新）。
let package = Package(
    name: "KongPrism",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KongPrism", targets: ["KongPrism"]),
    ],
    targets: [
        .target(name: "KongPrismCore"),
        .executableTarget(name: "KongPrism", dependencies: ["KongPrismCore"]),
        .testTarget(name: "KongPrismCoreTests", dependencies: ["KongPrismCore"]),
    ]
)
