import AppKit
import Charts
import SwiftUI
import KongPrismCore

// MARK: - 局域网共享

struct LANShareView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if let ip = LANShare.address {
            let address = "\(ip):\(controller.settings.mixedPort)"
            HStack(alignment: .top, spacing: 16) {
                if let qr = LANShare.qrCode(address) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("其他设备的代理地址").font(.caption).foregroundStyle(.secondary)
                    Text(address).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Text("iPhone / iPad：设置 › 无线局域网 › 当前网络的 ⓘ › 配置代理 › 手动，服务器填 \(ip)，端口填 \(String(controller.settings.mixedPort))。也可以用相机扫码后复制地址。HTTP 与 SOCKS5 共用这个端口。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("同一网络里的任何设备都能使用，不用时请关掉。").font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            Text("没有找到这台 Mac 的局域网地址。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
