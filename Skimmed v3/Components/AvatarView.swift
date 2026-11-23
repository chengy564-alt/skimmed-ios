import SwiftUI
import UIKit
import Combine

/// The user's avatar, shared app-wide. Renders the saved profile photo if
/// one exists, else a monogram from the onboarding name (a person glyph
/// when no name was given). Photo persistence lives in AvatarStore
/// (UserDefaults, JPEG downscaled to ≤512px) so every avatar in the app
/// updates the moment a new photo is picked.
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    private static let key = "profile.photo"

    @Published private(set) var image: UIImage?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            image = UIImage(data: data)
        }
    }

    func save(_ uiImage: UIImage) {
        let scaled = uiImage.scaledToFit(maxDimension: 512)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
        image = scaled
    }
}

private extension UIImage {
    func scaledToFit(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }
        let scale = maxDimension / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

struct AvatarView: View {
    var size: CGFloat

    @ObservedObject private var store = AvatarStore.shared
    @AppStorage("profile.name") private var storedName: String = ""

    private var monogram: String? {
        storedName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
    }

    var body: some View {
        ZStack {
            if let image = store.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Theme.accent.opacity(0.18))
                if let monogram {
                    Text(monogram)
                        .font(.app(size * 0.37, weight: .heavy))
                        .foregroundStyle(Theme.cream)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.37, weight: .semibold))
                        .foregroundStyle(Theme.cream.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}
