import SwiftUI

/// After a burst: pick the shots worth keeping. Only those are saved.
struct BurstPicker: View {
    let shots: [BurstShot]
    var onKeep: ([BurstShot]) -> Void
    var onDiscard: () -> Void

    @State private var picked: Set<UUID> = []
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(shots) { shot in
                        let isPicked = picked.contains(shot.id)
                        Image(uiImage: shot.thumbnail)
                            .resizable()
                            .aspectRatio(3.0 / 4.0, contentMode: .fill)
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(isPicked ? Color.accentColor : .white)
                                    .background(Circle().fill(isPicked ? .white : .black.opacity(0.25)))
                                    .padding(6)
                            }
                            .opacity(picked.isEmpty || isPicked ? 1 : 0.6)
                            .onTapGesture {
                                if isPicked { picked.remove(shot.id) } else { picked.insert(shot.id) }
                            }
                    }
                }
                .padding(4)
            }
            .navigationTitle("\(shots.count) burst shots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive, action: onDiscard)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Keep all" : "Keep \(picked.count)") {
                        onKeep(picked.isEmpty ? shots : shots.filter { picked.contains($0.id) })
                    }
                    .bold()
                }
            }
        }
    }
}
