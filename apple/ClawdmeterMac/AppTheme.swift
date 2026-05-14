import SwiftUI

/// Persisted theme preference. Defaults to `system` so the app follows macOS.
public enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` means "let the system decide" — `.preferredColorScheme(nil)`
    /// honors the user's macOS appearance.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    public static let storageKey = "clawdmeter.theme"
}
