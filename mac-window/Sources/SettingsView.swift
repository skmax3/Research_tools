import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// 設定画面から呼ぶ操作
struct SettingsActions {
    let apply: (Preset) -> Void
    let capture: (ScreenTarget) -> [Slot]
    let tryAI: () -> Void
    let openAccessibility: () -> Void
}

final class SettingsWindowController {
    private let settings: AppSettings
    private let actions: SettingsActions
    private var window: NSWindow?

    init(settings: AppSettings, actions: SettingsActions) {
        self.settings = settings
        self.actions = actions
    }

    func show(tab: SettingsTab = .presets) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, actions: actions, initialTab: tab))
            let w = NSWindow(contentViewController: host)
            w.title = "窓割り の設定"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 940, height: 700))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: Hashable { case presets, ai, general }

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @State var initialTab: SettingsTab

    var body: some View {
        TabView(selection: $initialTab) {
            PresetsTab(settings: settings, actions: actions)
                .tabItem { Label("配置プリセット", systemImage: "rectangle.split.3x1") }
                .tag(SettingsTab.presets)
            AITab(settings: settings, actions: actions)
                .tabItem { Label("AI と並べる", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            GeneralTab(settings: settings, actions: actions)
                .tabItem { Label("一般・ショートカット", systemImage: "keyboard") }
                .tag(SettingsTab.general)
        }
        .padding()
        .frame(minWidth: 900, minHeight: 640)
    }
}

// MARK: - アプリの選択

/// アプリの候補（起動中のアプリ ＋ よく使うアプリ ＋ フォルダから選ぶ）
struct AppChoice: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static func running() -> [AppChoice] {
        var seen = Set<String>()
        var list: [AppChoice] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app != NSRunningApplication.current {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            list.append(AppChoice(bundleID: bid, name: app.localizedName ?? bid))
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func knownInstalled() -> [AppChoice] {
        KnownApp.all
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map { AppChoice(bundleID: $0.bundleID, name: $0.name) }
    }

    /// アプリケーションフォルダからアプリを選ぶ
    static func pickFromDisk() -> AppChoice? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "選ぶ"
        guard panel.runModal() == .OK, let url = panel.url, let b = Bundle(url: url), let bid = b.bundleIdentifier else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppChoice(bundleID: bid, name: name)
    }
}

/// アプリのアイコン
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 20

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
                .help("このアプリはこの Mac に見つかりません")
        }
    }
}

struct AppMenu: View {
    let title: String
    let onPick: (AppChoice) -> Void

    var body: some View {
        Menu {
            Section("起動中のアプリ") {
                ForEach(AppChoice.running()) { c in Button(c.name) { onPick(c) } }
            }
            Section("よく使うアプリ") {
                ForEach(AppChoice.knownInstalled()) { c in Button(c.name) { onPick(c) } }
            }
            Divider()
            Button("アプリケーションフォルダから選ぶ…") {
                if let c = AppChoice.pickFromDisk() { onPick(c) }
            }
        } label: {
            Text(title).lineLimit(1)
        }
    }
}

// MARK: - 配置プリセット

/// 図で行ごとに色を変える
let slotColors: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .yellow, .red, .indigo, .mint]

struct PresetsTab: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @State private var selected: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selected) {
                    ForEach(Array(settings.presets.enumerated()), id: \.element.id) { i, p in
                        HStack(spacing: 6) {
                            Text(i < 9 ? "⌃⌥\(i + 1)" : "　")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .leading)
                            Text(p.name).lineLimit(2)
                        }
                        .tag(p.id)
                    }
                    .onMove { settings.presets.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(width: 250)
                HStack(spacing: 4) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("新しいプリセット")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .help("複製")
                        .disabled(selected == nil)
                    Button { remove() } label: { Image(systemName: "minus") }
                        .help("削除")
                        .disabled(selected == nil)
                    Spacer()
                    Button { shift(-1) } label: { Image(systemName: "chevron.up") }
                        .help("上へ（ショートカットの番号が変わる）")
                        .disabled(selected == nil)
                    Button { shift(1) } label: { Image(systemName: "chevron.down") }
                        .help("下へ")
                        .disabled(selected == nil)
                }
                .frame(width: 250)
                Text("上から順に ⌃⌥1〜9 で呼び出せます。ドラッグでも並べ替えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 250, alignment: .leading)
            }
            if let id = selected, let i = settings.presets.firstIndex(where: { $0.id == id }) {
                PresetEditor(preset: binding(for: id), index: i, actions: actions)
                    .id(id)
            } else {
                Text("左の一覧からプリセットを選んでください")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selected == nil { selected = settings.presets.first?.id } }
    }

    /// 削除しても落ちないように、番号ではなく ID でプリセットを探す
    private func binding(for id: UUID) -> Binding<Preset> {
        let fallback = settings.presets.first { $0.id == id } ?? Preset(name: "", slots: [])
        return Binding(
            get: { settings.presets.first { $0.id == id } ?? fallback },
            set: { new in
                if let i = settings.presets.firstIndex(where: { $0.id == id }) { settings.presets[i] = new }
            }
        )
    }

    private func add() {
        let p = Preset(name: "新しいプリセット", slots: [])
        settings.presets.append(p)
        selected = p.id
    }

    private func duplicate() {
        guard let id = selected, let i = settings.presets.firstIndex(where: { $0.id == id }) else { return }
        var p = settings.presets[i]
        p.id = UUID()
        p.name += " のコピー"
        p.slots = p.slots.map { var s = $0; s.id = UUID(); return s }
        settings.presets.insert(p, at: i + 1)
        selected = p.id
    }

    private func remove() {
        guard let id = selected, let i = settings.presets.firstIndex(where: { $0.id == id }) else { return }
        selected = nil
        settings.presets.remove(at: i)
        selected = settings.presets.isEmpty ? nil : settings.presets[min(i, settings.presets.count - 1)].id
    }

    private func shift(_ d: Int) {
        guard let id = selected, let i = settings.presets.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard j >= 0, j < settings.presets.count else { return }
        settings.presets.swapAt(i, j)
    }
}

