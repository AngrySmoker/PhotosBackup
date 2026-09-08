import PhotosUI
import SwiftUI

/// iOS 15-compatible photo/video picker.
///
/// SwiftUI's `PhotosPicker` (and `PhotosPickerItem`) are iOS 16+, so this wraps
/// the UIKit `PHPickerViewController`, which is available from iOS 14. Results
/// are mapped to `[MediaSource]` via `MediaLibrary.sources(forPickerResults:)`:
/// an asset identifier when the library is readable (keeps the original
/// filename and capture date), otherwise the item provider for a lazy copy at
/// export time.
struct PhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 50
    var onPicked: ([MediaSource]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([MediaSource]) -> Void

        init(onPicked: @escaping ([MediaSource]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let sources = MediaLibrary.sources(forPickerResults: results)
            picker.dismiss(animated: true)
            onPicked(sources)
        }
    }
}
