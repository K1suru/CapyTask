import AppKit
import SwiftUI

struct ProcessListTab: View {
    private let engine = SystemMonitorEngine.shared

    @ViewState private var search = ""
    @ViewState private var onlyUserApps = false
    @ViewState private var sortOrder = [KeyPathComparator(\ProcessSample.cpuSortValue, order: .reverse)]
    @ViewState private var selection: ProcessSample.ID?
    @ViewState private var pendingKill: ProcessSample?
    @ViewState private var toast: Toast?
    @ViewState private var killing: Set<Int32> = []
    @FocusState private var searchFocused: Bool

    private var rows: [ProcessSample] {
        var list = engine.processes
        if onlyUserApps { list = list.filter(\.isUserApp) }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false)
                    || String($0.pid).hasPrefix(query)
            }
        }
        return list.sorted(using: sortOrder)
    }

    private var selected: ProcessSample? {
        selection.flatMap { pid in engine.processes.first { $0.pid == pid } }
    }

    var body: some View {
        VStack(spacing: 10) {
            controlBar
            table
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.bottom, 62)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert(
            L("¿Finalizar «\(pendingKill?.name ?? "")»?", "End “\(pendingKill?.name ?? "")”?"),
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { process in
            Button(L("Finalizar Tarea", "End Task"), role: .destructive) { terminate(process) }
            Button(L("Cancelar", "Cancel"), role: .cancel) {}
        } message: { process in
            Text(L("El capibara le pedirá amablemente que se cierre (SIGTERM). Si no responde en 3 segundos, lo forzará (SIGKILL). Los cambios sin guardar de \(process.name) podrían perderse.", "The capybara will politely ask it to quit (SIGTERM). If it doesn’t respond within 3 seconds, it will be forced (SIGKILL). Unsaved changes in \(process.name) may be lost."))
        }
    }

    // MARK: - Barra de control

    private var controlBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.inkSoft)
                TextField(L("Buscar por app o proceso...", "Search apps or processes..."), text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.rounded(12.5))
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: 260)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(searchFocused ? Theme.mandarina.opacity(0.6) : Theme.cardBorder, lineWidth: 1)
            )
            .background {
                Button(L("Buscar", "Search")) { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }

            CapsuleChoice(title: L("Solo Mis Apps", "My Apps Only"), isSelected: onlyUserApps) {
                withAnimation(.snappy) { onlyUserApps = true }
            }
            CapsuleChoice(title: L("Todos los Procesos", "All Processes"), isSelected: !onlyUserApps) {
                withAnimation(.snappy) { onlyUserApps = false }
            }

            Spacer(minLength: 4)

            let userApps = engine.processes.filter(\.isUserApp).count
            Text(verbatim: L("\(userApps) apps de usuario / \(engine.processes.count) procesos totales", "\(userApps) user apps / \(engine.processes.count) total processes"))
                .font(Theme.rounded(11, .medium).monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Tabla

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Nombre", "Name"), value: \.name, comparator: .localizedStandard) { process in
                ProcessNameCell(process: process, isKilling: killing.contains(process.pid))
            }
            .width(min: 180, ideal: 250)

            TableColumn("PID", value: \.pid) { process in
                Text(verbatim: String(process.pid))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkSoft)
            }
            .width(min: 50, ideal: 62)

            TableColumn("CPU (%)", value: \.cpuSortValue) { process in
                CPUCell(process: process)
            }
            .width(min: 96, ideal: 112)

            TableColumn(L("Memoria (MB)", "Memory (MB)"), value: \.memorySortValue) { process in
                MemoryCell(process: process, totalMemory: engine.totalMemory)
            }
            .width(min: 92, ideal: 108)

            TableColumn(L("Tipo", "Type"), value: \.kindSortValue) { process in
                KindTag(isUserApp: process.isUserApp)
            }
            .width(min: 64, ideal: 76)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ProcessSample.ID.self) { pids in
            if let pid = pids.first, let process = engine.processes.first(where: { $0.pid == pid }) {
                Button(L("Finalizar Tarea…", "End Task…")) { pendingKill = process }
                    .disabled(!process.isOwnedByUser)
                if let path = process.bundlePath ?? process.path {
                    Button(L("Mostrar en Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Divider()
                Button(L("Copiar nombre", "Copy Name")) { copy(process.name) }
                Button(L("Copiar PID", "Copy PID")) { copy(String(process.pid)) }
            }
        }
        .overlay {
            if engine.processes.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Leyendo la tabla de procesos del kernel…", "Reading the kernel process table…"))
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.inkSoft)
                }
            } else if rows.isEmpty {
                Text(L("Ningún proceso coincide con «\(search)» 🍊", "No process matches “\(search)” 🍊"))
                    .font(Theme.rounded(12.5, .medium))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }

    // MARK: - Pie

    private var footer: some View {
        HStack(spacing: 10) {
            if let process = selected {
                ProcessIcon(bundlePath: process.bundlePath, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(process.name)
                        .font(Theme.rounded(12.5, .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: process.isOwnedByUser
                         ? "PID \(process.pid)" + (process.threadCount.map { L(" · \($0) hilos", " · \($0) threads") } ?? "")
                         : "PID \(process.pid) · " + L("Proceso del sistema: macOS no permite finalizarlo sin privilegios", "System process: macOS won’t allow ending it without privileges"))
                        .font(Theme.rounded(10.5))
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(Theme.inkSoft)
                Text(L("Selecciona un proceso para ver sus detalles o finalizarlo", "Select a process to see its details or end it"))
                    .font(Theme.rounded(11.5))
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            Button {
                pendingKill = selected
            } label: {
                Label(L("Finalizar Tarea", "End Task"), systemImage: "xmark.octagon.fill")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(selected.map { !$0.isOwnedByUser || killing.contains($0.pid) } ?? true)
            .keyboardShortcut(.delete, modifiers: .command)
            .help(L("Finalizar el proceso seleccionado (⌘⌫)", "End the selected process (⌘⌫)"))
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }

    // MARK: - Acciones

    private func terminate(_ process: ProcessSample) {
        killing.insert(process.pid)
        Task {
            let outcome = await ProcessKiller.terminate(pid: process.pid)
            killing.remove(process.pid)
            if outcome == .terminated || outcome == .forceKilled || outcome == .alreadyGone, selection == process.pid {
                selection = nil
            }
            show(Toast(outcome: outcome, name: process.name))
            engine.refreshNow()
        }
    }

    private func show(_ newToast: Toast) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = newToast }
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            if toast?.id == newToast.id {
                withAnimation(.easeOut(duration: 0.3)) { toast = nil }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Celdas

private struct ProcessNameCell: View {
    let process: ProcessSample
    let isKilling: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProcessIcon(bundlePath: process.bundlePath, size: 18)
            Text(process.name)
                .font(Theme.rounded(12.5, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if isKilling {
                ProgressView().controlSize(.mini)
            }
        }
        .help(process.path ?? process.name)
    }
}

private struct CPUCell: View {
    let process: ProcessSample

    var body: some View {
        HStack(spacing: 6) {
            Text(process.cpuPercent.map { Format.cpu($0) } ?? "—")
                .font(Theme.rounded(12, .medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: 44, alignment: .trailing)
            UsageBar(value: (process.cpuPercent ?? 0) / 100, color: Theme.mandarina, height: 5)
                .frame(width: 38)
        }
        .help(process.cpuPercent == nil
              ? L("Midiendo… (los procesos protegidos del sistema tardan unos segundos)", "Measuring… (protected system processes take a few seconds)")
              : L("100% equivale a un núcleo completo, como en Monitor de Actividad", "100% equals one full core, like in Activity Monitor"))
    }
}

private struct MemoryCell: View {
    let process: ProcessSample
    let totalMemory: UInt64

    var body: some View {
        HStack(spacing: 6) {
            WeightIndicator(bytes: process.memoryBytes ?? 0, totalMemory: totalMemory)
            Text(process.memoryBytes.map { Format.megabytes($0) } ?? "—")
                .font(Theme.rounded(12, .medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
        }
        .help(process.memoryBytes.map { Format.bytes($0) } ?? L("Sin datos de memoria", "No memory data"))
    }
}

// MARK: - Aviso flotante

private struct Toast: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let message: String
    let isError: Bool

    init(outcome: KillOutcome, name: String) {
        switch outcome {
        case .terminated:
            symbol = "checkmark.circle.fill"; message = L("«\(name)» se cerró correctamente", "“\(name)” quit successfully"); isError = false
        case .forceKilled:
            symbol = "bolt.circle.fill"; message = L("«\(name)» no respondía y se forzó su cierre", "“\(name)” wasn’t responding and was force quit"); isError = false
        case .alreadyGone:
            symbol = "checkmark.circle.fill"; message = L("«\(name)» ya no estaba en ejecución", "“\(name)” was no longer running"); isError = false
        case .notPermitted:
            symbol = "lock.circle.fill"; message = L("macOS no permite finalizar «\(name)» sin privilegios", "macOS won’t allow ending “\(name)” without privileges"); isError = true
        case .protected:
            symbol = "shield.lefthalf.filled"; message = L("«\(name)» está protegido: el capibara no lo tocará", "“\(name)” is protected: the capybara won’t touch it"); isError = true
        case .failed(let code):
            symbol = "exclamationmark.triangle.fill"; message = L("No se pudo finalizar «\(name)» (error \(code))", "Couldn’t end “\(name)” (error \(code))"); isError = true
        }
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.isError ? Theme.danger : Theme.bamboo)
            Text(toast.message)
                .font(Theme.rounded(12, .semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
