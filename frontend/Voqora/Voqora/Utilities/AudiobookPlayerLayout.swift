import SwiftUI

enum AudiobookPlayerLayout {
    static let coverColumnBreakpoint: CGFloat = 860
    static let controlsColumnWidth: CGFloat = 320
    static let minWidth: CGFloat = 480

    struct ColumnVisibility: Equatable {
        let showCover: Bool
    }

    static func columnVisibility(for width: CGFloat) -> ColumnVisibility {
        ColumnVisibility(showCover: max(0, width) >= coverColumnBreakpoint)
    }

    static func artworkHeight(forAvailableHeight height: CGFloat) -> CGFloat {
        min(336, max(180, height * 0.4))
    }
}
