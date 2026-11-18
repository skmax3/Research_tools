import AppKit
import Combine
import SwiftUI

/// 枠に入っているもの
enum SlotFill: Equatable {
    case empty
    case candidate(String)                    // 開いているウィンドウ（WindowCandidate.id）
    case app(bundleID: String, name: String)  // プリセットのアプリ（起動して並べる）
}

/// 配置パネルの状態。配置案を選ぶ → 枠にウィンドウを入れる → 並べる
final class LayoutBoardModel: ObservableObject {
    enum Mode: Hashable { case layout, single }

    struct Choice: Identifiable {
        let id: String
        let name: String
        let zones: [Zone]
        let fullScreen: [Bool]
        let preset: Preset?
        let shortcut: String?

        func isFullScreen(_ i: Int) -> Bool { i < fullScreen.count && fullScreen[i] }
    }

    @Published var mode: Mode = .layout
    @Published var screenIndex: Int
    @Published var choiceID: String
    @Published var fills: [SlotFill] = []
    @Published var selectedSlot: Int?
    @Published var candidates: [WindowCandidate]
    @Published private(set) var choices: [Choice] = []
    /// 並べるときに、ほかのアプリを隠す（設定に保存して、次に開いたときも同じにする）
    @Published var hideOthers: Bool { didSet { settings.panelHideOthers = hideOthers } }

    let screens: [WindowMover.ScreenInfo]
    private let settings: AppSettings
    private let mover: WindowMover
    private var sub: AnyCancellable?

    // 「手前のウィンドウだけ動かす」用
    let target: AXUIElement?
    let targetName: String?
    let targetZone: Zone?
    let targetArea: CGRect?

