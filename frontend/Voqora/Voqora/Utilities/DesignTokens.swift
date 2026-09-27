import AppKit
import SwiftUI

enum DesignTokens {
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 14
        static let xLarge: CGFloat = 16
        static let overlay: CGFloat = 24
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 44
    }

    enum Layout {
        static let paneInset: CGFloat = Spacing.lg
        static let sectionGap: CGFloat = Spacing.xl
        static let cardInset: CGFloat = Spacing.lg
        static let rowInsetHorizontal: CGFloat = Spacing.md
        static let rowInsetVertical: CGFloat = Spacing.sm
        static let rowIconGap: CGFloat = Spacing.md
        static let barInsetHorizontal: CGFloat = Spacing.lg
        static let barInsetVertical: CGFloat = Spacing.md
        static let rowMinHeight: CGFloat = 32
    }

    enum Radius {
        static let xxs: CGFloat = 3
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
    }

    enum Animation {
        static var quick: SwiftUI.Animation? {
            reduceMotionEnabled ? nil : SwiftUI.Animation.easeInOut(duration: 0.15)
        }

        static var standard: SwiftUI.Animation? {
            reduceMotionEnabled ? nil : SwiftUI.Animation.easeInOut(duration: 0.25)
        }

        private static var reduceMotionEnabled: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    struct FontRole {
        let size: CGFloat
        let weight: SwiftUI.Font.Weight
    }
}

extension DesignTokens.FontRole {
    static let pageTitle = Self(size: 28, weight: .bold)
    static let paneTitle = Self(size: 16, weight: .semibold)
    static let sectionHeader = Self(size: 11, weight: .semibold)
    static let sectionTitle = Self(size: 15, weight: .semibold)
    static let button = Self(size: 13, weight: .medium)
    static let rowTitle = Self(size: 13, weight: .regular)
    static let rowSubtitle = Self(size: 11, weight: .regular)
    static let caption = Self(size: 10, weight: .regular)
    static let chip = Self(size: 9, weight: .medium)
}
