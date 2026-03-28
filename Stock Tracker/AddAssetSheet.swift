import SwiftUI

struct AddAssetSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    let kind: AssetKind
    
    @State private var symbol: String = ""
    @State private var name: String = ""
    @State private var priceText: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Asset Details")) {
                    TextField("Symbol (e.g. AAPL, BTC)", text: $symbol)
                        .autocapitalization(.allCharacters)
                    TextField("Name", text: $name)
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Text("Add a custom \(kind == .stock ? "stock" : "cryptocurrency") to your watchlist. You can manually enter the current price.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add Custom \(kind == .stock ? "Stock" : "Crypto")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let price = Double(priceText), !symbol.isEmpty, !name.isEmpty else { return }
                        marketData.addCustomAsset(symbol: symbol.uppercased(),
                                                  name: name,
                                                  price: price,
                                                  kind: kind,
                                                  exchange: "NYSE")
                        dismiss()
                    }
                    .disabled(symbol.isEmpty || name.isEmpty || priceText.isEmpty)
                }
            }
        }
    }
}
