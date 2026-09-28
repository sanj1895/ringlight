import SwiftUI

/// An instant-film print (Instax Mini proportions) with the photo developing inside.
struct PrintCard: View {
    let image: UIImage?
    let progress: Double
    var width: CGFloat = 210

    var body: some View {
        // Border proportions match `Look.polaroidFrame`, so the saved photo looks the same.
        let photoWidth = width / (1 + 2 * 0.087)
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(red: 0.13, green: 0.14, blue: 0.12)
                }
            }
            .frame(width: photoWidth, height: photoWidth * 4 / 3)
            .clipped()
            .padding(.top, photoWidth * 0.15)
            .padding(.bottom, photoWidth * 0.37)
        }
        .frame(width: width)
        .background(Color(red: 0.96, green: 0.95, blue: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }
}

/// The print that's out, with what to do next underneath. Swipe it down to put it on the pile.
struct DevelopingPrint: View {
    @ObservedObject var developer: PrintDeveloper
    var onPutAway: () -> Void

    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            PrintCard(image: developer.image, progress: developer.progress)
                .rotationEffect(.degrees(-3))
                .offset(y: max(0, drag))
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 80 { onPutAway() }
                        withAnimation(.spring) { drag = 0 }
                    })
            Text(hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
                .contentTransition(.opacity)
                .animation(.easeInOut, value: hint)
        }
    }

    private var hint: String {
        switch developer.progress {
        case 1...: "Developed ✓"
        case 0.02...: "Keep shaking… \(Int(developer.progress * 100))%"
        default: "Shake to develop 🫨"
        }
    }
}
