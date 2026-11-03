import SwiftUI
import WatchCore

/// Sheets present above the root view, so each one needs its own cover.
struct PrivacyCovered: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            // Also what iOS captures for the app switcher.
            if scenePhase != .active { PrivacyCover() }
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Emblem()
                Text(Theme.lockedLine).font(.headline).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("privacy.cover")
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        if let vault = model.vault {
            if vault.onion == nil, !model.isDemo {
                PairingView(model: model, vault: vault)
            } else {
                HomeView(model: model, vault: vault)
            }
        } else if model.vaultExists {
            LockedView(model: model)
        } else {
            WelcomeView(model: model)
        }
    }
}

private struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Emblem()
            Text("electrs-watch").font(.largeTitle.bold())
            Text(Theme.tagline).font(.headline).italic().foregroundStyle(.secondary)
            Text("See the balance of addresses you choose, from your own server, over Tor. This app holds no wallet keys and can't spend.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let message = model.unlockFailure {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center).accessibilityIdentifier("setup.error")
            }
            Spacer()
            Button("Get Started") { Task { await model.beginSetup() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("setup.start")
            Button("Try a Demo") { model.startDemo() }
                .controlSize(.large)
                .accessibilityIdentifier("setup.demo")
            Text("The demo shows sample data, with no server and no connection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

private struct LockedView: View {
    let model: AppModel
    @State private var confirmErase = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Emblem()
            Text(Theme.lockedLine).font(.headline).italic().foregroundStyle(.secondary)
            if let message = model.unlockFailure {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center).accessibilityIdentifier("lock.error")
            }
            if model.offerErase {
                Button("Erase and Start Over", role: .destructive) { confirmErase = true }
            }
            Spacer()
            Button("Unlock with Face ID") { Task { await model.unlock() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("lock.unlock")
        }
        .padding(24)
        .confirmationDialog("Erase everything on this phone?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { model.eraseEverything() }
        } message: {
            Text("You'll need to add a new key to your node. Your coins aren't affected.")
        }
    }
}

private struct PairingView: View {
    let model: AppModel
    let vault: VaultContents
    @State private var onionText = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(vault.clientKey.authorizedClientLine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("pair.publicKey")
                    ShareLink(item: vault.clientKey.authorizedClientLine) {
                        Label("Send to Mac", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("1. Add this public key to your node")
                } footer: {
                    Text("This is public, so it's safe to send. The private half stays on this phone. Follow docs/NODE-SETUP.md.")
                }
                Section {
                    TextField("your-address.onion", text: $onionText, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pair.onion")
                    if invalid {
                        Text("That isn't a v3 onion address.").foregroundStyle(.red).accessibilityIdentifier("pair.invalid")
                    }
                    Button("Continue") { invalid = !model.setOnion(onionText) }
                        .disabled(onionText.isEmpty)
                        .accessibilityIdentifier("pair.continue")
                } header: {
                    Text("2. Enter your server's onion address")
                }
            }
            .navigationTitle("Connect")
        }
    }
}

private struct HomeView: View {
    let model: AppModel
    let vault: VaultContents
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                totalSection
                addressesSection
            }
            .privacySensitive()
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("home.settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.hideAmounts.toggle() } label: {
                        Image(systemName: model.hideAmounts ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(model.hideAmounts ? "Show amounts" : "Hide amounts")
                    .accessibilityIdentifier("home.hide")
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add address")
                        .accessibilityIdentifier("home.add")
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
            .sheet(isPresented: $showAdd) { AddAddressView(model: model) }
            .sheet(isPresented: $showSettings) { SettingsView(model: model, vault: vault) }
            .navigationDestination(for: String.self) { AddressDetailView(model: model, address: $0) }
        }
    }

    private func amount(_ sats: Int64, signed: Bool = false) -> String {
        model.hideAmounts ? "•••••• \(model.unit.label)" : BitcoinAmount.display(sats: sats, unit: model.unit, signed: signed)
    }

    private func checkedText(_ date: Date) -> String {
        // An older saved balance needs its date, or it could pass for today's.
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Says when the numbers on screen might be out of date, and why.
    private var staleText: String? {
        if model.balanceIsCurrent { return nil }
        if model.activity != .idle { return "Updating. Showing your last saved balance." }
        if model.failure != nil { return "Couldn't update. Showing your last saved balance." }
        return "Showing your last saved balance."
    }

    private var totalSection: some View {
        Section {
            if model.isDemo { DemoBadge(text: "Demo: sample data, not a real wallet") }
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 4) {
                    if let staleText {
                        HStack(spacing: 8) {
                            if model.activity != .idle { ProgressView().controlSize(.small) }
                            Text(staleText)
                                .font(.footnote.bold())
                                .foregroundStyle(model.failure == nil ? Color.secondary : Color.orange)
                                .accessibilityIdentifier("home.stale")
                        }
                    }
                    Text(amount(snapshot.totalConfirmedSats))
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(model.balanceIsCurrent ? .primary : .secondary)
                        .accessibilityIdentifier("home.total")
                    if snapshot.totalUnconfirmedSats != 0 {
                        Text("Pending \(amount(snapshot.totalUnconfirmedSats, signed: true))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("home.pending")
                    }
                    Text("Block \(String(snapshot.tip.height)), checked \(checkedText(snapshot.fetchedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.tip")
                }
            } else {
                Text("Not checked yet").foregroundStyle(.secondary)
            }
        } footer: {
            Text("This only covers the addresses below, so it isn't your wallet total. Change from a spend usually goes to a new address: add it here.")
        }
    }

    private var addressesSection: some View {
        Section {
            ForEach(vault.watched) { item in
                let row = model.snapshot?.rows.first { $0.id == item.id }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label.isEmpty ? "Address" : item.label).font(.headline)
                        Text(item.address).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        if let row {
                            Text("\(amount(row.balance.confirmedSats)), \(row.history.transactionCount) tx")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(model.balanceIsCurrent ? .primary : .secondary)
                                .accessibilityIdentifier("row.\(item.label)")
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                // Not a NavigationLink, which would merge the row's text into one accessibility element.
                .contentShape(Rectangle())
                .onTapGesture { path.append(item.address) }
                .accessibilityAction(named: "Open") { path.append(item.address) }
            }
            .onDelete { offsets in
                offsets.map { vault.watched[$0] }.forEach(model.remove)
            }
            if vault.watched.isEmpty {
                Text("Nothing on watch yet. Tap + to add an address.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Addresses")
        } footer: {
            if !vault.watched.isEmpty {
                Text("Tap an address for its activity and to rename it. Swipe left to remove it.")
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if model.isDemo {
            VStack(spacing: 8) {
                Text("This is a demo with made-up balances. Nothing connects anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Exit Demo") { model.exitDemo() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("demo.exit")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        } else {
            liveStatusBar
        }
    }

    private var liveStatusBar: some View {
        VStack(spacing: 8) {
            if let failure = model.failure {
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("home.error")
            }
            if model.activity == .idle {
                HStack(spacing: 12) {
                    Button(model.failure == nil ? "Refresh" : "Retry") { model.refresh() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("home.refresh")
                    hardRefreshButton
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activityText).font(.footnote).accessibilityIdentifier("home.activity")
                }
                if let startedAt = model.refreshStartedAt {
                    // Ticks every second, so it's clear the app is still working and when it started over.
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(progressDetail(since: startedAt, now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("home.progress")
                    }
                }
                hardRefreshButton
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Always available, so a stuck connection never has to wait out its retries.
    private var hardRefreshButton: some View {
        Button("Hard Refresh") { model.hardRefresh() }
            .buttonStyle(.bordered)
            .sensoryFeedback(.impact, trigger: model.hardRefreshTaps)
            .accessibilityIdentifier("home.hardRefresh")
    }

    private var activityText: String {
        let text = switch model.activity {
        case .idle: ""
        case .startingTor(let percent): "Starting Tor, \(percent)%"
        case .resetting: "Resetting Tor"
        case .connecting: "Connecting to your server"
        case .waitingToRetry: "Didn't connect, trying again shortly"
        case .refreshing: "Checking addresses"
        }
        return model.isHardRefresh ? "Hard refresh: \(text)" : text
    }

    private func progressDetail(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "Attempt \(model.attempt), \(elapsed) elapsed"
    }
}

private struct AddAddressView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var label = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("bc1...", text: $text, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("add.address")
                    TextField("Label (optional)", text: $label)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("add.label")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red).accessibilityIdentifier("add.problem")
                    } else {
                        Text("Enter a single address. Don't enter an xpub or a seed phrase.")
                    }
                }
            }
            .navigationTitle("Add Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(text.isEmpty).accessibilityIdentifier("add.save")
                }
            }
        }
        .modifier(PrivacyCovered())
    }

    private func save() {
        do {
            let address = try BitcoinAddress(text)
            if model.add(address: address, label: label) {
                dismiss()
            } else {
                problem = "Couldn't save this address."
            }
        } catch AddressError.notMainnet {
            problem = "That's a testnet address. This app only supports mainnet."
        } catch AddressError.unsupportedWitnessVersion {
            problem = "This address type isn't supported yet."
        } catch {
            problem = "That isn't a valid Bitcoin address."
        }
    }
}

struct RenameAddressView: View {
    let model: AppModel
    let item: WatchedAddress
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var failed = false

    init(model: AppModel, item: WatchedAddress) {
        self.model = model
        self.item = item
        _label = State(initialValue: item.label)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.address).font(.footnote.monospaced())
                    TextField("Label (optional)", text: $label)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("rename.label")
                } footer: {
                    if failed {
                        Text("Couldn't save this label.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.rename(item, to: label) {
                            dismiss()
                        } else {
                            failed = true
                        }
                    }
                    .accessibilityIdentifier("rename.save")
                }
            }
        }
        .modifier(PrivacyCovered())
    }
}

