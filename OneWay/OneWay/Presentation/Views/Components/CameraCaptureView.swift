import SwiftUI
import UIKit

struct CameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    var body: some View {
        ZStack {
            SideMenuBackground()

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                CameraImagePicker { image in
                    onCapture(image)
                    dismiss()
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.slash")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Camera is not available on this device.")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Close") { dismiss() }
                        .buttonStyle(PrimaryPillButtonStyle())
                }
                .padding(24)
            }
        }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void

        init(onCapture: @escaping (UIImage) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            picker.dismiss(animated: true)
        }
    }
}
