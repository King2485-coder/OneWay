import SwiftUI

struct CollectionManagerView: View {
    @State var collections: [StoreCollection]
    let onAskAI: () -> Void

    var body: some View {
        List {
            ForEach(collections) { collection in
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name).font(.headline)
                    Text(collection.description).font(.subheadline).foregroundStyle(.secondary)
                    Text("\(collection.productIDs.count) items").font(.caption)
                }
            }

            Section {
                Button("Ask AI to suggest collections") { onAskAI() }
            }
        }
        .navigationTitle("Collections")
    }
}
