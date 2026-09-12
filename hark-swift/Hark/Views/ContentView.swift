import SwiftUI

struct ContentView: View {
    @State private var model = AppModel.shared
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            MainPane()
        }
        .background(palette.bg)
        .environment(\.palette, palette)
        .preferredColorScheme(overrideScheme)
        .sheet(isPresented: $model.settingsOpen) {
            SettingsSheet()
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var palette: Palette {
        Palette.forTheme(model.settings.theme, systemDark: systemScheme == .dark)
    }

    private var overrideScheme: ColorScheme? {
        switch model.settings.theme {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}
