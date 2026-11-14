import WebKit
import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsSection: String, CaseIterable {
    case general = "通用设置", appearance = "界面设置", about = "关于应用"
    var symbol: String { switch self { case .general: "gearshape"; case .appearance: "circle.lefthalf.filled"; case .about: "seal" } }
}

struct SettingsRootView: View {
    @State private var section: SettingsSection = .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("side-player").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Color(hex: "2a3f52"))
                    .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 6)
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(section == item ? Color(hex: "c9c9ad") : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(Color(hex: "2a3f52"))
                    }.buttonStyle(.plain).padding(.horizontal, 8)
                }
                Spacer()
            }
            .frame(width: 205)
            .background(Color(hex: "f3f4f8"))
            Group {
                switch section {
                case .general: GeneralSettingsView()
                case .appearance: InterfaceSettingsView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .background(Color(hex: "f3f4f8"))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "d6dfeb"), lineWidth: 1).padding(8))
        }
        .frame(minWidth: 850, minHeight: 650)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: PlayerModel
    @AppStorage("startupSettings") private var startupSettings = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("sidebarSide") private var sidebarSide = "左侧"
    @AppStorage("sidebarSongCount") private var songCount = 8
    @AppStorage("sidebarVerticalOffsetMM") private var verticalOffset = 0.0
    @AppStorage("sidebarOpacity") private var opacity = 100.0
    @AppStorage("sourceLocal") private var sourceLocal = true
    @AppStorage("sourceNetEase") private var sourceNetEase = true
    @ObservedObject private var netease = NetEaseClient.shared
    @State private var showNetEaseLogin = false
    @State private var settingsError: String?
    @State private var selectedPlaylistIDs = Set(UserDefaults.standard.stringArray(forKey: "selectedNetEasePlaylists") ?? [])

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                folderRow
                ToggleRow(title: "启动时显示设置界面", subtitle: "每次启动应用时，先打开设置界面", isOn: $startupSettings)
                ToggleRow(title: "随系统启动", subtitle: "登录系统后自动启动 side-player", isOn: $launchAtLogin)
                valueRow("侧栏位置", subtitle: "在桌面边缘显示的位置") {
                    Picker("侧栏位置", selection: $sidebarSide) { Text("左侧").tag("左侧"); Text("右侧").tag("右侧") }.labelsHidden().frame(width: 110)
                }
                valueRow("显示数量", subtitle: "侧栏同时显示的歌曲数，更多歌曲可在列表内滚动") {
                    HStack { Stepper(value: $songCount, in: 1...100) { Text("\(songCount)").frame(width: 32, alignment: .center) }.frame(width: 110); Text("个") }
                }
                valueRow("垂直位置", subtitle: "正值向上，负值向下") {
                    HStack {
                        let offset = Binding(get: { verticalOffset }, set: {
                            if $0.isFinite { verticalOffset = ($0 * 10).rounded() / 10 }
                        })
                        Stepper(value: offset, step: 0.1) {
                            TextField("垂直位置", value: offset, format: .number.precision(.fractionLength(1)))
                                .labelsHidden().multilineTextAlignment(.center).frame(width: 65)
                        }.frame(width: 110)
                        Text("mm")
                    }
                }
                valueRow("侧栏透明度", subtitle: nil) {
                    HStack(spacing: 10) { Slider(value: $opacity, in: 10...100).frame(width: 190).tint(Color(hex: "273043")); Text("\(Int(opacity))%").frame(width: 48, alignment: .trailing) }
                }
                sourcePicker
                netEaseRow
                valueRow("歌曲排序", subtitle: "可按歌曲名称排序或随机排序") {
                    Picker("歌曲排序", selection: $model.sortRandom) { Text("字母顺序").tag(false); Text("随机排序").tag(true) }
                        .labelsHidden().frame(width: 130).onChange(of: model.sortRandom) { _, value in
                            UserDefaults.standard.set(value, forKey: "randomSort")
                            model.sortTracks()
                        }
                }
                valueRow("扫描与刷新", subtitle: "重新扫描已勾选位置中的歌曲") {
                    Button("立即扫描") { model.refreshSelectedSources() }.buttonStyle(OutlineButtonStyle())
                }
                HStack {
                    Button { NSApp.terminate(nil) } label: { Label("彻底退出应用", systemImage: "power") }
                        .buttonStyle(QuitButtonStyle())
                    Spacer()
                }.padding(.horizontal, 4).padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 22).padding(.top, 20)
        .onAppear {
            model.sortRandom = UserDefaults.standard.bool(forKey: "randomSort")
            model.setSources(local: sourceLocal, netEase: sourceNetEase)
            model.refreshSongs()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            model.refreshNetEaseSource()
        }
        .onChange(of: sourceLocal) { _, enabled in
            model.setSources(local: enabled)
            model.refreshSongs()
        }
        .onChange(of: sourceNetEase) { _, enabled in
            model.setSources(netEase: enabled)
            model.refreshNetEaseSource()
        }
        .onChange(of: selectedPlaylistIDs) { _, _ in model.refreshNetEaseSource() }
        .onChange(of: netease.isLoggedIn) { _, _ in model.refreshNetEaseSource() }
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        .alert("启动项设置失败", isPresented: Binding(get: { settingsError != nil }, set: { if !$0 { settingsError = nil } })) {
            Button("好", role: .cancel) { settingsError = nil }
        } message: { Text(settingsError ?? "") }
        .sheet(isPresented: $showNetEaseLogin) { NetEaseLoginView().environmentObject(netease) }
    }

    private var folderRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text("播放文件夹").font(.system(size: 14, weight: .semibold)); Text("选择本机音乐所在文件夹").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            Text(model.musicFolder.isEmpty ? "尚未选择文件夹" : FileManager.default.displayName(atPath: model.musicFolder))
                .foregroundStyle(.secondary).lineLimit(1).frame(width: 180, alignment: .leading)
            Button("选择文件夹") { model.chooseFolder() }.buttonStyle(AccentButtonStyle())
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("播放位置").font(.system(size: 14, weight: .semibold))
            HStack {
                Toggle("本地文件夹", isOn: $sourceLocal)
                Toggle("网易云音乐列表", isOn: $sourceNetEase)
            }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() }
    }

    private var netEaseRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("网易云音乐").font(.system(size: 14, weight: .semibold)); Text(netease.loginStatus).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button(netease.isLoggedIn ? "重新登录" : "网页登录") { showNetEaseLogin = true }.buttonStyle(OutlineButtonStyle())
                if netease.isLoggedIn { Button("退出登录") { netease.logout() }.buttonStyle(OutlineButtonStyle()) }
            }
            if let message = netease.errorMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
            }
            if netease.isLoggedIn {
                if netease.playlists.isEmpty {
                    Text("正在加载歌单，或此账号暂时没有可显示的歌单。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(netease.playlists) { playlist in
                    Toggle("\(playlist.name)（\(playlist.trackCount) 首）", isOn: Binding(get: { selectedPlaylistIDs.contains(playlist.id) }, set: { enabled in
                        if enabled { selectedPlaylistIDs.insert(playlist.id) } else { selectedPlaylistIDs.remove(playlist.id) }
                        UserDefaults.standard.set(Array(selectedPlaylistIDs), forKey: "selectedNetEasePlaylists")
                    }))
                }
            }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() }
    }

    private func valueRow<T: View>(_ title: String, subtitle: String?, @ViewBuilder control: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14, weight: .semibold)); if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) } }
            Spacer(minLength: 16); control()
        }.padding(.vertical, 11).overlay(alignment: .bottom) { Divider() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = error.localizedDescription
        }
    }


}

