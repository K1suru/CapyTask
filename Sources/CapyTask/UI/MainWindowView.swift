import SwiftUI

struct MainWindowView: View {
    /// Alto real de la barra de título, para alinear la cabecera con los semáforos.
    let titlebarHeight: CGFloat
    @Bindable private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(height: max(titlebarHeight, 38))
            Group {
                switch state.selectedTab {
                case .summary: VisualSummaryTab()
                case .processes: ProcessListTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 500)
    }
}

private struct HeaderBar: View {
    let height: CGFloat
    @Bindable private var state = AppState.shared
    private let engine = SystemMonitorEngine.shared

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                LogoBadge(size: 24)
                VStack(alignment: .leading, spacing: -1) {
                    Text("CapyTask")
                        .font(Theme.rounded(15, .bold))
                        .foregroundStyle(Theme.ink)
                    Text("\(engine.mood.emoji) \(engine.mood.title)")
                        .font(Theme.rounded(9.5, .medium))
                        .foregroundStyle(Theme.inkSoft)
                        .contentTransition(.opacity)
                }
                Spacer()
                PetToggle(isOn: $state.petVisible)
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)

            CapyTabPicker(selection: $state.selectedTab)
        }
        .frame(height: height)
        .background(WindowDragArea())
    }
}

private struct PetToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isOn ? Theme.mandarina : Theme.inkSoft)
            Text(L("Mascota en Pantalla", "Pet on Screen"))
                .font(Theme.rounded(11.5, .semibold))
                .foregroundStyle(Theme.ink)
            Toggle(L("Mascota en Pantalla", "Pet on Screen"), isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.mandarina)
                .labelsHidden()
        }
        .help(isOn ? L("Ocultar el capibara flotante", "Hide the floating capybara") : L("Mostrar el capibara flotante", "Show the floating capybara"))
    }
}

struct CapyTabPicker: View {
    @Binding var selection: MainTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                let isSelected = selection == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .foregroundStyle(isSelected ? Theme.mandarina : Theme.inkSoft)
                        Text(tab.title)
                            .foregroundStyle(isSelected ? Theme.ink : Theme.inkSoft)
                    }
                    .font(Theme.rounded(12, .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4.5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.card)
                                .shadow(color: .black.opacity(0.1), radius: 2.5, y: 1)
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(Capsule().fill(Theme.track))
    }
}
