import AppKit
import SwiftUI

/// 色分けの種類
enum ClipCategory: String, CaseIterable, Identifiable {
    case text, link, image, video, file
    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "テキスト"
        case .link: return "リンク"
        case .image: return "画像"
        case .video: return "動画"
        case .file: return "ファイル"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .video: return "film"
        case .file: return "doc"
        }
    }

    var color: Color {
        switch self {
        case .text: return .blue
        case .link: return .purple
        case .image: return .orange
        case .video: return .pink
        case .file: return .teal
        }
    }
}

/// 並び順・絞り込み
enum ClipFilter {
    static func apply(_ items: [ClipItem], state: PanelState, size: (ClipItem) -> Int64 = { _ in 0 }) -> [ClipItem] {
        var list = items.filter { $0.pinned } + items.filter { !$0.pinned }
        if let k = state.kind { list = list.filter { $0.category == k } }
        if let a = state.app { list = list.filter { $0.appKey == a } }
        let q = state.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.text.lowercased().contains(q) || $0.app.lowercased().contains(q) }
        }
        if state.sortBySize {
            // 保存している大きさの順（同じ大きさは今の並びのまま）
            let order = StoragePolicy.sizeOrder(list.map(size))
            list = order.map { list[$0] }
        } else if state.sortByApp {
            // アプリ名でまとめる（同じアプリの中は新しい順のまま）
            list = list.enumerated()
                .sorted { ($0.element.app.lowercased(), $0.offset) < ($1.element.app.lowercased(), $1.offset) }
                .map(\.element)
        }
        return list
    }

    struct AppEntry: Identifiable {
        let key: String
        let name: String
        let bundleID: String
        let count: Int
        var id: String { key }
    }

    /// コピー元アプリの一覧（件数の多い順）
    static func apps(_ items: [ClipItem]) -> [AppEntry] {
        var dict: [String: AppEntry] = [:]
        for it in items where !it.appKey.isEmpty {
            let old = dict[it.appKey]
            dict[it.appKey] = AppEntry(key: it.appKey, name: it.app.isEmpty ? it.appID : it.app,
                                       bundleID: it.appID, count: (old?.count ?? 0) + 1)
        }
        return dict.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

/// アプリのアイコン（何度も読まないように保持）
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundleID: String) -> NSImage? {
        if bundleID.isEmpty { return nil }
        if let img = cache[bundleID] { return img }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = img
        return img
    }
}

