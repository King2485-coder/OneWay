import SwiftUI

struct MyNumbersView: View {
    @StateObject private var viewModel = MyNumbersViewModel()

    var body: some View {
        List {
            Section {
                ForEach(viewModel.numbers) { number in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(number.number)
                                .font(.headline)

                            if number.isPrimary {
                                badge("Primary", color: .blue)
                            }

                            if number.isPaid {
                                badge("Paid", color: .green)
                            }
                        }

                        Text(number.label ?? "OneWay number")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if viewModel.mutatingNumberID == number.id {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .swipeActions {
                        if !number.isPrimary {
                            Button("Primary") {
                                Task { await viewModel.makePrimary(number) }
                            }
                            .tint(.blue)
                        }

                        Button("Delete", role: .destructive) {
                            Task { await viewModel.delete(number) }
                        }
                    }
                    .disabled(viewModel.mutatingNumberID != nil || viewModel.isAddingNumber)
                }
            } header: {
                Text("My Numbers")
            }

            Section {
                Button {
                    Task { await viewModel.addNumber() }
                } label: {
                    if viewModel.isAddingNumber {
                        HStack {
                            ProgressView()
                            Text("Adding Number...")
                        }
                    } else {
                        OneWayResolvedLabel("Add Number", systemImage: "plus.circle.fill")
                    }
                }
                .disabled(viewModel.isAddingNumber || viewModel.mutatingNumberID != nil)
            }

            Section {
                Text("Your first 2 OneWay numbers are free. Extra numbers require OneWay Extra Numbers for $7.99/month.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("My Numbers")
        .overlay {
            if viewModel.isLoading && viewModel.numbers.isEmpty {
                ProgressView()
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.showPaywall) {
            ExtraNumbersPaywallView {
                Task { await viewModel.finishExtraNumbersPurchaseAndAddNumber() }
            }
        }
        .alert("OneWay", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18))
            .clipShape(Capsule())
    }
}
