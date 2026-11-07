import Foundation
import Photos

/// The only place in the app that talks to the system photo library.
///
/// "相册" in the UI means **Apple Photos**, not a folder this app owns: the
/// watched-folder feature exists so a screenshot saved anywhere can land in
/// 照片 without opening 照片. That is why this uses `PHPhotoLibrary` instead of
/// copying bytes into Application Support.
///
/// Add-only access (`NSPhotoLibraryAddUsageDescription`) is all that is needed
/// and all that is requested: the app never enumerates or reads the user's
/// existing library.
enum PhotosLibrary {
    /// What happened to one image.
    enum Outcome: Equatable, Sendable {
        /// Written to 照片. `localIdentifier` is nil only if Photos did not hand
        /// one back, which does not mean the write failed.
        case added(localIdentifier: String?)
        /// The user has not granted 照片 access (or revoked it).
        case denied
        case failed(String)
    }

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static var hasAccess: Bool {
        let status = authorizationStatus
        return status == .authorized || status == .limited
    }

    /// Ask once for add-only access. Safe to call repeatedly: Photos returns the
    /// remembered answer without prompting again.
    static func requestAccess() async -> Bool {
        let status = authorizationStatus
        switch status {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        @unknown default:
            return false
        }
    }

    /// Write one image into the user's 照片 library.
    ///
    /// `pngData` is passed as a resource with an `originalFilename`, so 照片
    /// shows the screenshot's real name rather than a UUID.
    static func addImage(_ pngData: Data, filename: String?) async -> Outcome {
        guard await requestAccess() else { return .denied }

        // `performChanges` runs its block on a background queue; a class box is
        // the least clever way to bring the identifier back across that boundary
        // under Swift 6 strict concurrency.
        final class IdentifierBox: @unchecked Sendable {
            var value: String?
        }
        let box = IdentifierBox()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename ?? "Unseen.png"
                request.addResource(with: .photo, data: pngData, options: options)
                box.value = request.placeholderForCreatedAsset?.localIdentifier
            }
            return .added(localIdentifier: box.value)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Indirection so the folder watcher can be tested without the real Photos
/// library (which would prompt for TCC permission in a headless self-test).
protocol PhotosImporting: Sendable {
    /// Ask for add-only access. Returns false when the user has refused.
    func requestAccess() async -> Bool
    func addImage(_ pngData: Data, filename: String?) async -> PhotosLibrary.Outcome
}

/// Production implementation — the real system photo library.
struct SystemPhotosLibrary: PhotosImporting {
    func requestAccess() async -> Bool {
        await PhotosLibrary.requestAccess()
    }

    func addImage(_ pngData: Data, filename: String?) async -> PhotosLibrary.Outcome {
        await PhotosLibrary.addImage(pngData, filename: filename)
    }
}
