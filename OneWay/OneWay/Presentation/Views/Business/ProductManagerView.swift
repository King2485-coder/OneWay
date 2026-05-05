import SwiftUI

struct ProductManagerView: View {
    @State var products: [ProductOrService]
    let onAskAI: () -> Void

    var body: some View {
        List {
            Section("Products") {
                ForEach(products) { product in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.name).font(.headline)
                        Text(product.description).font(.subheadline).foregroundStyle(.secondary)
                        Text(product.price).font(.caption)
                    }
                }
            }

            Section {
                Button("Ask AI to improve descriptions") { onAskAI() }
            }
        }
        .navigationTitle("Products")
    }
}
