import AgentBarCore
import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class AppModel {
    var sessions: [AgentSession] = []
    var hostStates: [HostID: HostConnectionState] = [.local: HostConnectionState(host: .local, isOnline: true)]
    var remoteHomes: [HostID: String] = [:]
    var probingHostIDs: Set<HostID> = []
    var balanceReadings: [BalanceReading] = []
    var subscriptionCards: [SubscriptionCardItem] = []
    var isRefreshingBalances: Bool = false
    var lastBalanceRefreshAt: Date?
    private var antigravityPlan: String?
    private var antigravityQuotas: [QuotaWindowReading] = []
    private var lastAntigravityPlanAttemptAt: Date?

    var isShowingOverview: Bool = false {
        didSet {
            if isShowingOverview {
                refreshBalancesIfStale(maxAge: min(60, dashboardRefreshIntervalSeconds))
            }
        }
    }
    var selectedSettingsTab: Int = 0
    var selectedCategory: StatusCategoryFilter? = nil {
        didSet {
            if isShowingOverview {
                isShowingOverview = false
            }
        }
    }
    var selectedHostFilter: HostID? = nil
    var searchQuery: String = ""
    var isSearchVisible: Bool = false
    var expandedSessionIDs: Set<String> = []
    var collapsedGroupIDs: Set<String> = []
    var seenSessionIDs: Set<String> = []
    var pinnedGroupIDs: Set<String> = []
    var customHostOrder: [String] = []

    var projectSortOrder: ProjectSortOrder = .priorityAndRecent {
        didSet { UserDefaults.standard.set(projectSortOrder.rawValue, forKey: "projectSortOrder") }
    }

    var hostSortOrder: HostSortOrder = .localFirst {
        didSet { UserDefaults.standard.set(hostSortOrder.rawValue, forKey: "hostSortOrder") }
    }

    var menuBarStyle: MenuBarIconStyle = .multiDot {
        didSet {
            UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
            notifyStatusBar()
        }
    }

    var demoModeEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(demoModeEnabled, forKey: "demoModeEnabled")
            Task { await refreshAll(includeBalances: true) }
        }
    }

    var lookbackHours: Double = 72 {
        didSet { UserDefaults.standard.set(lookbackHours, forKey: "lookbackHours") }
    }

    var includeSubagents: Bool = false {
        didSet { UserDefaults.standard.set(includeSubagents, forKey: "includeSubagents") }
    }

    var notificationsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    var dashboardRefreshIntervalSeconds: Double = 180 {
        didSet {
            UserDefaults.standard.set(dashboardRefreshIntervalSeconds, forKey: "dashboardRefreshIntervalSeconds")
            restartBalancePolling()
        }
    }

    var sshHosts: [SSHHostConfig] = [] {
        didSet { saveCodable(sshHosts, key: "sshHosts") }
    }

    var balanceSources: [BalanceSourceConfig] = [] {
        didSet {
            saveCodable(balanceSources, key: "balanceSources")
            let validIDs = Set(balanceSources.filter(\.isEnabled).map(\.id))
            balanceReadings.removeAll { !validIDs.contains($0.sourceID) }
        }
    }

    var isRefreshing: Bool = false
    var confirmingHighRiskSession: AgentSession?
    var denyingSession: AgentSession?
    var denyReasonDraft: String = ""
    var standaloneMarkdownSession: AgentSession?
    var newSSHAliasDraft: String = ""
    var hookInstallMessage: String?
    var quickBannerToast: String?
    var balanceTestMessage: [UUID: String] = [:]
    var tokenInputs: [UUID: String] = [:]

    var measuredTopChromeHeight: CGFloat = 112
    var measuredScrollContentHeight: CGFloat = 320
    var measuredFooterHeight: CGFloat = 38

    var onStatusBarNeedsUpdate: (() -> Void)?
    var onPreferredHeightChanged: (() -> Void)?

    var preferredPanelHeight: CGFloat {
        let total = ceil(measuredTopChromeHeight + measuredScrollContentHeight + measuredFooterHeight + 4)
        return max(200, total)
    }

    private var notifiedApprovalIDs: Set<String> = []
    private var localPollTask: Task<Void, Never>?
    private var sshPollTask: Task<Void, Never>?
    private var balancePollTask: Task<Void, Never>?
    private var lastSSHProbeAt: Date?

    init() {
        loadPersistedPreferences()
        discoverAndMergeSSHHosts()
        setupNotificationsIfAvailable()
        startBackgroundPolling()
    }

    init(showcaseOverview: Bool) {
        let demo = DemoData.makeShowcase()
        self.sessions = demo.sessions
        self.hostStates = demo.hostStates
        self.remoteHomes = [.local: "/Users/dev", .ssh(alias: "gpu-dev-01"): "/data", .ssh(alias: "build-mac"): "/Users/builder"]
        self.sshHosts = [
            SSHHostConfig(alias: "gpu-dev-01", hostname: "10.24.8.15", user: "ubuntu", isEnabled: true),
            SSHHostConfig(alias: "build-mac", hostname: "10.24.9.42", user: "builder", isEnabled: true)
        ]
        self.balanceReadings = Array(demo.balances.prefix(2))
        self.subscriptionCards = demo.subscriptions
        self.expandedSessionIDs = ["demo:claude:acmecore"]
        self.isShowingOverview = showcaseOverview
    }

    var menuBarCounts: MenuBarCounts {
        SessionGroupingBuilder.computeMenuBarCounts(sessions: sessions)
    }

    var totalAnalytics: TotalAnalyticsSnapshot {
        SubscriptionAndStatsService.buildAnalytics(
            sessions: sessions,
            demoMode: demoModeEnabled,
            homeByHost: remoteHomes
        )
    }

    var filteredHostGroups: [HostSessionGroup] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sessions.filter { session in
            if session.kind.isChatOnly {
                return false
            }
            if let hostFilter = selectedHostFilter, session.host != hostFilter {
                return false
            }
            if let category = selectedCategory, !category.matches(session) {
                return false
            }
            guard !query.isEmpty else { return true }
            return session.title.lowercased().contains(query)
                || session.overview.lowercased().contains(query)
                || (session.cwd?.lowercased().contains(query) ?? false)
                || session.kind.displayName.lowercased().contains(query)
                || (session.model?.lowercased().contains(query) ?? false)
        }

        let activeStates: [HostID: HostConnectionState]
        if let hostFilter = selectedHostFilter {
            activeStates = [hostFilter: hostStates[hostFilter] ?? HostConnectionState(host: hostFilter, isOnline: true)]
        } else if selectedCategory == nil && query.isEmpty {
            activeStates = hostStates
        } else {
            var subset: [HostID: HostConnectionState] = [:]
            for s in filtered {
                subset[s.host] = hostStates[s.host] ?? HostConnectionState(host: s.host, isOnline: true)
            }
            activeStates = subset
        }
        return SessionGroupingBuilder.buildHostGroups(
            sessions: filtered,
            hostStates: activeStates,
            homeByHost: remoteHomes,
            hostSort: hostSortOrder,
            projectSort: projectSortOrder,
            pinnedGroupIDs: pinnedGroupIDs,
            customHostOrder: customHostOrder
        )
    }

    var allHostSummaries: [(host: HostID, connection: HostConnectionState, sessionCount: Int)] {
        let realSessions = sessions.filter { !$0.kind.isChatOnly }
        let groups = SessionGroupingBuilder.buildHostGroups(
            sessions: realSessions,
            hostStates: hostStates,
            homeByHost: remoteHomes,
            hostSort: hostSortOrder,
            projectSort: projectSortOrder,
            pinnedGroupIDs: pinnedGroupIDs,
            customHostOrder: customHostOrder
        )
        return groups.map { ($0.host, $0.connection, $0.totalSessionCount) }
    }

    var todaySummaryText: String {
        let dayCutoff = Calendar.current.startOfDay(for: Date())
        let recent = sessions.filter { $0.lastActivityAt >= dayCutoff || demoModeEnabled }
        var totalTok = 0
        var totalPrompt = 0
        var totalCacheRead = 0
        var totalCost = 0.0
        for s in recent {
            totalTok += s.usage.totalTokens
            totalPrompt += s.usage.totalPromptTokens
            totalCacheRead += s.usage.cacheRead
            if let cost = PricingCatalog.estimatedCostUSD(usage: s.usage, model: s.model) {
                totalCost += cost
            }
        }
        let tokStr = FormattingHelpers.compactTokens(totalTok)
        let hitStr = totalPrompt > 0
            ? String(format: "%.0f%%", (Double(totalCacheRead) / Double(totalPrompt)) * 100.0)
            : "—"
        let costStr = String(format: "$%.2f", totalCost)
        return "今日 \(tokStr) tokens · 缓存命中 \(hitStr) · 预估 \(costStr)"
    }

    func toggleSessionExpanded(_ session: AgentSession) {
        if expandedSessionIDs.contains(session.id) {
            expandedSessionIDs.remove(session.id)
        } else {
            expandedSessionIDs.insert(session.id)
            markSessionSeen(session.id)
        }
    }

    func markSessionSeen(_ sessionID: String) {
        seenSessionIDs.insert(sessionID)
        saveCodable(Array(seenSessionIDs), key: "seenSessionIDs")
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].isSeen = true
        }
        notifyStatusBar()
    }

    func markAllCompletedSeen() {
        for idx in sessions.indices where sessions[idx].status == .completed || sessions[idx].status == .failed {
            sessions[idx].isSeen = true
            seenSessionIDs.insert(sessions[idx].id)
        }
        saveCodable(Array(seenSessionIDs), key: "seenSessionIDs")
        notifyStatusBar()
    }

    func isGroupCollapsed(_ id: String, defaultOffline: Bool = false) -> Bool {
        if collapsedGroupIDs.contains(id) { return true }
        if defaultOffline && !collapsedGroupIDs.contains("expanded:\(id)") {
            return true
        }
        return false
    }

    func toggleGroupCollapsed(_ id: String, isOfflineHost: Bool = false) {
        if isOfflineHost {
            let overrideKey = "expanded:\(id)"
            if collapsedGroupIDs.contains(overrideKey) {
                collapsedGroupIDs.remove(overrideKey)
            } else {
                collapsedGroupIDs.insert(overrideKey)
            }
        } else {
            if collapsedGroupIDs.contains(id) {
                collapsedGroupIDs.remove(id)
            } else {
                collapsedGroupIDs.insert(id)
            }
        }
        saveCodable(Array(collapsedGroupIDs), key: "collapsedGroupIDs")
    }

    func isGroupPinned(_ id: String) -> Bool {
        pinnedGroupIDs.contains(id)
    }

    func toggleGroupPinned(_ id: String) {
        if pinnedGroupIDs.contains(id) {
            pinnedGroupIDs.remove(id)
        } else {
            pinnedGroupIDs.insert(id)
        }
        saveCodable(Array(pinnedGroupIDs), key: "pinnedGroupIDs")
    }

    func toggleStatusCategory(_ category: StatusCategoryFilter) {
        if selectedCategory == category {
            selectedCategory = nil
        } else {
            selectedCategory = category
        }
    }

    func toggleHostFilter(_ host: HostID) {
        if selectedHostFilter == host {
            selectedHostFilter = nil
        } else {
            selectedHostFilter = host
        }
    }

    var isHookInstalled: Bool {
        HookApprovalManager.isClaudeHooksInstalled()
    }

    func enableOneClickApprovalHooks() {
        let hookPath = HookApprovalManager.hookBinaryPath()
        do {
            let saved = try HookApprovalManager.installClaudeHooks(hookExecutablePath: hookPath)
            hookInstallMessage = "✓ 已安装至 \(saved)"
            showQuickToast("✓ 已开启 Claude 一键审批 Hook")
        } catch {
            showQuickToast("Hook 安装失败：\(error.localizedDescription)")
        }
    }

    func approveAllPending() {
        let pendingSessions = sessions.filter { $0.status == .awaitingApproval }
        guard !pendingSessions.isEmpty else {
            if !isHookInstalled {
                enableOneClickApprovalHooks()
            }
            return
        }

        if let risky = pendingSessions.first(where: { $0.pendingApproval?.highRiskMatchedRule != nil }) {
            confirmingHighRiskSession = risky
            return
        }

        var approvedHookCount = 0
        var firstTerminalOnly: AgentSession?
        for session in pendingSessions {
            if let approval = session.pendingApproval, approval.canRespondViaHook {
                performApprovalDecision(session: session, approval: approval, action: .allow, reason: nil)
                approvedHookCount += 1
            } else if firstTerminalOnly == nil {
                firstTerminalOnly = session
            }
        }

        if approvedHookCount > 0 {
            showQuickToast("✓ 已一键批准 \(approvedHookCount) 个请求")
        }
        if let termSession = firstTerminalOnly {
            JumpService.jump(to: termSession)
        }
    }

    private func showQuickToast(_ text: String) {
        quickBannerToast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            if self?.quickBannerToast == text {
                self?.quickBannerToast = nil
            }
        }
    }

    func clearAllPinnedGroups() {
        pinnedGroupIDs.removeAll()
        saveCodable(Array(pinnedGroupIDs), key: "pinnedGroupIDs")
    }

    func moveHost(_ hostGroupID: String, direction: Int) {
        var currentIDs = filteredHostGroups.map(\.id)
        for existing in customHostOrder where !currentIDs.contains(existing) {
            currentIDs.append(existing)
        }
        guard let idx = currentIDs.firstIndex(of: hostGroupID) else { return }
        let targetIdx = idx + direction
        guard currentIDs.indices.contains(targetIdx) else { return }
        currentIDs.swapAt(idx, targetIdx)
        customHostOrder = currentIDs
        hostSortOrder = .customOrder
        saveCodable(customHostOrder, key: "customHostOrder")
    }

    func moveSSHConfig(at index: Int, direction: Int) {
        let target = index + direction
        guard sshHosts.indices.contains(index), sshHosts.indices.contains(target) else { return }
        sshHosts.swapAt(index, target)
        var order = [HostID.local.storageKey] + sshHosts.map { HostID.ssh(alias: $0.alias).storageKey }
        for existing in customHostOrder where !order.contains(existing) {
            order.append(existing)
        }
        customHostOrder = order
        saveCodable(customHostOrder, key: "customHostOrder")
    }

    func expandAllGroups() {
        collapsedGroupIDs.removeAll()
        saveCodable(Array(collapsedGroupIDs), key: "collapsedGroupIDs")
    }

    func collapseAllDirectories() {
        for hg in filteredHostGroups {
            for dg in hg.directories {
                collapsedGroupIDs.insert(dg.id)
            }
        }
        saveCodable(Array(collapsedGroupIDs), key: "collapsedGroupIDs")
    }

    func requestApprove(_ session: AgentSession, bypassHighRiskCheck: Bool = false) {
        guard let approval = session.pendingApproval else {
            JumpService.jump(to: session)
            return
        }
        if !bypassHighRiskCheck, approval.highRiskMatchedRule != nil {
            confirmingHighRiskSession = session
            return
        }
        confirmingHighRiskSession = nil
        performApprovalDecision(session: session, approval: approval, action: .allow, reason: nil)
    }

    func requestDeny(_ session: AgentSession, reason: String? = nil) {
        guard let approval = session.pendingApproval else { return }
        denyingSession = nil
        performApprovalDecision(session: session, approval: approval, action: .deny, reason: reason)
    }

    func requestHandleInTerminal(_ session: AgentSession) {
        if let approval = session.pendingApproval {
            performApprovalDecision(session: session, approval: approval, action: .passthrough, reason: nil)
        }
        JumpService.jump(to: session)
    }

    private func performApprovalDecision(
        session: AgentSession,
        approval: PendingApproval,
        action: ApprovalDecisionAction,
        reason: String?
    ) {
        if demoModeEnabled {
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].pendingApproval = nil
                switch action {
                case .allow:
                    sessions[idx].status = .runningTool
                    sessions[idx].overview = "已批准执行：\(approval.commandOrSummary)"
                case .deny:
                    sessions[idx].status = .waitingForInput
                    sessions[idx].overview = "已拒绝执行：\(reason ?? approval.commandOrSummary)"
                case .passthrough:
                    sessions[idx].status = .runningTool
                    sessions[idx].overview = "已交回终端处理"
                }
            }
            notifyStatusBar()
            return
        }

        Task {
            try? await HookApprovalManager.submitDecision(for: approval, action: action, reason: reason)
            await refreshLocalSessions()
        }
    }

    func refreshAll(includeBalances: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }

        if demoModeEnabled {
            let demo = DemoData.makeShowcase()
            self.sessions = demo.sessions
            self.hostStates = demo.hostStates
            self.balanceReadings = demo.balances
            self.subscriptionCards = demo.subscriptions
            if expandedSessionIDs.isEmpty {
                expandedSessionIDs = ["demo:claude:acmecore", "demo:codex:acmecore-test"]
            }
            notifyStatusBar()
            return
        }

        await refreshLocalSessions()
        await refreshSSHHosts()
        if includeBalances {
            await refreshBalances()
        }
    }

    func refreshOnPanelOpen() async {
        guard !demoModeEnabled else { return }
        refreshBalancesIfStale(maxAge: min(60, dashboardRefreshIntervalSeconds))
        await refreshLocalSessions()
        let needsSSH = lastSSHProbeAt == nil || Date().timeIntervalSince(lastSSHProbeAt!) > 12
        if needsSSH {
            await refreshSSHHosts()
        }
    }

    func refreshBalancesIfStale(maxAge: TimeInterval) {
        guard !demoModeEnabled, !isRefreshingBalances else { return }
        let hasBalanceSource = balanceSources.contains(where: \.isEnabled)
        guard hasBalanceSource || AntigravityUsageService.executable != nil else { return }
        let isStale = lastBalanceRefreshAt.map { Date().timeIntervalSince($0) >= maxAge } ?? true
        if isStale || (hasBalanceSource && balanceReadings.isEmpty) {
            Task { await refreshBalances(silent: true) }
        }
    }

    func refreshLocalSessions() async {
        guard !demoModeEnabled else { return }
        let lookback = lookbackHours
        let subagents = includeSubagents
        let seen = seenSessionIDs

        async let claudeList = ClaudeCodeAdapter.loadLocalSessions(
            lookbackHours: lookback,
            includeSubagents: subagents,
            seenSessionIDs: seen
        )
        async let codexList = CodexAdapter.loadLocalSessions(lookbackHours: lookback, includeSubagents: subagents, seenSessionIDs: seen)
        async let dshList = DeepSeekHarnessAdapter.loadLocalSessions(lookbackHours: lookback, seenSessionIDs: seen)
        async let cursorList = CursorTraeAdapter.loadLocalSessions(lookbackHours: lookback, seenSessionIDs: seen)
        async let antigravityList = AntigravityAdapter.loadLocalSessions(lookbackHours: lookback, seenSessionIDs: seen)

        let antigravity = await antigravityList
        var local = await (claudeList + codexList + dshList + cursorList) + antigravity
        let procs = await Task.detached(priority: .utility) {
            ProcessAndChatScanner.scanLocalAgentProcesses()
        }.value
        ProcessAndChatScanner.attachProcesses(to: &local, processes: procs)
        if antigravity.isEmpty, let appSession = AntigravityAdapter.runningDesktopSession(processes: procs) {
            local.append(appSession)
        }

        let pendingApprovals = HookApprovalManager.loadLocalPendingApprovals()
        mergePendingApprovals(pendingApprovals, into: &local, host: .local)

        let remoteExisting = sessions.filter { !$0.host.isLocal }
        self.sessions = local + remoteExisting
        self.hostStates[.local] = HostConnectionState(host: .local, isOnline: true)
        updateSubscriptionCards()
        notifyStatusBar()
    }

    private func updateSubscriptionCards() {
        subscriptionCards = SubscriptionAndStatsService.detectLocalSubscriptions(
            sessions: sessions, antigravityPlan: antigravityPlan, antigravityQuotas: antigravityQuotas
        )
    }

    func refreshSSHHosts() async {
        guard !demoModeEnabled else { return }
        let enabledHosts = sshHosts.filter(\.isEnabled)
        let enabledSet = Set(enabledHosts.map { HostID.ssh(alias: $0.alias) })

        // Prune disabled SSH sessions
        sessions.removeAll { !$0.host.isLocal && !enabledSet.contains($0.host) }
        for key in Array(hostStates.keys) where !key.isLocal && !enabledSet.contains(key) {
            hostStates.removeValue(forKey: key)
        }

        guard !enabledHosts.isEmpty else {
            notifyStatusBar()
            return
        }

        for cfg in enabledHosts {
            let hid = HostID.ssh(alias: cfg.alias)
            probingHostIDs.insert(hid)
            if hostStates[hid] == nil {
                hostStates[hid] = HostConnectionState(host: hid, isOnline: true)
            }
        }

        let seen = seenSessionIDs
        let remoteLookback = max(lookbackHours, 168)

        await withTaskGroup(of: (SSHHostConfig, SSHProbeResult).self) { group in
            for cfg in enabledHosts {
                group.addTask {
                    let res = await SSHProbeService.probeHost(
                        alias: cfg.alias,
                        lookbackHours: remoteLookback,
                        seenSessionIDs: seen
                    )
                    return (cfg, res)
                }
            }
            for await (cfg, res) in group {
                let hostID = HostID.ssh(alias: cfg.alias)
                probingHostIDs.remove(hostID)
                hostStates[hostID] = res.connection
                if let rHome = res.remoteHome {
                    remoteHomes[hostID] = rHome
                }
                if res.connection.isOnline {
                    var remoteList = res.sessions
                    if cfg.approvalEnabled {
                        mergePendingApprovals(res.pendingApprovals, into: &remoteList, host: hostID)
                    }
                    sessions.removeAll { $0.host == hostID }
                    sessions.append(contentsOf: remoteList)
                }
                notifyStatusBar()
            }
        }
        lastSSHProbeAt = Date()
        notifyStatusBar()
    }

    func toggleSSHHostEnabled(_ alias: String) {
        guard let idx = sshHosts.firstIndex(where: { $0.alias == alias }) else { return }
        sshHosts[idx].isEnabled.toggle()
        Task { await refreshSSHHosts() }
    }

    func connectAndUnlockSSHHost(_ alias: String) {
        JumpService.openSSHInTerminal(alias: alias)
        Task { @MainActor [weak self] in
            for delaySec in [4, 6, 8] {
                try? await Task.sleep(for: .seconds(delaySec))
                guard let self, !self.demoModeEnabled else { return }
                await self.probeSingleSSHHost(alias: alias)
            }
        }
    }

    func probeSingleSSHHost(alias: String) async {
        guard !demoModeEnabled,
              let cfg = sshHosts.first(where: { $0.alias == alias && $0.isEnabled }) else {
            return
        }
        let hostID = HostID.ssh(alias: alias)
        probingHostIDs.insert(hostID)
        let res = await SSHProbeService.probeHost(
            alias: alias,
            lookbackHours: max(lookbackHours, 168),
            seenSessionIDs: seenSessionIDs
        )
        probingHostIDs.remove(hostID)
        hostStates[hostID] = res.connection
        if let rHome = res.remoteHome {
            remoteHomes[hostID] = rHome
        }
        if res.connection.isOnline {
            var remoteList = res.sessions
            if cfg.approvalEnabled {
                mergePendingApprovals(res.pendingApprovals, into: &remoteList, host: hostID)
            }
            sessions.removeAll { $0.host == hostID }
            sessions.append(contentsOf: remoteList)
        }
        notifyStatusBar()
    }

    func refreshBalances(silent: Bool = false) async {
        guard !demoModeEnabled, !isRefreshingBalances else { return }
        let enabled = balanceSources.filter(\.isEnabled)
        let antigravityCLI = AntigravityUsageService.executable
        guard !enabled.isEmpty || antigravityCLI != nil else {
            balanceReadings = []
            saveCodable(balanceReadings, key: "cachedBalanceReadings")
            antigravityPlan = nil
            antigravityQuotas = []
            lastAntigravityPlanAttemptAt = nil
            updateSubscriptionCards()
            return
        }
        isRefreshingBalances = true
        defer { isRefreshingBalances = false }

        async let antigravityRefresh: Void = refreshAntigravityUsage(executable: antigravityCLI, forcePlan: !silent)
        let previousByID = Dictionary(uniqueKeysWithValues: balanceReadings.map { ($0.sourceID, $0) })
        var updated: [BalanceReading] = []
        for src in enabled {
            let reading = await BalanceService.fetchReading(for: src) { url, expr in
                try await WebBalanceExtractor.shared.evaluateOnPage(url: url, jsOrSelector: expr)
            }
            if silent,
               reading.formattedValue == "获取失败",
               let prev = previousByID[src.id],
               !prev.needsLogin,
               prev.formattedValue != "获取失败" {
                updated.append(prev)
            } else {
                updated.append(reading)
            }
        }
        await antigravityRefresh
        guard !demoModeEnabled else { return }
        balanceReadings = updated
        lastBalanceRefreshAt = Date()
        saveCodable(updated, key: "cachedBalanceReadings")
    }

    private func refreshAntigravityUsage(executable: URL?, forcePlan: Bool) async {
        if let executable {
            let planIsStale = lastAntigravityPlanAttemptAt.map { Date().timeIntervalSince($0) >= 3600 } ?? true
            let includePlan = forcePlan || planIsStale
            let result = await AntigravityUsageService.fetch(executable: executable, includePlan: includePlan)
            guard !demoModeEnabled else { return }
            antigravityQuotas = result.quotas
            if includePlan && !result.quotas.isEmpty {
                lastAntigravityPlanAttemptAt = Date()
                antigravityPlan = result.plan
            }
        } else {
            antigravityQuotas = []
            antigravityPlan = nil
            lastAntigravityPlanAttemptAt = nil
        }
        updateSubscriptionCards()
    }

    func openDashboardWindow(for reading: BalanceReading) {
        guard let src = balanceSources.first(where: { $0.id == reading.sourceID }) else {
            if let urlStr = reading.dashboardURL, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        openDashboardWindow(for: src)
    }

    func openDashboardWindow(for source: BalanceSourceConfig) {
        WebBalanceExtractor.shared.openInteractiveLoginWindow(
            urlString: source.urlOrCommand,
            title: source.name,
            extractorExpression: source.extractorOrJSONPath
        ) { [weak self] rawPayload in
            guard let self else { return }
            let updatedReading = BalanceService.parseWebPayload(rawJSONOrString: rawPayload, source: source)
            if let idx = self.balanceReadings.firstIndex(where: { $0.sourceID == source.id }) {
                self.balanceReadings[idx] = updatedReading
            } else {
                self.balanceReadings.append(updatedReading)
            }
            self.lastBalanceRefreshAt = Date()
            self.saveCodable(self.balanceReadings, key: "cachedBalanceReadings")
            self.balanceTestMessage[source.id] = "已自动同步：\(updatedReading.formattedValue)"
        }
    }

    private func mergePendingApprovals(
        _ approvals: [PendingApproval],
        into list: inout [AgentSession],
        host: HostID
    ) {
        for approval in approvals {
            if let idx = list.firstIndex(where: {
                ($0.rawSessionID == approval.sessionID) || ($0.cwd != nil && $0.cwd == approval.cwd && $0.kind == .claudeCode)
            }) {
                list[idx].status = .awaitingApproval
                list[idx].statusIsInferred = false
                list[idx].pendingApproval = approval
                list[idx].overview = "请求执行 \(approval.toolName)：\(approval.commandOrSummary)"
                triggerApprovalNotificationIfNeeded(session: list[idx], approval: approval)
            } else {
                let dirName = approval.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
                let synthetic = AgentSession(
                    id: "\(host.storageKey):approval:\(approval.requestID)",
                    rawSessionID: approval.sessionID ?? approval.requestID,
                    kind: .claudeCode,
                    host: host,
                    title: "\(dirName) 权限请求",
                    overview: "请求执行 \(approval.toolName)：\(approval.commandOrSummary)",
                    status: .awaitingApproval,
                    cwd: approval.cwd,
                    groupDirectory: approval.cwd,
                    provider: "Anthropic",
                    pendingApproval: approval,
                    startedAt: approval.requestedAt,
                    lastActivityAt: approval.requestedAt
                )
                list.insert(synthetic, at: 0)
                triggerApprovalNotificationIfNeeded(session: synthetic, approval: approval)
            }
        }
    }

    private func startBackgroundPolling() {
        localPollTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll(includeBalances: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if !self.demoModeEnabled {
                    await self.refreshLocalSessions()
                }
            }
        }
        sshPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !self.demoModeEnabled else { continue }
                await self.refreshSSHHosts()
            }
        }
        restartBalancePolling()
    }

    private func restartBalancePolling() {
        balancePollTask?.cancel()
        let interval = max(30, dashboardRefreshIntervalSeconds)
        balancePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, !self.demoModeEnabled else { continue }
                await self.refreshBalances(silent: true)
            }
        }
    }

    func discoverAndMergeSSHHosts() {
        let ud = UserDefaults.standard
        let needsAutoEnableMigration = !ud.bool(forKey: "sshAutoEnableMigratedV2")
        let discovered = SSHProbeService.discoverSSHConfigEntries()
        let discoveredAliases = Set(discovered.map(\.alias))
        let cleanedExisting = sshHosts.filter {
            !SSHProbeService.isIgnoredGitOrWildcardHost(alias: $0.alias, hostname: $0.hostname, user: $0.user)
                && (discoveredAliases.contains($0.alias) || $0.hostname == nil)
        }
        var existingByAlias = Dictionary(uniqueKeysWithValues: cleanedExisting.map { ($0.alias, $0) })

        for entry in discovered {
            if var old = existingByAlias[entry.alias] {
                old.hostname = entry.hostname ?? old.hostname
                old.user = entry.user ?? old.user
                old.port = entry.port ?? old.port
                if needsAutoEnableMigration {
                    old.isEnabled = true
                }
                existingByAlias[entry.alias] = old
            } else {
                existingByAlias[entry.alias] = entry
            }
        }
        if needsAutoEnableMigration {
            ud.set(true, forKey: "sshAutoEnableMigratedV2")
        }

        let ordered = existingByAlias.values.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        sshHosts = ordered

        for cfg in ordered where cfg.isEnabled {
            let hid = HostID.ssh(alias: cfg.alias)
            if hostStates[hid] == nil {
                hostStates[hid] = HostConnectionState(host: hid, isOnline: true)
            }
        }
    }

    func sshHostConfig(for host: HostID) -> SSHHostConfig? {
        guard case .ssh(let alias) = host else { return nil }
        return sshHosts.first { $0.alias == alias }
    }

    var launchAtLoginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Ignore if running unbundled
            }
        }
    }

    private func notifyStatusBar() {
        onStatusBarNeedsUpdate?()
    }

    private func setupNotificationsIfAvailable() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let approveAction = UNNotificationAction(identifier: "APPROVE", title: "批准一次", options: [])
        let denyAction = UNNotificationAction(identifier: "DENY", title: "拒绝", options: [.destructive])
        let cat = UNNotificationCategory(
            identifier: "AGENTBAR_APPROVAL",
            actions: [approveAction, denyAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([cat])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func triggerApprovalNotificationIfNeeded(session: AgentSession, approval: PendingApproval) {
        guard notificationsEnabled,
              Bundle.main.bundleIdentifier != nil,
              notifiedApprovalIDs.insert(approval.requestID).inserted else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(session.kind.displayName) 需要审批 · \(session.title)"
        content.body = "\(approval.toolName)：\(approval.commandOrSummary)"
        content.sound = .default
        if approval.highRiskMatchedRule == nil {
            content.categoryIdentifier = "AGENTBAR_APPROVAL"
        }
        let req = UNNotificationRequest(identifier: approval.requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func loadPersistedPreferences() {
        let ud = UserDefaults.standard
        if let rawStyle = ud.string(forKey: "menuBarStyle"),
           let style = MenuBarIconStyle(rawValue: rawStyle) {
            menuBarStyle = style
        }
        demoModeEnabled = ud.bool(forKey: "demoModeEnabled")
        let savedLookback = ud.double(forKey: "lookbackHours")
        if savedLookback > 0 { lookbackHours = savedLookback }
        let savedDashInterval = ud.double(forKey: "dashboardRefreshIntervalSeconds")
        if savedDashInterval >= 30 { dashboardRefreshIntervalSeconds = savedDashInterval }
        includeSubagents = ud.bool(forKey: "includeSubagents")
        if ud.object(forKey: "notificationsEnabled") != nil {
            notificationsEnabled = ud.bool(forKey: "notificationsEnabled")
        }
        if let seen: [String] = loadCodable(key: "seenSessionIDs") {
            seenSessionIDs = Set(seen)
        }
        if let collapsed: [String] = loadCodable(key: "collapsedGroupIDs") {
            collapsedGroupIDs = Set(collapsed)
        }
        if !ud.bool(forKey: "v3GroupingMigrated") {
            collapsedGroupIDs = collapsedGroupIDs.filter { $0.contains("::") }
            saveCodable(Array(collapsedGroupIDs), key: "collapsedGroupIDs")
            ud.set(true, forKey: "v3GroupingMigrated")
        }
        if let pinned: [String] = loadCodable(key: "pinnedGroupIDs") {
            pinnedGroupIDs = Set(pinned)
        }
        if let hostOrder: [String] = loadCodable(key: "customHostOrder") {
            customHostOrder = hostOrder
        }
        if let rawProjSort = ud.string(forKey: "projectSortOrder"),
           let ps = ProjectSortOrder(rawValue: rawProjSort) {
            projectSortOrder = ps
        }
        if let rawHostSort = ud.string(forKey: "hostSortOrder"),
           let hs = HostSortOrder(rawValue: rawHostSort) {
            hostSortOrder = hs
        }
        if let hosts: [SSHHostConfig] = loadCodable(key: "sshHosts") {
            sshHosts = hosts
        }
        if let sources: [BalanceSourceConfig] = loadCodable(key: "balanceSources") {
            balanceSources = sources
        }
        if let cachedReadings: [BalanceReading] = loadCodable(key: "cachedBalanceReadings"),
           !cachedReadings.isEmpty {
            let validIDs = Set(balanceSources.filter(\.isEnabled).map(\.id))
            balanceReadings = cachedReadings.filter { validIDs.contains($0.sourceID) }
        }
    }

    private func saveCodable<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadCodable<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
