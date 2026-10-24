import SwiftUI

struct VisualSummaryTab: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                PerformanceCard()
                    .frame(width: 292)
                TopAppsCard()
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                MemoryCard()
                ProcessorCard()
                ActivityCard()
            }
            .frame(height: 146)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }
}

// MARK: - Rendimiento (anillos + capibara)

private struct PerformanceCard: View {
    private let engine = SystemMonitorEngine.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                CardTitle(symbol: "gauge.with.dots.needle.67percent", title: L("Rendimiento", "Performance"), tint: Theme.capyBrown)
                Spacer()
                Text(engine.mood.title)
                    .font(Theme.rounded(10.5, .bold))
                    .foregroundStyle(Theme.color(for: engine.mood))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Theme.color(for: engine.mood).opacity(0.15)))
            }

            ConcentricRings(rings: [
                RingSpec(id: "disk", value: engine.disk.usedFraction, color: Theme.onsen),
                RingSpec(id: "ram", value: engine.memory.usedFraction, color: Theme.bamboo),
                RingSpec(id: "cpu", value: engine.cpu.usage, color: Theme.mandarina),
            ], lineWidth: 9, gap: 3) {
                GeometryReader { geometry in
                    ZStack {
                        Circle().fill(Theme.color(for: engine.mood).opacity(0.12))
                        CapySpriteView(state: engine.mood.sprite, height: geometry.size.height * 0.86)
                            .offset(y: geometry.size.height * 0.02)
                    }
                }
            }
            .frame(minHeight: 120)

            Text(engine.mood.statusLine(effortPercent: Int((engine.stress * 100).rounded())))
                .font(Theme.rounded(12, .semibold))
                .foregroundStyle(Theme.accentInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 0) {
                LegendDot(color: Theme.mandarina, label: "CPU", value: Format.percent(engine.cpu.usage))
                    .frame(maxWidth: .infinity, alignment: .leading)
                LegendDot(color: Theme.bamboo, label: "RAM", value: Format.bytes(engine.memory.used))
                    .frame(maxWidth: .infinity, alignment: .leading)
                LegendDot(color: Theme.onsen, label: L("Disco", "Disk"), value: Format.percent(engine.disk.usedFraction))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(L("\(Format.bytes(engine.disk.available)) libres de \(Format.bytes(engine.disk.total))", "\(Format.bytes(engine.disk.available)) free of \(Format.bytes(engine.disk.total))"))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chip))
        }
        .capyCard()
    }
}

// MARK: - Top Apps

private struct TopAppsCard: View {
    @Bindable private var state = AppState.shared
    private let engine = SystemMonitorEngine.shared

    private var topApps: [AppUsage] {
        let sorted: [AppUsage] = switch state.topAppsMetric {
        case .cpu: engine.apps.sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
        case .memory: engine.apps.sorted { $0.memoryBytes > $1.memoryBytes }
        }
        return Array(sorted.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(symbol: "fork.knife", title: L("Top Apps Devoradoras", "Hungriest Apps"), tint: Theme.mandarina)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(TopAppsMetric.allCases) { metric in
                        CapsuleChoice(title: metric.label, isSelected: state.topAppsMetric == metric) {
                            withAnimation(.snappy) { state.topAppsMetric = metric }
                        }
                    }
                }
            }

            if engine.apps.isEmpty || (state.topAppsMetric == .cpu && !engine.apps.contains(where: \.cpuMeasured)) {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("El capibara está midiendo el consumo…", "The capybara is measuring usage…"))
                        .font(Theme.rounded(11.5))
                        .foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let apps = topApps
                let leader = max(leaderValue(apps.first), 0.0001)
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        TopAppRow(rank: index + 1, app: app, metric: state.topAppsMetric, fraction: value(of: app) / leader)
                        if index < apps.count - 1 {
                            Divider().overlay(Theme.cardBorder).padding(.leading, 58)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .capyCard()
    }

    private func value(of app: AppUsage) -> Double {
        state.topAppsMetric == .cpu ? app.cpuPercent : Double(app.memoryBytes)
    }

    private func leaderValue(_ app: AppUsage?) -> Double {
        app.map(value(of:)) ?? 0
    }
}

private struct TopAppRow: View {
    let rank: Int
    let app: AppUsage
    let metric: TopAppsMetric
    let fraction: Double

    private var cpuText: String {
        app.cpuMeasured ? Format.cpu(app.cpuPercent) : "—"
    }