private struct SettingsView: View {
    let model: AppModel
    let vault: VaultContents
    @Environment(\.dismiss) private var dismiss
    @State private var confirmErase = false
    @State private var newOnion = ""
    @State private var onionInvalid = false
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.dark

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.appearance")
                }
                Section("Show amounts in") {
                    Picker("Show amounts in", selection: Binding(get: { model.unit }, set: { model.setUnit($0) })) {
                        ForEach(AmountUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.unit")
                }
                if !model.isDemo {
                    Section("Server") {
                        Text(vault.onion?.hostname ?? "").font(.footnote.monospaced())
                        TextField("New onion address", text: $newOnion, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if onionInvalid {
                            Text("That isn't a v3 onion address.").foregroundStyle(.red)
                        }
                        Button("Change Address") {
                            onionInvalid = !model.setOnion(newOnion)
                            if !onionInvalid { newOnion = "" }
                        }
                        .disabled(newOnion.isEmpty)
                    }
                    Section("This phone's public key") {
                        Text(vault.clientKey.authorizedClientLine).font(.footnote.monospaced()).textSelection(.enabled)
                        ShareLink(item: vault.clientKey.authorizedClientLine) {
                            Label("Send to Mac", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Section {
                    let outcomes = ConnectionLog.Outcome.allCases.filter { vault.connectionLog.count(of: $0) > 0 }
                    ForEach(outcomes, id: \.self) { outcome in
                        LabeledContent(outcome.label, value: String(vault.connectionLog.count(of: outcome)))
                            .accessibilityIdentifier("settings.log.\(outcome.rawValue)")
                    }
                    if outcomes.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connection history")
                } footer: {
                    Text("Counts only, with no addresses or times. Stays on this phone.")
                }
                Section {
                    NavigationLink("Open Source Licenses") { AcknowledgementsView() }
                        .accessibilityIdentifier("settings.licenses")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } header: {
                    Text("About")
                } footer: {
                    Text("electrs-watch is open source under the MIT license.")
                }
                Section {
                    Button("Lock Now") { dismiss(); model.lock() }
                    if !model.isDemo {
                        Button("Erase Everything", role: .destructive) { confirmErase = true }
                    }
                } footer: {
                    Text("Erasing removes the key and your addresses from this phone. Your coins aren't affected. Also remove this phone's file from the node.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Erase everything on this phone?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { dismiss(); model.eraseEverything() }
            }
        }
        .modifier(PrivacyCovered())
    }
}

/// Credits for the open source software inside the app, as their licenses require.
private struct AcknowledgementsView: View {
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("licenses.text")
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Marks sample data on every screen of the demo.
struct DemoBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "theatermasks")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityIdentifier("demo.badge")
    }
}
