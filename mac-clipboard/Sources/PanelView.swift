import AppKit
import SwiftUI

/// 並び順（ピン留めが先）と検索
enum ClipFilter {
    static func apply(_ items: [ClipItem], query: String) -> [ClipItem] {
        let ordered = items.filter { $0.pinned } + items.filter { !$0.pinned }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ordered }
        return ordered.filter { $0.text.lowercased().contains(q) || $0.app.lowercased().contains(q) }
    }
}

struct PanelView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    let onPick: (ClipItem, Bool) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = ClipFilter.apply(store.items, query: state.query)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("検索", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .frame(maxWidth: 300)
                Spacer()
                Text("←→ 選ぶ　Enter 貼り付け　⌥Enter 書式なし　⌘1〜9　⌘P ピン　⌘⌫ 削除　Esc 閉じる")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if items.isEmpty {
                Text(store.items.isEmpty ? "まだ何もありません。⌘C でコピーすると、ここにたまります。" : "一致する項目はありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                CardView(item: item, index: index, selected: index == state.selected, store: store)
                                    .id(item.id)
                                    .onTapGesture {
                                        state.selected = index
                                        onPick(item, false)
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
        }
        .padding(.bottom, 14)
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }
}

struct CardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let store: ClipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Text(item.app.isEmpty ? kindLabel : item.app)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(footer)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: 210, height: 200)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor).opacity(0.9)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text.prefix(600))
                .font(.system(size: 12))
                .lineLimit(9)
        case .image:
            if let img = ThumbCache.shared.image(for: item, store: store) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
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

    private var kindLabel: String {
        switch item.kind {
        case .text: return "テキスト"
        case .image: return "画像"
        case .files: return "ファイル"
        }
    }

    private var footer: String {
        let when = CardView.relative.localizedString(for: item.date, relativeTo: Date())
        switch item.kind {
        case .text: return "\(item.text.count)文字・\(when)"
        case .image: return "\(item.width)×\(item.height)・\(when)"
        case .files: return "\(item.paths.count)件・\(when)"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f
    }()
}