    var body: some View {
        HStack(spacing: 10) {
            RankBadge(rank: rank)
            ProcessIcon(bundlePath: app.bundlePath, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(Theme.rounded(12.5, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if app.processCount > 1 {
                        Text(L("· \(app.processCount) procesos", "· \(app.processCount) processes"))
                            .font(Theme.rounded(10))
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                    }
                }
                UsageBar(value: fraction, color: metric == .cpu ? Theme.mandarina : Theme.bamboo, height: 5)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(metric == .cpu ? cpuText : Format.bytes(app.memoryBytes))
                    .font(Theme.rounded(12.5, .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text(metric == .cpu ? Format.bytes(app.memoryBytes) : cpuText)
                    .font(Theme.rounded(10).monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .help(app.bundlePath ?? app.executablePath ?? app.name)
    }
}

private struct RankBadge: View {
    let rank: Int

    private var color: Color {
        switch rank {
        case 1: Color(hex: 0xF5B83D)
        case 2: Color(hex: 0xB9C0C9)
        case 3: Color(hex: 0xD49A6A)
        default: Theme.track
        }
    }

    var body: some View {
        Text("\(rank)")
            .font(Theme.rounded(11, .heavy))
            .foregroundStyle(rank <= 3 ? .white : Theme.inkSoft)
            .frame(width: 20, height: 20)
            .background(Circle().fill(color.gradient))
    }
}

// MARK: - Métricas rápidas

private struct MemoryCard: View {
    private let engine = SystemMonitorEngine.shared

    var body: some View {
        let memory = engine.memory
        let total = Double(max(memory.total, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardTitle(symbol: "memorychip.fill", title: L("Memoria", "Memory"), tint: Theme.bamboo)
                Spacer()
                Text(L("Presión: ", "Pressure: ") + memory.pressure.label)
                    .font(Theme.rounded(9.5, .semibold))
                    .foregroundStyle(memory.pressure == .normal ? Theme.bambooInk : Theme.danger)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.bytes(memory.used))
                    .font(Theme.rounded(19, .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text(L("de ", "of ") + Format.bytes(memory.total))
                    .font(Theme.rounded(11))
                    .foregroundStyle(Theme.inkSoft)
            }
            // Páginas físicas tal como las cuenta el kernel (host_statistics64).
            StackedBar(segments: [
                StackedBarSegment(id: "wired", value: Double(memory.wired) / total, color: Theme.woodLight),
                StackedBarSegment(id: "active", value: Double(memory.active) / total, color: Theme.bamboo),
                StackedBarSegment(id: "inactive", value: Double(memory.inactive) / total, color: Theme.bambooLight),
                StackedBarSegment(id: "compressed", value: Double(memory.compressed) / total, color: Theme.peach),
                StackedBarSegment(id: "free", value: Double(memory.free) / total, color: Theme.onsenLight),
            ])
            .help(
                L("Activa", "Active") + " \(Format.bytes(memory.active)) · " + L("Inactiva", "Inactive")
                    + " \(Format.bytes(memory.inactive)) · Wired \(Format.bytes(memory.wired)) · "
                    + L("Comprimida", "Compressed") + " \(Format.bytes(memory.compressed)) · "
                    + L("Libre", "Free") + " \(Format.bytes(memory.free))\n"
                    + L("Usada (como Monitor de Actividad) = App ", "Used (like Activity Monitor) = App ")
                    + Format.bytes(memory.app) + L(" + Wired + Comprimida", " + Wired + Compressed")
            )
            ViewThatFits(in: .horizontal) {
                legend(compact: false)
                legend(compact: true)
            }
            Spacer(minLength: 0)
            Text(L("Disponible: ", "Available: ") + "\(Format.bytes(memory.available)) · Swap: \(Format.bytes(memory.swapUsed))")
                .font(Theme.rounded(10.5, .medium))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .capyCard(padding: 12)
    }

    private func legend(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            miniLegend(Theme.bamboo, compact ? L("Act.", "Act.") : L("Activa", "Active"))
            miniLegend(Theme.bambooLight, compact ? L("Inact.", "Inact.") : L("Inactiva", "Inactive"))
            miniLegend(Theme.woodLight, "Wired")
            miniLegend(Theme.peach, L("Compr.", "Compr."))
            miniLegend(Theme.onsenLight, L("Libre", "Free"))
        }
    }

    private func miniLegend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.rounded(9.5)).foregroundStyle(Theme.inkSoft).fixedSize()
        }
    }
}

private struct ProcessorCard: View {
    private let engine = SystemMonitorEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardTitle(symbol: "cpu.fill", title: L("Procesador", "Processor"), tint: Theme.mandarina)
                Spacer()
                Text(engine.cpuModel.replacingOccurrences(of: "Apple ", with: ""))
                    .font(Theme.rounded(9.5, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.percent(engine.cpu.usage))
                    .font(Theme.rounded(19, .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text(L("usuario", "user") + " \(Format.percent(engine.cpu.user)) · " + L("sistema", "system") + " \(Format.percent(engine.cpu.system))")
                    .font(Theme.rounded(10))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            CoreBars(cores: engine.cpu.cores)
                .frame(maxHeight: .infinity)
            Text("\(coreSummary) · " + L("Muestreo", "Sampling") + " \(Format.seconds(engine.interval))")
                .font(Theme.rounded(10.5, .medium))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .capyCard(padding: 12)
    }

    private var coreSummary: String {
        let total = engine.coreKinds.count
        let performance = engine.performanceCoreCount
        let efficiency = engine.efficiencyCoreCount
        guard performance > 0, efficiency > 0 else { return L("\(total) núcleos", "\(total) cores") }
        return L("\(total) núcleos", "\(total) cores") + " (\(performance)P + \(efficiency)E)"
    }
}

private struct ActivityCard: View {
    private let engine = SystemMonitorEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardTitle(symbol: "waveform.path.ecg", title: L("Actividad", "Activity"), tint: Theme.onsen)
                Spacer()
                HStack(spacing: 6) {
                    legend(Theme.mandarina, "CPU")
                    legend(Theme.bamboo, "RAM")
                }
            }
            ZStack {
                VStack {
                    Divider().overlay(Theme.cardBorder)
                    Spacer()
                    Divider().overlay(Theme.cardBorder)
                    Spacer()
                    Divider().overlay(Theme.cardBorder)
                }
                Sparkline(values: engine.memoryHistory, color: Theme.bamboo)
                Sparkline(values: engine.cpuHistory, color: Theme.mandarina)
            }
            .frame(maxHeight: .infinity)
            .clipped()
            Text(L("Encendido: ", "Uptime: ") + "\(Format.uptime(ProcessInfo.processInfo.systemUptime)) · CapyTask: \(Format.bytes(engine.selfUsage.memoryBytes))")
                .font(Theme.rounded(10.5, .medium))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .capyCard(padding: 12)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 8, height: 3)
            Text(label).font(Theme.rounded(9.5, .medium)).foregroundStyle(Theme.inkSoft)
        }
    }
}
