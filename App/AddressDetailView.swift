import Charts
import SwiftUI
import WatchCore

/// One address: its balance, a balance-over-time chart, and its transactions, newest first.
/// History is fetched when the page opens and kept in memory only until the app locks.
struct AddressDetailView: View {
    let model: AppModel
    let address: String
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: WatchedAddress?
    @State private var confirmRemove = false
    @State private var expanded: Set<TxID> = []

    private var item: WatchedAddress? { model.vault?.watched.first { $0.address == address } }
    private var row: AddressStatus? { model.snapshot?.rows.first { $0.id == address } }
    private var history: AddressHistory? { model.histories[address] }
    private var loading: Bool { model.historyLoading.contains(address) }

    var body: some View {
        Group {
            if let item {
                List {
                    summarySection(item)
                    chartSection
                    activitySections
                    Section {
                        Button("Stop Watching", role: .destructive) { confirmRemove = true }
                            .accessibilityIdentifier("detail.remove")
                    }
                }
                .privacySensitive()
                .navigationTitle(item.label.isEmpty ? "Address" : item.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { renaming = item } label: { Image(systemName: "pencil") }
                            .accessibilityLabel("Rename")
                            .accessibilityIdentifier("detail.edit")
                    }
                }
                .sheet(item: $renaming) { RenameAddressView(model: model, item: $0) }
                .confirmationDialog("Stop watching this address?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Stop Watching", role: .destructive) {
                        model.remove(item)
                        dismiss()
                    }
                } message: {
                    Text("It's only removed from this phone. Your coins aren't affected.")
                }
            } else {
                ContentUnavailableView("Not on watch", systemImage: "eye.slash")
            }
        }
        // Runs again when the connection opens or a refresh brings new numbers.
        .task(id: reloadKey) { await loadIfNeeded() }
        .refreshable { await reload() }
    }

    /// Includes whether a load is running, so the page checks again when one ends.
    private var reloadKey: String {
        "\(model.isConnected) \(model.snapshot?.fetchedAt.timeIntervalSince1970 ?? 0) \(loading)"
    }

    private func loadIfNeeded() async {
        guard let item, !loading, model.historyFailures[address] == nil else { return }
        if let history, let snapshot = model.snapshot {
            // Loaded after the balances on screen, so it's the newest there is. Checking this first also
            // means a page that differs slightly from the balances can't keep reloading itself.
            if history.fetchedAt >= snapshot.fetchedAt { return }
            // A saved page that matches the latest balances needs no connection.
            if let row, HistoryCache.matches(history, row: row, tip: snapshot.tip) { return }
        }
        if !model.isConnected {
            if model.activity == .idle, model.failure == nil { model.refresh(retries: 6) }
            return
        }
        model.loadHistory(for: item)
    }

    private func reload() async {
        guard let item else { return }
        if model.isConnected {
            await model.loadHistory(for: item)?.value
        } else if model.activity == .idle {
            model.refresh(retries: 6)
        }
    }

    private func amount(_ sats: Int64, signed: Bool = false) -> String {
        model.hideAmounts ? "•••••• \(model.unit.label)" : BitcoinAmount.display(sats: sats, unit: model.unit, signed: signed)
    }

    // MARK: Summary

    private func summarySection(_ item: WatchedAddress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                if model.isDemo { DemoBadge(text: "Demo: sample data") }
                if let kind = (try? BitcoinAddress(item.address))?.kind {
                    Text(Self.kindName(kind))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Text(Self.grouped(item.address))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(item.address)
                    .accessibilityIdentifier("detail.address")

                VStack(alignment: .leading, spacing: 4) {
                    if let row {
                        Text(amount(row.balance.confirmedSats))
                            .font(.title.monospacedDigit().bold())
                            .foregroundStyle(model.balanceIsCurrent ? .primary : .secondary)
                            .accessibilityIdentifier("detail.balance")
                        if row.balance.unconfirmedSats != 0 {
                            Text("Pending \(amount(row.balance.unconfirmedSats, signed: true))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("detail.pending")
                        }
                        if !model.balanceIsCurrent {
                            Text("Last saved balance").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not checked yet").foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        stat("Transactions", row.map { String($0.history.transactionCount) }, id: "detail.count")
                        stat("Received", history?.receivedSats.map { amount($0) }, id: "detail.received")
                        stat("Sent", history?.sentSats.map { amount($0) }, id: "detail.sent")
                    }
                    GridRow {
                        stat("First seen", history?.firstSeen.map(Self.day), id: "detail.firstSeen")
                        stat("Last activity", history?.lastActivity.map(Self.day), id: "detail.lastActivity")
                        Color.clear.frame(height: 0)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func stat(_ title: String, _ value: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value ?? (history == nil && loading ? "…" : "–"))
                .font(.footnote.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: Chart

    private struct Point: Identifiable {
        let date: Date
        let sats: Int64
        var id: Date { date }
    }

    /// Balance after each transaction, oldest first, ending now. Only points that are known.
    private var points: [Point] {
        guard let history else { return [] }
        var result: [Point] = []
        let oldestFirst = history.transactions.reversed()
        if history.isComplete, let first = oldestFirst.first?.time {
            result.append(Point(date: first.addingTimeInterval(-1), sats: 0))
        }
        for item in oldestFirst {
            guard let balance = item.balanceAfterSats else { continue }
            let date = item.time ?? history.fetchedAt
            if let last = result.last, last.date >= date { result.removeLast() }
            result.append(Point(date: date, sats: balance))
        }
        if let last = result.last, last.date < history.fetchedAt {
            result.append(Point(date: history.fetchedAt, sats: last.sats))
        }
        return result
    }

    @ViewBuilder
    private var chartSection: some View {
        let points = points
        if points.count >= 2, !model.hideAmounts {
            Section {
                // Doubles are only used to place the line. Every amount shown as text is exact.
                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Balance", chartValue(point.sats)))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date), y: .value("Balance", chartValue(point.sats)))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(axisLabel(number)) }
                        }
                    }
                }
                .frame(height: 170)
                .padding(.vertical, 8)
                .accessibilityLabel("Balance over time")
                .accessibilityIdentifier("detail.chart")
            } header: {
                Text("Balance over time")
            }
        }
    }

    private func chartValue(_ sats: Int64) -> Double {
        model.unit == .btc ? Double(sats) / 100_000_000 : Double(sats)
    }

    private func axisLabel(_ value: Double) -> String {
        if model.unit == .btc { return value.formatted(.number.precision(.fractionLength(0...4))) }
        return value.formatted(.number.notation(.compactName))
    }

    // MARK: Activity

    private struct MonthGroup: Identifiable {
        let title: String
        let items: [AddressTransaction]
        var id: String { title }
    }

    private var groups: [MonthGroup] {
        guard let history else { return [] }
        var result: [MonthGroup] = []
        let pending = history.transactions.filter(\.isPending)
        if !pending.isEmpty { result.append(MonthGroup(title: "Pending", items: pending)) }
        for item in history.transactions where !item.isPending {
            let title = item.time.map { $0.formatted(.dateTime.month(.wide).year()) } ?? "Earlier"
            if result.last?.title == title, result.last?.title != "Pending" {
                let last = result.removeLast()
                result.append(MonthGroup(title: title, items: last.items + [item]))
            } else {
                result.append(MonthGroup(title: title, items: [item]))
            }
        }
        return result
    }

    @ViewBuilder
    private var activitySections: some View {
        if let history {
            let positions = Dictionary(uniqueKeysWithValues: history.transactions.enumerated().map { ($1.txid, $0) })
            if history.transactions.isEmpty {
                Section("Activity") { Text("No transactions yet.").foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        TransactionRow(
                            item: item,
                            tip: history.tipHeight,
                            index: positions[item.txid] ?? 0,
                            expanded: expanded.contains(item.txid),
                            amount: amount
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(item.txid) }
                        .accessibilityAction(named: "Details") { toggle(item.txid) }
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        if group.id == groups.first?.id, loading {
                            Spacer()
                            ProgressView().controlSize(.mini)
                        }
                    }
                } footer: {
                    if group.id == groups.last?.id { activityFooter(history) }
                }
            }
            if let failure = model.historyFailures[address] {
                Section { failureView(failure.message) }
            }
        } else {
            Section("Activity") { placeholder }
        }
    }

    private func activityFooter(_ history: AddressHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !history.isComplete {
                Text("Showing the latest \(history.transactions.count) of \(history.totalCount) transactions.")
                    .accessibilityIdentifier("detail.truncated")
            }
            Text("Loaded \(history.fetchedAt.formatted(date: .abbreviated, time: .shortened)). Worked out on this phone from your server's transactions, each checked against its ID. Saved behind Face ID.")
                .accessibilityIdentifier("detail.footer")
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let failure = model.historyFailures[address] {
            failureView(failure.message)
        } else if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading transactions").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("detail.loading")
        } else if model.isConnected {
            // Normally replaced by a load within a moment. Never a spinner with nothing behind it.
            Button("Load Transactions") { Task { await reload() } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detail.load")
        } else if model.activity != .idle {
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to your server").foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.failure?.message ?? "Not connected.").font(.footnote).foregroundStyle(.secondary)
                Button("Connect") { model.refresh(retries: 6) }.buttonStyle(.bordered)
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("detail.error")
            Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
        }
    }

    private func toggle(_ txid: TxID) {
        withAnimation(.snappy) {
            if expanded.contains(txid) { expanded.remove(txid) } else { expanded.insert(txid) }
        }
    }

    // MARK: Formatting

    static func kindName(_ kind: AddressKind) -> String {
        switch kind {
        case .p2pkh: "Legacy"
        case .p2sh: "Script"
        case .p2wpkh: "SegWit"
        case .p2wsh: "SegWit script"
        case .p2tr: "Taproot"
        }
    }

    /// Groups of four, which makes an address or ID easier to compare by eye.
    static func grouped(_ text: String) -> String {
        stride(from: 0, to: text.count, by: 4).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            return String(text[start..<(text.index(start, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex)])
        }.joined(separator: " ")
    }

    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct TransactionRow: View {
    let item: AddressTransaction
    let tip: Int
    let index: Int
    let expanded: Bool
    let amount: (Int64, Bool) -> String

    private enum Direction { case incoming, outgoing, moved, unknown }

    private var direction: Direction {
        guard let net = item.netSats else { return .unknown }
        return net > 0 ? .incoming : (net < 0 ? .outgoing : .moved)
    }

    private var title: String {
        switch (direction, item.isPending) {
        case (.incoming, false): "Received"
        case (.incoming, true): "Receiving"
        case (.outgoing, false): "Sent"
        case (.outgoing, true): "Sending"
        case (.moved, _): "No change"
        case (.unknown, _): "Transaction"
        }
    }

    private var symbol: String {
        switch direction {
        case .incoming: "arrow.down.left"
        case .outgoing: "arrow.up.right"
        case .moved: "arrow.left.arrow.right"
        case .unknown: "questionmark"
        }
    }

    private var color: Color {
        switch direction {
        case .incoming: .green
        case .outgoing: .orange
        case .moved, .unknown: .secondary
        }
    }

    private var subtitle: String {
        guard let time = item.time else { return item.isPending ? "Waiting for a block" : "Block \(item.height)" }
        let confirmations = item.confirmations(tip: tip)
        let when = time.formatted(date: .abbreviated, time: .shortened)
        // Recent ones say how settled they are. Past six, the date is what matters.
        return confirmations < 6 ? "\(when), \(confirmations) of 6 confirmations" : when
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.15))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: 34, height: 34)
                .overlay {
                    if item.isPending {
                        Circle().strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // Amounts stay on one line, shrinking a little if they must. The title and date wrap instead.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.netSats.map { amount($0, true) } ?? "Amount unknown")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(direction == .incoming ? Color.green : Color.primary)
                        .accessibilityIdentifier("detail.tx.\(index).amount")
                    if let balance = item.balanceAfterSats {
                        Text(amount(balance, false))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Balance after, \(amount(balance, false))")
                            .accessibilityIdentifier("detail.tx.\(index).balance")
                    }
                }
                .layoutPriority(1)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !item.isPending {
                        LabeledContent("Block", value: item.height.formatted())
                        LabeledContent("Confirmations", value: item.confirmations(tip: tip).formatted())
                    }
                    Text("Transaction ID").font(.caption).foregroundStyle(.secondary)
                    Text(AddressDetailView.grouped(item.txid.hex))
                        .font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(item.txid.hex)
                        .accessibilityIdentifier("detail.tx.\(index).id")
                }
                .font(.footnote)
                .padding(.leading, 46)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}