    init(mover: WindowMover, screens: [WindowMover.ScreenInfo], screenIndex: Int,
         target: AXUIElement?, targetName: String?, targetZone: Zone?, targetArea: CGRect?) {
        self.mover = mover
        self.settings = mover.settings
        hideOthers = mover.settings.panelHideOthers
        self.screens = screens
        self.screenIndex = screenIndex
        self.target = target
        self.targetName = targetName
        self.targetZone = targetZone
        self.targetArea = targetArea
        candidates = WindowList.candidates()
        // MacBook 本体の画面はフルスクリーンで使うことが多いので、最初の配置案を変える
        choiceID = screens.indices.contains(screenIndex) && screens[screenIndex].builtin ? "full" : "thirds"
        rebuildChoices()
        autoFill()
        // 最小サイズを測った・覚えたら、警告とおすすめを描き直す
        sub = settings.$minSizes.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var choice: Choice { choices.first { $0.id == choiceID } ?? choices[0] }
    var area: CGRect { screens[screenIndex].area }
    var aspect: CGFloat { area.width / max(area.height, 1) }

    func rebuildChoices() {
        let templates = LayoutTemplate.builtIn.map {
            Choice(id: $0.id, name: $0.name, zones: $0.zones, fullScreen: $0.fullScreen, preset: nil, shortcut: nil)
        }
        let presets = settings.presets.enumerated().map { i, p in
            Choice(id: "preset-\(p.id.uuidString)", name: p.name, zones: p.slots.map(\.zone),
                   fullScreen: p.slots.map(\.fullScreen), preset: p,
                   shortcut: i < Shortcut.presetKeys.count ? settings.combo(for: Shortcut.presetKeys[i])?.label : nil)
        }
        choices = templates + presets
    }

    func choose(_ id: String) {
        let f = simulatedFills(for: choices.first { $0.id == id } ?? choice, carry: fills)
        choiceID = id
        fills = f
        selectedSlot = f.firstIndex(of: .empty) ?? 0
    }

    /// 枠に、それらしいウィンドウを最初から入れておく（あとで入れ替えればよい）
    func autoFill() {
        fills = simulatedFills(for: choice, carry: [])
        selectedSlot = fills.firstIndex(of: .empty) ?? 0
    }

    /// 配置案 c を選んだときに枠に入るもの。
    /// プリセットはそのアプリ。ひな形は、いま枠に入れているもの（carry）を順に引き継ぎ、残りを手前のウィンドウで埋める
    func simulatedFills(for c: Choice, carry: [SlotFill]) -> [SlotFill] {
        var f = Array(repeating: SlotFill.empty, count: c.zones.count)
        var used = Set<String>()
        if let p = c.preset {
            // プリセット: 同じアプリのウィンドウを入れる。なければ「起動して並べる」
            for (i, s) in p.slots.enumerated() where i < f.count {
                if let cand = candidates.first(where: { $0.bundleID == s.bundleID && !used.contains($0.id) }) {
                    f[i] = .candidate(cand.id)
                    used.insert(cand.id)
                } else if s.launch {
                    f[i] = .app(bundleID: s.bundleID, name: s.appName)
                }
            }
        } else {
            // ひな形: いま入れているものを引き継ぎ、残りは手前にあるウィンドウから順に入れる
            var queue = carry.filter { $0 != .empty }
            for fill in queue { if case .candidate(let id) = fill { used.insert(id) } }
            queue += candidates.filter { $0.window != nil && !$0.isMinimized && !used.contains($0.id) }.map { SlotFill.candidate($0.id) }
            for i in f.indices where i < queue.count { f[i] = queue[i] }
        }
        return f
    }

    // MARK: アプリの最小サイズ（警告・おすすめ）

    func bundleID(_ f: SlotFill) -> String? {
        switch f {
        case .empty: return nil
        case .candidate(let id): return candidate(id)?.bundleID
        case .app(let bid, _): return bid
        }
    }

    func minSize(_ bid: String?) -> MinSize? { bid.flatMap { settings.minSizes[$0] } }

    /// 場所 z の実際の枠（すき間・端の余白を引いたもの）
    func frame(_ z: Zone) -> CGRect {
        Geometry.frame(for: z, in: area, gap: CGFloat(settings.gap), edge: CGFloat(settings.edgeGap))
    }

    /// 配置案 c に fills を入れたとき、枠ごとに収まるか（フルスクリーンにする枠は調べない）
    func fits(for c: Choice, fills: [SlotFill]) -> [SlotFit] {
        var minW: [Double] = [], minH: [Double] = []
        for (i, z) in c.zones.enumerated() {
            let m = c.isFullScreen(i) || !fills.indices.contains(i) ? nil : minSize(bundleID(fills[i]))
            let f = frame(z)
            minW.append(m.map { Fit.fraction(minPt: $0.w, zoneSize: z.w, frameSize: Double(f.width), areaSize: Double(area.width)) } ?? 0)
            minH.append(m.map { Fit.fraction(minPt: $0.h, zoneSize: z.h, frameSize: Double(f.height), areaSize: Double(area.height)) } ?? 0)
        }
        return Fit.check(zones: c.zones, minW: minW, minH: minH)
    }

    var slotFits: [SlotFit] { fits(for: choice, fills: fills) }

    /// 配置案の一覧に付ける印（いちばん悪いもの）
    func choiceFit(_ c: Choice) -> SlotFit {
        let r = fits(for: c, fills: c.id == choiceID ? fills : simulatedFills(for: c, carry: fills))
        if r.contains(.overlap) { return .overlap }
        return r.contains(.adjusted) ? .adjusted : .ok
    }

    /// 枠に出す説明（収まらないときだけ）
    func slotNote(_ i: Int) -> String? {
        let fits = slotFits
        guard fits.indices.contains(i), fits[i] != .ok, fills.indices.contains(i),
              let m = minSize(bundleID(fills[i])) else { return nil }
        let f = frame(choice.zones[i])
        let tail = fits[i] == .overlap ? "重なります" : "隣を細くして並べます"
        if m.w > Double(f.width) + 1 { return "最小の幅 \(Int(m.w)) pt ／ 枠 \(Int(f.width)) pt\n→ \(tail)" }
        return "最小の高さ \(Int(m.h)) pt ／ 枠 \(Int(f.height)) pt\n→ \(tail)"
    }

    /// アプリのおすすめの幅（選んでいる画面で）。短い表示と、詳しい説明
    func recommendation(_ bid: String) -> (short: String, long: String)? {
        guard let m = minSize(bid) else { return nil }
        let widths: [(String, NamedZone)] = [
            ("1/4", .leftQuarter), ("1/3", .leftThird), ("1/2", .leftHalf), ("2/3", .leftTwoThirds), ("全体", .maximize),
        ]
        let list: [(name: String, width: Double)] = widths.map { (name: $0.0, width: Double(frame($0.1.zone).width)) }
        let screen = screens[screenIndex].name
        var long: String
        let short: String
        if let name = Fit.recommend(minWidth: m.w, choices: list) {
            short = name == "1/4" ? "どの幅でも" : name == "全体" ? "全体で" : "\(name) 以上"
            long = name == "1/4" ? "\(screen) では 1/4 の幅にも入ります" : "\(screen) では \(name) 以上の幅がおすすめ"
        } else {
            short = "入りきらない"
            long = "\(screen) の幅に入りきりません"
        }
        long += "（最小 \(Int(m.w)) × \(Int(m.h)) pt）"
        if m.h > Double(frame(NamedZone.topHalf.zone).height) + 1 { long += "。上下に分けた枠には入りません" }
        return (short, long)
    }

    /// まだ最小サイズが分からないアプリを測る（各アプリ 1 回だけ。ウィンドウが一瞬小さくなって戻る）
    func measureUnknown() {
        var done = Set<String>()
        for c in candidates {
            guard let w = c.window, !c.isFullScreen, !c.isMinimized, !c.isHidden,
                  settings.minSizes[c.bundleID] == nil, !done.contains(c.bundleID) else { continue }
            done.insert(c.bundleID)
            mover.measureMinSize(w)
        }
    }

    func candidate(_ id: String) -> WindowCandidate? { candidates.first { $0.id == id } }

    func slotIndex(of id: String) -> Int? { fills.firstIndex(of: .candidate(id)) }

    /// 枠にウィンドウを入れる。ほかの枠に入っていたら、入れ替える
    func assign(_ id: String, to slot: Int) {
        guard fills.indices.contains(slot) else { return }
        if let old = slotIndex(of: id), old != slot { fills[old] = fills[slot] }
        fills[slot] = .candidate(id)
        selectedSlot = nextEmpty(after: slot) ?? slot
    }

    /// 一覧のウィンドウをクリックしたとき：選んでいる枠（なければ空いている枠）に入れる
    func tap(_ id: String) {
        assign(id, to: selectedSlot ?? fills.firstIndex(of: .empty) ?? 0)
    }

    func clear(_ slot: Int) {
        guard fills.indices.contains(slot) else { return }
        fills[slot] = .empty
        selectedSlot = slot
    }

    func clearAll() {
        fills = Array(repeating: .empty, count: fills.count)
        selectedSlot = 0
    }

    private func nextEmpty(after slot: Int) -> Int? {
        let later = fills.indices.filter { $0 > slot && fills[$0] == .empty }
        return later.first ?? fills.firstIndex(of: .empty)
    }

    func reload() {
        candidates = WindowList.candidates()
        rebuildChoices()
        autoFill()
        measureUnknown()
    }

    /// 並べるための一覧（空の枠は飛ばす）
    func items() -> [WindowMover.ArrangeItem] {
        let c = choice
        return fills.enumerated().compactMap { i, f in
            guard i < c.zones.count else { return nil }
            switch f {
            case .empty:
                return nil
            case .candidate(let id):
                guard let cand = candidate(id) else { return nil }
                return WindowMover.ArrangeItem(window: cand.window, bundleID: cand.bundleID, zone: c.zones[i],
                                               fullScreen: c.isFullScreen(i))
            case .app(let bid, _):
                return WindowMover.ArrangeItem(window: nil, bundleID: bid, zone: c.zones[i], fullScreen: c.isFullScreen(i))
            }
        }
    }

    /// プリセットとして保存するための行
    func slotsForPreset() -> [Slot] {
        let c = choice
        return fills.enumerated().compactMap { i, f in
            guard i < c.zones.count else { return nil }
            switch f {
            case .empty:
                return nil
            case .candidate(let id):
                guard let cand = candidate(id) else { return nil }
                return Slot(bundleID: cand.bundleID, appName: cand.appName, zone: c.zones[i], fullScreen: c.isFullScreen(i))
            case .app(let bid, let name):
                return Slot(bundleID: bid, appName: name, zone: c.zones[i], launch: true, fullScreen: c.isFullScreen(i))
            }
        }
    }

    /// 選んでいる画面を、プリセットの「並べる画面」に直す
    var screenTarget: ScreenTarget {
        let s = screens[screenIndex]
        if s.builtin { return .builtin }
        if let largest = WindowMover.largestArea(), largest == s.area { return .largest }
        return .mouse
    }
}

// MARK: - 画面

struct LayoutBoardView: View {
    @ObservedObject var model: LayoutBoardModel
    let aiName: String
    let onArrange: () -> Void
    let onSave: () -> Void
    let onAI: () -> Void
    let onSingleChange: (Zone) -> Void
    let onSingleCommit: (Zone) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.mode == .layout { layoutBody } else { singleBody }
        }
        .padding(16)
        .frame(width: 1060, height: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.mode) {
                Text("配置案から並べる").tag(LayoutBoardModel.Mode.layout)
                Text("手前のウィンドウだけ動かす").tag(LayoutBoardModel.Mode.single)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            if model.mode == .layout && model.screens.count > 1 {
                Picker("並べる画面", selection: $model.screenIndex) {
                    ForEach(model.screens.indices, id: \.self) { i in
                        Label(model.screens[i].name, systemImage: model.screens[i].builtin ? "laptopcomputer" : "display")
                            .tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
            }
            Spacer()
            Button { onAI() } label: { Label("AI と並べる（\(aiName)）", systemImage: "sparkles") }
                .controlSize(.small)
            Text("esc で閉じる").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 配置案から並べる

    private var layoutBody: some View {
        HStack(alignment: .top, spacing: 14) {
            choiceList.frame(width: 220)
            VStack(alignment: .leading, spacing: 10) {
                Text("「\(model.choice.name)」を \(model.screens[model.screenIndex].name) に並べる")
                    .font(.headline)
                    .lineLimit(1)
                board
                fitSummary
                Text("右の一覧のウィンドウを、枠へドラッグして入れます。クリックすると、選んでいる枠（青い線）に順に入ります。枠どうしで入れ替えるときも、一覧からドラッグします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { onArrange() } label: { Label("並べる（↩）", systemImage: "rectangle.3.group") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("プリセットとして保存") { onSave() }
                    Button("枠を空にする") { model.clearAll() }
                    Spacer()
                    Toggle("ほかのアプリを隠す", isOn: $model.hideOthers)
                        .help("並べるアプリ以外で、この画面・このデスクトップだけにあるアプリを隠します（⌘H と同じ。Dock や ⌘Tab で戻ります）")
                }
            }
            .frame(maxWidth: .infinity)
            candidateList.frame(width: 290)
        }
    }

    /// 収まらないアプリがあるときの説明
    @ViewBuilder private var fitSummary: some View {
        let fits = model.slotFits
        if fits.contains(.overlap) {
            Label("この画面では、入れたアプリの最小の幅（高さ）を合わせると入りきらず、重なります。配置案を変えるか、広い画面に並べてください。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if fits.contains(.adjusted) {
            Label("枠より狭くできないアプリがあります。並べるときに、隣の枠を細くして重ならないようにします。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choiceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("配置案").font(.caption).foregroundStyle(.secondary)
                ForEach(model.choices.filter { $0.preset == nil }) { choiceRow($0) }
                if model.choices.contains(where: { $0.preset != nil }) {
                    Divider().padding(.vertical, 4)
                    Text("保存したプリセット").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.choices.filter { $0.preset != nil }) { choiceRow($0) }
                }
            }
        }
    }

    private func choiceRow(_ c: LayoutBoardModel.Choice) -> some View {
        let selected = c.id == model.choiceID
        return Button { model.choose(c.id) } label: {
            HStack(spacing: 8) {
                ZoneIcon(zones: c.zones, size: CGSize(width: 44, height: 25), colors: slotColors)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).lineLimit(2)
                    if let s = c.shortcut { Text(s).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                switch model.choiceFit(c) {
                case .ok: EmptyView()
                case .adjusted:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("枠より狭くできないアプリがあります。隣の枠を細くして並べます")
                case .overlap:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .help("この画面では入りきらず、ウィンドウが重なります")
                }
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var board: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                ForEach(Array(model.choice.zones.enumerated()), id: \.offset) { i, z in
                    SlotBox(index: i,
                            fill: model.fills.indices.contains(i) ? model.fills[i] : .empty,
                            candidate: model.fills.indices.contains(i) ? candidateFor(model.fills[i]) : nil,
                            selected: model.selectedSlot == i,
                            fullScreen: model.choice.isFullScreen(i),
                            color: slotColors[i % slotColors.count],
                            fit: model.slotFits.indices.contains(i) ? model.slotFits[i] : .ok,
                            note: model.slotNote(i),
                            onTap: { model.selectedSlot = i },
                            onClear: { model.clear(i) },
                            onDrop: { id in
                                guard model.candidate(id) != nil else { return false }
                                model.assign(id, to: i)
                                return true
                            })
                        .frame(width: max(10, CGFloat(z.w) * size.width - 6), height: max(10, CGFloat(z.h) * size.height - 6))
                        .offset(x: CGFloat(z.x) * size.width + 3, y: CGFloat(z.y) * size.height + 3)
                }
            }
        }
        .aspectRatio(model.aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 420)
    }

    private func candidateFor(_ f: SlotFill) -> WindowCandidate? {
        if case .candidate(let id) = f { return model.candidate(id) }
        return nil
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("開いているウィンドウ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("一覧を読み直す")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.candidates) { c in
                        let rec = model.recommendation(c.bundleID)
                        CandidateRow(candidate: c, slot: model.slotIndex(of: c.id), recommendation: rec)
                            .onTapGesture { model.tap(c.id) }
                            .help(rec?.long ?? "")
                            .draggable(c.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        AppIconView(bundleID: c.bundleID, size: 20)
                                        Text(c.appName)
                                    }
                                    if let rec { Text(rec.long).font(.caption) }
                                }
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
            }
        }
    }

    // MARK: 手前のウィンドウだけ動かす

    private static let quick: [NamedZone] = [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                                      .leftHalf, .rightHalf, .centerHalf, .leftQuarter, .maximize]

    @ViewBuilder private var singleBody: some View {
        if let name = model.targetName, let area = model.targetArea {
            Text("「\(name)」をマス目のドラッグか、下のボタンで動かす").font(.headline)
            GridSelector(cols: 12, rows: 6, highlight: model.targetZone, highlightLabel: "いまの場所",
                         onChange: onSingleChange, onCommit: onSingleCommit)
                .aspectRatio(area.width / max(area.height, 1), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 440)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.quick) { z in
                    Button { onSingleCommit(z.zone) } label: {
                        VStack(spacing: 3) {
                            ZoneIcon(zones: [z.zone], size: CGSize(width: 36, height: 20))
                            Text(z.title).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            Text("動かすウィンドウがありません。「配置案から並べる」を使ってください。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 配置案の枠 1 つ
private struct SlotBox: View {
    let index: Int
    let fill: SlotFill
    let candidate: WindowCandidate?
    let selected: Bool
    let fullScreen: Bool
    let color: Color
    let fit: SlotFit
    let note: String?
    let onTap: () -> Void
    let onClear: () -> Void
    let onDrop: (String) -> Bool
    @State private var targeted = false

    private var warnColor: Color? { fit == .overlap ? .red : fit == .adjusted ? .orange : nil }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(targeted ? 0.55 : (fill == .empty ? 0.12 : 0.3)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor : warnColor ?? color.opacity(0.7),
                                lineWidth: selected || warnColor != nil ? 3 : 1.5)
                }
            content
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if fill != .empty {
                Button { onClear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("この枠を空にする")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            return onDrop(id)
        } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("\(index + 1)").font(.headline)
                if fullScreen {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").help("並べたあとフルスクリーンにする")
                }
            }
            switch fill {
            case .empty:
                Text("ここにウィンドウを\nドロップ").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .candidate:
                if let c = candidate {
                    AppIconView(bundleID: c.bundleID, size: 30)
                    Text(c.appName).font(.callout.weight(.semibold)).lineLimit(1)
                    if !c.title.isEmpty {
                        Text(c.title).font(.caption).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    warning
                } else {
                    Text("（ウィンドウが閉じられました）").font(.caption).foregroundStyle(.secondary)
                }
            case .app(let bid, let name):
                AppIconView(bundleID: bid, size: 30)
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Text("起動して並べる").font(.caption).foregroundStyle(.secondary)
                warning
            }
        }
    }

    @ViewBuilder private var warning: some View {
        if let note, let warnColor {
            Label(note, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(warnColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
    }
}

/// 開いているウィンドウの一覧の 1 行
private struct CandidateRow: View {
    let candidate: WindowCandidate
    let slot: Int?
    /// おすすめの幅（最小サイズが分かっているアプリだけ）
    let recommendation: (short: String, long: String)?

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundleID: candidate.bundleID, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.appName).font(.callout.weight(.semibold)).lineLimit(1)
                if !candidate.title.isEmpty {
                    Text(candidate.title).font(.caption).lineLimit(1)
                }
                if !candidate.badges.isEmpty {
                    Text(candidate.badges.joined(separator: " ・ ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let recommendation {
                Text(recommendation.short)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(recommendation.short == "入りきらない" ? Color.red : Color.secondary)
            }
            if let slot {
                Text("\(slot + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(slotColors[slot % slotColors.count], in: Circle())
                    .help("\(slot + 1) 番の枠に入っています")
            }
        }
        .padding(6)
        .background(slot != nil ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .opacity(candidate.window == nil ? 0.75 : 1)
    }
}
