import AppKit
import SwiftUI
import KongPrismCore

// MARK: - 新手引导

@MainActor
enum Onboarding {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView().environmentObject(AppController.shared))
            let created = NSWindow(contentViewController: hosting)
            created.title = "欢迎使用 KongPrism"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 520, height: 470))
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    @EnvironmentObject var controller: AppController
    @State private var input = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var checking = false
    @State private var googleResult: (ok: Bool, text: String)?
    @State private var others: [String] = OtherClients.running().map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }

    private var step: Int {
        if controller.profiles.isEmpty { return 1 }
        if !controller.status.isRunning { return 2 }
        return googleResult?.ok == true ? 4 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("三步开始使用").font(.title2.bold())
            if AppUpdater.isTranslocatedOrOutsideApplications {
                warning("KongPrism 不在“应用程序”文件夹里，在线更新无法替换它。", button: "移到“应用程序”") { AppUpdater.moveToApplications() }
            }
            if !others.isEmpty {
                warning("\(others.joined(separator: "、")) 正在运行，两个代理软件会互相改写系统代理。", button: "退出它们") {
                    for app in OtherClients.running() { app.terminate() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { others = OtherClients.running().map { $0.localizedName ?? "?" } }
                }
            }

            stepView(1, "添加订阅") {
                if step == 1 {
                    TextField("粘贴订阅地址 https://…（机场网页上的 Clash 订阅）", text: $input)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(adding ? "正在下载订阅…" : "添加") { add() }
                            .disabled(adding || input.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                        Button("从文件导入…") { Importer.chooseFile(controller: controller) }
                        if adding { ProgressView().controlSize(.small) }
                    }
                    if let addError { Text(addError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    Text("也可以在机场网页上点“一键导入 Clash / sing-box”。").font(.caption).foregroundStyle(.secondary)
                } else if let profile = controller.selectedProfile {
                    Text("“\(profile.name)”：\(profile.nodeCount) 个节点").foregroundStyle(.secondary)
                }
            }

            stepView(2, "开启代理") {
                if step == 2 {
                    HStack {
                        Button("开启代理") { controller.connect() }.disabled(controller.status == .starting)
                        if controller.status == .starting { ProgressView().controlSize(.small) }
                    }
                    if case .failed(let message) = controller.status { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                } else if step > 2 {
                    Text("已连接，系统代理指向 127.0.0.1:\(String(controller.settings.mixedPort))").foregroundStyle(.secondary)
                }
            }

            stepView(3, "验证能打开 Google") {
                if step >= 3 {
                    HStack {
                        Button(checking ? "正在检查…" : "检查") { checkGoogle() }.disabled(checking)
                        if let googleResult {
                            Label(googleResult.text, systemImage: googleResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(googleResult.ok ? .green : .red)
                        }
                    }
                    if googleResult?.ok == false {
                        Button("诊断连接…") { Diagnostics.show(controller: controller) }
                    }
                }
            }

            Spacer()
            HStack {
                Text("菜单栏的 ◇ 图标可以开关代理、换节点；\(HotKey.display) 一键开关。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(step == 4 ? "完成" : "以后再说") {
                    controller.settings.onboardingDone = true
                    Onboarding.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520, height: 470)
        .onAppear {
            if controller.status.isRunning, googleResult == nil { checkGoogle() }
            if input.isEmpty, let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.hasPrefix("http"), !text.contains("\n"), text.count < 2000 {
                input = text
            }
        }
        .onChange(of: controller.status) { status in
            if status.isRunning, googleResult == nil { checkGoogle() }
        }
    }

    @ViewBuilder
    private func stepView<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(step > number ? Color.green : step == number ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 26, height: 26)
                if step > number { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold()) }
                else { Text("\(number)").foregroundStyle(.white).font(.callout.bold()) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(step >= number ? Color.primary : Color.secondary)
                content()
            }
        }
    }

    private func warning(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button(button, action: action)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    private func add() {
        adding = true
        addError = nil
        let text = input
        Task {
            do {
                let id = try await controller.addProfile(input: text, name: "")
                controller.selectProfile(id)
                input = ""
            } catch {
                addError = "添加失败：\(error.localizedDescription)"
            }
            adding = false
        }
    }

    private func checkGoogle() {
        checking = true
        let port = controller.settings.mixedPort
        Task {
            let start = Date()
            do {
                let (_, response) = try await Net.get(URL(string: "https://www.google.com/generate_204")!, headers: ["User-Agent": "KongPrism-Onboarding"],
                                                      routes: [.viaProxy(port: port)], timeout: 10)
                googleResult = (true, "可以访问（HTTP \(response.statusCode)，\(Int(Date().timeIntervalSince(start) * 1000)) ms）")
            } catch {
                googleResult = (false, "打不开：\(error.localizedDescription)")
            }
            checking = false
        }
    }
}