struct PanelView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = ClipFilter.apply(store.items, state: state, size: store.cachedBytes(of:))
        VStack(alignment: .leading, spacing: 8) {
            header
            if items.isEmpty {
                Text(store.items.isEmpty ? "まだ何もありません。⌘C でコピーすると、ここにたまります。" : "一致する項目はありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cards(items)
            }
            footer
        }
        .padding(.vertical, 12)
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }

    // 1段目: 検索・種類・コピー元アプリ
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("検索", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .frame(width: 150)
            Divider().frame(height: 22)
            Chip(title: "すべて", symbol: nil, color: .gray, on: state.kind == nil) { state.kind = nil }
            ForEach(ClipCategory.allCases) { c in
                Chip(title: c.label, symbol: c.symbol, color: c.color, on: state.kind == c) {
                    state.kind = state.kind == c ? nil : c
                }
            }
            Divider().frame(height: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "全アプリ", symbol: "square.grid.2x2", color: .gray, on: state.app == nil) { state.app = nil }
                    ForEach(ClipFilter.apps(store.items).prefix(10)) { a in
                        AppChip(entry: a, on: state.app == a.key) {
                            state.app = state.app == a.key ? nil : a.key
                        }
                    }
                }
            }
            Chip(title: "アプリ順", symbol: "arrow.up.arrow.down", color: .gray, on: state.sortByApp) {
                state.sortByApp.toggle()
                if state.sortByApp { state.sortBySize = false }
            }
            Chip(title: "大きい順", symbol: "externaldrive", color: .gray, on: state.sortBySize) {
                state.sortBySize.toggle()
                if state.sortBySize { state.sortByApp = false }
                state.selected = 0
            }
        }
        .padding(.horizontal, 18)
    }

    // 2段目: カード
    private func cards(_ items: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CardView(item: item, index: index, isCursor: index == state.selected, showSize: state.sortBySize,
                                 pickOrder: state.picked.firstIndex(of: item.id).map { $0 + 1 },
                                 store: store, onTogglePick: { state.togglePick(item.id) })
                            .id(item.id)
                            // ダブルクリック＝貼り付け
                            .onTapGesture(count: 2) {
                                state.selected = index
                                if state.picked.isEmpty { actions.paste(item) }
                            }
                            // クリック＝選ぶだけ（⌘・⇧クリックで複数選択）
                            .onTapGesture {
                                state.selected = index
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) || mods.contains(.shift) || !state.picked.isEmpty {
                                    state.togglePick(item.id)
                                }
                            }
                            .onDrag { dragProvider(item) }
                            .contextMenu {
                                if item.kind == .text {
                                    Section("変換して貼り付け") {
                                        ForEach(TextTransform.allCases.filter { !$0.isTable }) { t in
                                            Button(t.title) { actions.transform(item, t) }
                                        }
                                    }
                                    Section {
                                        ForEach(TextTransform.allCases.filter { $0.isTable }) { t in
                                            Button(t.title) { actions.transform(item, t) }
                                        }
                                    }
                                }
                                Section {
                                    Button("iPhone に送る") { actions.sendToPhone([item]) }
                                }
                                Section {
                                    Button(item.pinned ? "ピンを外す" : "ピン留め") { store.togglePin(item.id) }
                                    Button("削除", role: .destructive) { store.delete(item.id) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .onChange(of: state.selected) { _, newValue in
                guard items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(items[newValue].id, anchor: .center)
                }
            }
        }
    }

    // 3段目: 複数選択中の操作、またはキー操作のヒント
    private var footer: some View {
        HStack(spacing: 10) {
            if state.needsTrust {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("自動貼り付けの許可がありません。今は「コピーまで」なので、選んだあと ⌘V を押してください。")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Button("許可の設定を開く") { actions.openTrust() }
                    .buttonStyle(.borderedProminent)
            } else if state.picked.isEmpty && state.sortBySize {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                Text("容量 \(sizeString(store.cachedTotalBytes())) ／ 上限 \(StoragePolicy.label(mb: Settings.maxStorageMB))　大きい順です。⌘クリック・Space・⇧← → で選んで、⌘⌫ で削除（2回押して確定）")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(1)
            } else if state.picked.isEmpty {
                Text("クリック 選ぶ　ダブルクリック／Enter 貼り付け　⌘クリック・Space 複数選択　⌘T・右クリック 変換　⌘I iPhone へ　Tab 種類　⌘1〜9　⌘P ピン　⌘⌫ 削除　Esc")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(1)
            } else {
                Text("\(state.picked.count)件を選択中（\(sizeString(pickedBytes))）")
                    .font(.system(size: 13, weight: .semibold))
                if state.confirmDelete {
                    Button { actions.deletePicked() } label: {
                        Label("もう一度押すと削除（\(state.picked.count)件・\(sizeString(pickedBytes))）", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Button { actions.pastePicked(false) } label: {
                    Label("順番に貼り付け　Enter", systemImage: "list.number")
                }
                .buttonStyle(.borderedProminent)
                Button { actions.pastePicked(true) } label: {
                    Label("まとめて1回で貼り付け　⇧Enter", systemImage: "square.stack")
                }
                Button {
                    actions.sendToPhone(state.picked.compactMap { id in store.items.first { $0.id == id } })
                } label: {
                    Label("iPhone に送る　⌘I", systemImage: "iphone")
                }
                if !state.confirmDelete {
                    Button { actions.deletePicked() } label: {
                        Label("削除　⌘⌫", systemImage: "trash")
                    }
                }
                Button { state.picked = [] } label: {
                    Label("選択を解除　Esc", systemImage: "xmark")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 28)
    }

    private var pickedBytes: Int64 {
        state.picked.compactMap { id in store.items.first { $0.id == id } }
            .reduce(Int64(0)) { $0 + store.cachedBytes(of: $1) }
    }

    private func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 他のアプリへドラッグして渡す
    private func dragProvider(_ item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: item.text as NSString)
        case .image:
            return NSItemProvider(contentsOf: store.imageURL(item.id)) ?? NSItemProvider()
        case .files:
            guard let first = item.paths.first else { return NSItemProvider() }
            return NSItemProvider(contentsOf: URL(fileURLWithPath: first)) ?? NSItemProvider()
        }
    }
}

/// 絞り込み用の小さなボタン
struct Chip: View {
    let title: String
    let symbol: String?
    let color: Color
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Color.white : color)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? color : color.opacity(0.22)))
            .overlay(Capsule().strokeBorder(color.opacity(on ? 0 : 0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// コピー元アプリのボタン（アイコン＋名前＋件数）
struct AppChip: View {
    let entry: ClipFilter.AppEntry
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = AppIcons.icon(entry.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text("\(entry.name) \(entry.count)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.22)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(on ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct CardView: View {
    let item: ClipItem
    let index: Int
    let isCursor: Bool
    /// 保存している大きさを、カードの上に大きく見せる（大きい順のとき）
    let showSize: Bool
    let pickOrder: Int?
    let store: ClipStore
    let onTogglePick: () -> Void

    var body: some View {
        let cat = item.category
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // 種類のラベル（色分け）
                HStack(spacing: 3) {
                    Image(systemName: cat.symbol).font(.system(size: 10, weight: .bold))
                    Text(cat.label).font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(Capsule().fill(cat.color))
                if item.hasRTF {
                    Text("書式").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if showSize, store.cachedBytes(of: item) > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: store.cachedBytes(of: item), countStyle: .file))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                }
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange)
                }
                // 複数選択の丸（番号付き）
                Button(action: onTogglePick) {
                    ZStack {
                        Circle().fill(pickOrder != nil ? Color.accentColor : Color.clear)
                        Circle().strokeBorder(pickOrder != nil ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                        if let n = pickOrder {
                            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("複数選択に入れる／外す")
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                if let icon = AppIcons.icon(item.appID) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(footerText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if index < 9 {
                    Text("⌘\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 230, height: 220)
        .background(
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                if pickOrder != nil { RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)) }
                cat.color.frame(height: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCursor ? Color.accentColor : (pickOrder != nil ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)),
                        lineWidth: isCursor ? 3 : (pickOrder != nil ? 2 : 1))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text.prefix(600))
                .font(.system(size: 13))
                .lineLimit(8)
                .foregroundStyle(item.category == .link ? Color.purple : Color.primary)
        case .image:
            if let img = ThumbCache.shared.image(for: item, store: store) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
        case .files where item.category == .video:
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    if let img = ThumbCache.shared.image(for: item, store: store) {
                        Image(nsImage: img).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)).frame(height: 100)
                    }
                    if item.duration > 0 {
                        Text(Self.timeText(item.duration))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 110)
                .overlay(Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 2))
                Text(item.text).font(.system(size: 12)).lineLimit(2)
            }
        case .files:
            VStack(alignment: .leading, spacing: 6) {
                if let img = ThumbCache.shared.image(for: item, store: store) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 100)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths.first ?? "/"))
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(3)
            }
        }
    }

    private var footerText: String {
        // 直後は「0秒後」と表示されてしまうので、1分以内は「たった今」にする
        let now = Date()
        let when = now.timeIntervalSince(item.date) < 60
            ? "たった今" : CardView.relative.localizedString(for: item.date, relativeTo: now)
        let from = item.app.isEmpty ? "" : "\(item.app)・"
        switch item.kind {
        case .text: return "\(from)\(item.text.count)文字・\(when)"
        case .image:
            let size = ByteCountFormatter.string(fromByteCount: store.cachedBytes(of: item), countStyle: .file)
            return "\(from)\(item.width)×\(item.height)・\(size)・\(when)"
        case .files:
            if item.category == .video, item.duration > 0 {
                return "\(from)\(Self.timeText(item.duration))\(item.width > 0 ? "・\(item.width)×\(item.height)" : "")・\(when)"
            }
            if item.paths.count == 1, item.width > 0 { return "\(from)\(item.width)×\(item.height)・\(when)" }
            return "\(from)\(item.paths.count)件・\(when)"
        }
    }

    /// 秒 → 「1:05」「1:02:03」
    static func timeText(_ sec: Double) -> String {
        let t = Int(sec.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f
    }()
}