private struct NetEaseLoginView: View {
    @EnvironmentObject private var client: NetEaseClient
    @Environment(\.dismiss) private var dismiss
    @State private var dataStore = WKWebsiteDataStore.nonPersistent()
    @State private var pageID = UUID()
    @State private var errorMessage: String?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网易云音乐网页登录").font(.headline)
            Text("在下方官网登录。网页显示已登录后，点击「已登录，读取歌单」。")
                .font(.system(size: 12))
            NetEaseLoginPage(dataStore: dataStore) { message in
                errorMessage = message
            }
            .id(pageID)
            .frame(minHeight: 450)
            if let errorMessage {
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Button("重新加载") { errorMessage = nil; pageID = UUID() }
                    .buttonStyle(OutlineButtonStyle())
                Spacer()
                if confirming { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("已登录，读取歌单") { confirming = true }
                    .buttonStyle(AccentButtonStyle())
            }
            .disabled(confirming)
        }
        .padding(22)
        .frame(width: 820, height: 600)
        .task(id: confirming) {
            guard confirming else { return }
            defer { confirming = false }
            errorMessage = nil
            do {
                let cookies = await dataStore.httpCookieStore.allCookies()
                try Task.checkCancellation()
                try await client.completeWebLogin(cookies: cookies)
                dismiss()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct NetEaseLoginPage: NSViewRepresentable {
    let dataStore: WKWebsiteDataStore
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: NetEaseClient.loginPage))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onError: (String) -> Void

        init(onError: @escaping (String) -> Void) { self.onError = onError }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.scheme == "https" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.request.url?.scheme == "https" { webView.load(action.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onError("网页加载失败：\(error.localizedDescription)")
        }
    }
}

private struct InterfaceSettingsView: View {
    @AppStorage("showArtist") private var showArtist = true
    @AppStorage("showTitle") private var showTitle = true
    @AppStorage("showYear") private var showYear = false
    @AppStorage("showExtension") private var showExtension = false
    @AppStorage("defaultFontSize") private var defaultSize = 9.0
    @AppStorage("hoverFontSize") private var hoverSize = 12.0
    @AppStorage("color.文字（默认）") private var previewTextHex = "556775"
    @AppStorage("color.歌词") private var previewLyricHex = "c9c9ad"
    @AppStorage("color.上下相邻歌曲") private var previewAdjacentHex = "c9c9ad"
    @AppStorage("color.悬停歌曲") private var previewHoverHex = "ceba7b"
    @AppStorage("color.长线") private var previewLongLineHex = "556775"
    @AppStorage("color.短线") private var previewShortLineHex = "556775"
    @AppStorage("color.进度（已播放）") private var previewPlayedHex = "273043"
    @AppStorage("color.进度（未播放）") private var previewUnplayedHex = "556775"
    @AppStorage("color.播放时按钮图标与边框") private var previewPlayingButtonHex = "556775"
    private let colors: [(String, String)] = [
        ("文字（默认）", "556775"), ("歌词", "c9c9ad"), ("文字（辅助）", "556775"), ("上下相邻歌曲", "c9c9ad"), ("悬停歌曲", "ceba7b"),
        ("长线", "556775"), ("短线", "556775"), ("进度（已播放）", "273043"), ("进度（未播放）", "556775"),
        ("播放时按钮底色", "556775"), ("播放时按钮图标与边框", "556775"), ("暂停时按钮底色", "252d3a"), ("暂停时按钮图标与边框", "556775")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("配色设置").font(.system(size: 16, weight: .bold))
                        Text("输入十六进制颜色值（#RRGGBB），实时预览侧栏效果").font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(colors, id: \.0) { name, hex in ColorField(name: name, initial: hex) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("侧栏预览").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 11) {
                            previewLine("演唱者丨歌曲名", selected: true)
                            previewLine("演唱者丨歌曲名", adjacent: true)
                            previewLine("演唱者丨歌曲名")
                            HStack { SegmentedProgress(value: 0.45, playedHex: previewPlayedHex, unplayedHex: previewUnplayedHex); Text("01:28 / 04:12").font(.system(size: 10)).foregroundStyle(Color(hex: previewTextHex)) }
                            Text("示例歌词").font(.system(size: 9)).foregroundStyle(Color(hex: previewLyricHex))
                            HStack(spacing: 8) {
                                SVGSpriteCrop(image: previewSprite, sourceRect: NSRect(x: 0, y: 16, width: 73, height: 40)).frame(width: 18, height: SegmentedProgress.height)
                                SVGSpriteCrop(image: previewSprite, sourceRect: NSRect(x: 105, y: 114, width: 72, height: 72)).frame(width: 18, height: SegmentedProgress.height)
                                SVGSpriteCrop(image: previewSprite, sourceRect: NSRect(x: 208, y: 16, width: 73, height: 40)).frame(width: 18, height: SegmentedProgress.height)
                            }
                        }.padding(14).frame(width: 220).background(Color(hex: "f3f4f8"), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "d6dfeb")))
                    }.padding(.top, 35)
                }
                Divider().padding(.vertical, 4)
                Text("显示设置").font(.system(size: 16, weight: .bold))
                HStack(spacing: 10) {
                    Text("侧栏显示名称")
                    Toggle("第一位歌手名", isOn: $showArtist).toggleStyle(.checkbox)
                    Toggle("歌曲名", isOn: $showTitle).toggleStyle(.checkbox)
                    Toggle("发行年", isOn: $showYear).toggleStyle(.checkbox)
                    Toggle("后缀名", isOn: $showExtension).toggleStyle(.checkbox)
                }
                HStack(spacing: 10) {
                    Text("默认字号")
                    TextField("9", value: $defaultSize, format: .number).multilineTextAlignment(.center).frame(width: 68)
                    Text("pt").padding(.trailing, 14)
                    Text("悬停最大字号")
                    TextField("12", value: $hoverSize, format: .number).multilineTextAlignment(.center).frame(width: 68)
                    Text("pt")
                }
                HStack { Button("恢复默认") { showArtist = true; showTitle = true; showYear = false; showExtension = false; defaultSize = 9; hoverSize = 12 }.buttonStyle(OutlineButtonStyle()); Button("确认修改") {}.buttonStyle(AccentButtonStyle()) }
                Spacer(minLength: 10)
            }.padding(18)
        }
    }
    private func previewLine(_ title: String, selected: Bool = false, adjacent: Bool = false) -> some View {
        HStack(spacing: 8) {
            VStack(spacing: 5) {
                Rectangle().fill(Color(hex: previewLongLineHex)).frame(width: 38, height: 1)
                Rectangle().fill(Color(hex: previewShortLineHex)).frame(width: 20, height: 1).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 38)
            Text(title).font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(hex: selected ? previewHoverHex : (adjacent ? previewAdjacentHex : previewTextHex)))
                .lineLimit(1)
        }
    }
    private var previewSprite: NSImage {
        let url = Bundle.module.url(forResource: "slide-player", withExtension: "svg", subdirectory: "Resources")!
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = original.replacingOccurrences(of: "#556775", with: "#\(previewPlayingButtonHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))")
        return NSImage(data: Data(updated.utf8)) ?? NSImage(contentsOf: url)!
    }
}

