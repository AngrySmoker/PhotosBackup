import SwiftUI

// Small cross-version shims so the app deploys to iOS 15, where a few SwiftUI
// APIs used elsewhere are iOS 16+.

extension View {
    /// `.scrollIndicators(.hidden)` is iOS 16+. On iOS 15 the indicators simply
    /// show (a minor cosmetic difference). Prefer `ScrollView(showsIndicators:)`
    /// where the initializer is in reach; this covers the cases where it is not.
    @ViewBuilder
    func hiddenScrollIndicators() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }
}

/// A label/value row, the iOS 15-safe stand-in for `LabeledContent`.
struct LabeledRow<Value: View>: View {
    let title: String
    let value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            value
        }
    }
}

extension LabeledRow where Value == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value).foregroundColor(.secondary) }
    }
}