struct PresetEditor: View {
    @Binding var preset: Preset
    let index: Int
    let actions: SettingsActions
    @State private var selectedSlot: UUID?
    @State private var confirmCapture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("プリセットの名前", text: $preset.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                if index < 9 {
                    Text("⌃⌥\(index + 1)")
                        .font(.body.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
                Button("今すぐ並べる") { actions.apply(preset) }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 20) {
                Picker("並べる画面", selection: $preset.screen) {
                    ForEach(ScreenTarget.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 360)
                Toggle("ほかのアプリを隠す（集中したいとき）", isOn: $preset.hideOthers)
            }

            GridSelector(cols: 12, rows: 6, highlight: selectedZone, highlightLabel: selectedLabel, others: otherZones,
                         onCommit: { z in setZone(z) })
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 560, maxHeight: 315)
            Text(selectedSlot == nil
                 ? "下の一覧で行を選ぶと、図をドラッグしてその場所を決められます（12 × 6 マス）。"
                 : "図をドラッグすると、選んでいる行（青）の場所が変わります。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(preset.slots.enumerated()), id: \.element.id) { i, slot in
                        SlotRow(slot: slotBinding(slot.id), number: i + 1, color: slotColors[i % slotColors.count],
                                selected: selectedSlot == slot.id,
                                onSelect: { selectedSlot = (selectedSlot == slot.id) ? nil : slot.id },
                                onDelete: { deleteSlot(slot.id) })
                    }
                    if preset.slots.isEmpty {
                        Text("「＋ アプリを追加」か「今の画面の配置を取り込む」で始めます。")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .frame(minHeight: 120)

            HStack {
                AppMenu(title: "＋ アプリを追加") { c in
                    let s = Slot(bundleID: c.bundleID, appName: c.name, zone: NamedZone.maximize.zone)
                    preset.slots.append(s)
                    selectedSlot = s.id
                }
                .fixedSize()
                Button("今の画面の配置を取り込む…") { confirmCapture = true }
                    .help("いま画面に並んでいるウィンドウの位置を、このプリセットに読み込みます")
                Spacer()
            }
        }
        .confirmationDialog("今の画面の配置を取り込みますか？", isPresented: $confirmCapture) {
            Button("取り込む（今の行は消える）") {
                let slots = actions.capture(preset.screen)
                if !slots.isEmpty {
                    preset.slots = slots
                    selectedSlot = nil
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(preset.screen.title)」に見えているウィンドウの位置を読み取り、このプリセットの一覧を置き換えます。")
        }
    }

    private var selectedZone: Zone? {
        preset.slots.first { $0.id == selectedSlot }?.zone
    }

    private var selectedLabel: String {
        guard let i = preset.slots.firstIndex(where: { $0.id == selectedSlot }) else { return "" }
        return "\(i + 1). \(preset.slots[i].appName)"
    }

    private var otherZones: [LabeledZone] {
        preset.slots.enumerated().compactMap { i, s in
            s.id == selectedSlot ? nil
                : LabeledZone(id: s.id, zone: s.zone, label: "\(i + 1). \(s.appName)", color: slotColors[i % slotColors.count])
        }
    }

    private func setZone(_ z: Zone) {
        guard let i = preset.slots.firstIndex(where: { $0.id == selectedSlot }) else { NSSound.beep(); return }
        preset.slots[i].zone = z
    }

    private func slotBinding(_ id: UUID) -> Binding<Slot> {
        let fallback = preset.slots.first { $0.id == id } ?? Slot(bundleID: "", appName: "", zone: NamedZone.maximize.zone)
        return Binding(
            get: { preset.slots.first { $0.id == id } ?? fallback },
            set: { new in if let i = preset.slots.firstIndex(where: { $0.id == id }) { preset.slots[i] = new } }
        )
    }

    private func deleteSlot(_ id: UUID) {
        if selectedSlot == id { selectedSlot = nil }
        preset.slots.removeAll { $0.id == id }
    }
}

struct SlotRow: View {
    @Binding var slot: Slot
    let number: Int
    let color: Color
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text("\(number)").font(.body.monospacedDigit()).frame(width: 18)
            AppIconView(bundleID: slot.bundleID)
            AppMenu(title: slot.appName) { c in
                slot.bundleID = c.bundleID
                slot.appName = c.name
            }
            .frame(width: 210)
            Menu {
                ForEach(NamedZone.groups, id: \.self) { g in
                    Section(g) {
                        ForEach(NamedZone.allCases.filter { $0.group == g }) { z in
                            Button(z.title) { slot.zone = z.zone }
                        }
                    }
                }
            } label: {
                Text(NamedZone.named(slot.zone)?.title ?? "図で指定した場所")
            }
            .frame(width: 180)
            Toggle("なければ起動", isOn: $slot.launch)
                .toggleStyle(.checkbox)
                .help("アプリが起動していない（ウィンドウがない）ときは、起動してから並べます")
            Spacer()
            Button { onSelect() } label: {
                Image(systemName: selected ? "square.grid.3x3.fill" : "square.grid.3x3")
            }
            .buttonStyle(.borderless)
            .help("図で場所を決める")
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("この行を消す")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - AI と並べる

struct AITab: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("AI のアプリ") {
                    HStack {
                        AppIconView(bundleID: settings.aiBundleID)
                        AppMenu(title: settings.aiName) { c in
                            settings.aiBundleID = c.bundleID
                            settings.aiName = c.name
                        }
                        .fixedSize()
                    }
                }
                Picker("AI を置く側", selection: $settings.aiOnLeft) {
                    Text("左").tag(true)
                    Text("右").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("AI の幅", selection: $settings.aiFraction) {
                    Text("1/4").tag(0.25)
                    Text("1/3").tag(1.0 / 3.0)
                    Text("2/5").tag(0.4)
                    Text("1/2").tag(0.5)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("⌃⌥A で、いま作業中のウィンドウの横に AI のウィンドウを出します")
            } footer: {
                Text("AI が起動していなければ起動します。ブラウザで AI を使う場合は、そのブラウザを選んでください（ブラウザの手前のウィンドウが AI 側に来ます）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("並び方") {
                let z = AIPairing.zones(aiOnLeft: settings.aiOnLeft, fraction: settings.aiFraction)
                GridSelector(cols: 12, rows: 6, others: [
                    LabeledZone(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, zone: z.ai,
                                label: "AI（\(settings.aiName)）", color: .orange),
                    LabeledZone(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, zone: z.work,
                                label: "作業中のウィンドウ", color: .blue),
                ])
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 480)
                .allowsHitTesting(false)
                Button("試す（AI を出す）") { actions.tryAI() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 一般

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var trusted = WindowMover.trusted
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("見た目") {
                HStack {
                    Slider(value: $settings.gap, in: 0...24, step: 2) { Text("ウィンドウのすき間") }
                    Text("\(Int(settings.gap)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            Section("起動と許可") {
                Toggle("ログイン時に起動", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            loginOn = SMAppService.mainApp.status == .enabled
                        }
                    }
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "アクセシビリティ: 許可済み（ウィンドウを動かせます）"
                                 : "アクセシビリティ: 未許可（ウィンドウを動かすのに必要です）")
                    Spacer()
                    if !trusted {
                        Button("許可の設定を開く") { actions.openAccessibility() }
                    }
                }
                .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                    trusted = WindowMover.trusted
                }
            }
            Section("ショートカット（どのアプリを使っていても効きます）") {
                ShortcutTable(items: Shortcut.windowKeys + Shortcut.toolKeys)
                Text("⌃⌥1〜9: 配置プリセット（「配置プリセット」の一覧の上から順）")
                    .font(.callout)
                Text("⌃ = control、⌥ = option、⌘ = command。ほかのウィンドウ整理アプリ（Rectangle など）と同じキーは同時に使えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("配置プリセットを最初の状態に戻す…") { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("配置プリセットを最初の状態に戻しますか？", isPresented: $confirmReset) {
            Button("戻す（今のプリセットは消える）", role: .destructive) { settings.resetPresets() }
            Button("キャンセル", role: .cancel) {}
        }
    }
}

struct ShortcutTable: View {
    let items: [Shortcut]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(items) { s in
                GridRow {
                    Text(s.label)
                        .font(.body.monospaced())
                        .frame(width: 80, alignment: .leading)
                    Text(s.title)
                }
            }
        }
    }
}