private struct ColorField: View {
    let name: String
    @AppStorage private var value: String
    init(name: String, initial: String) {
        self.name = name
        self._value = AppStorage(wrappedValue: initial, "color.\(name)")
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12)).frame(width: 140, alignment: .leading)
            RoundedRectangle(cornerRadius: 5).fill(Color(hex: value)).frame(width: 26, height: 22).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "d6dfeb")))
            TextField("#RRGGBB", text: $value).font(.system(size: 12, weight: .semibold, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 90)
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if let image = NSImage(named: NSImage.Name("side-player")) ?? NSImage(contentsOf: Bundle.module.url(forResource: "side-player", withExtension: "png", subdirectory: "Resources")!) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 92, height: 92).clipShape(RoundedRectangle(cornerRadius: 18))
            }
            Text("side-player").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("融入侧栏的本地与网易云音乐混合播放器").font(.system(size: 14)).foregroundStyle(Color(hex: "556775"))
            Text("版本 1.0.0").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("© 北京正笔正心文化发展有限公司").font(.system(size: 13))
            Link("https://www.zhengxinshushe.com/", destination: URL(string: "https://www.zhengxinshushe.com/")!)
                .font(.system(size: 12)).foregroundStyle(Color(hex: "0756c6"))
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ToggleRow: View {
    let title: String; let subtitle: String; @Binding var isOn: Bool
    var body: some View {
        HStack { VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14, weight: .semibold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Toggle(title, isOn: $isOn).labelsHidden().tint(Color(hex: "ceba7b")) }.padding(.vertical, 11).overlay(alignment: .bottom) { Divider() }
    }
}

private struct QuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .foregroundStyle(Color(hex: "f33d32"))
            .background(configuration.isPressed ? Color(hex: "ffaaa4").opacity(0.18) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: "ffaaa4")))
    }
}

private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 7).background(Color(hex: "f3f4f8"), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "ccd7e7"))).foregroundStyle(Color(hex: "2a3f52")).opacity(configuration.isPressed ? 0.75 : 1) }
}
private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 8).background(Color(hex: "ceba7b"), in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(Color(hex: "2a3f52")).opacity(configuration.isPressed ? 0.75 : 1) }
}
