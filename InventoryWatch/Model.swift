//
//  Model.swift
//  InventoryWatch
//
//  Created by Worth Baker on 11/8/21.
//

import Foundation

struct JsonStore: Codable, Equatable {
    var storeName: String
    var storeNumber: String
    var city: String
}

struct Store: Equatable {
    let storeName: String
    let storeNumber: String
    let city: String
    let state: String
    
    var locationDescription: String {
        return [city, state].joined(separator: ", ")
    }
    
    let partsAvailability: [PartAvailability]
}

struct PartAvailability: Equatable {
    enum PickupAvailability: String {
        case available, unavailable, ineligible
    }
    
    let partNumber: String
    let availability: PickupAvailability
    
//    var descriptiveName: String? {
//        return SKUs[partNumber]
//    }
}

extension PartAvailability: Identifiable {
    var id: String {
        partNumber
    }
}

final class Model: ObservableObject {
    enum ModelError: Swift.Error {
        case couldNotGenerateURL
        case failedToParseJSON
    }
    
    @Published var availableParts: [(Store, [PartAvailability])] = []
    @Published var isLoading = false
    
    lazy private(set) var allStores: [JsonStore] = {
        var location = "Stores"
        var fileType = "json"
        if let path = Bundle.main.path(forResource: location, ofType: fileType) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let decoder = JSONDecoder()
                
                if let jsonStores = try? decoder.decode([JsonStore].self, from: data) {
                    return jsonStores
                } else {
                    return []
                }
                
            } catch {
                print(error)
                return []
            }
        } else {
            return []
        }
    }()
    
    private var preferredCountry: String {
        return UserDefaults.standard.string(forKey: "preferredCountry") ?? "US"
    }
    
    private var countryPathElement: String {
        let country = preferredCountry
        if country == "US" {
            return ""
        } else {
            return country + "/"
        }
    }
    
    private var preferredStoreNumber: String {
        return UserDefaults.standard.string(forKey: "preferredStoreNumber") ?? "R032"
    }
    
    private var preferredSKUs: Set<String> {
        guard let defaults = UserDefaults.standard.string(forKey: "preferredSKUs") else {
            return []
        }
        
        return defaults.components(separatedBy: ",").reduce(into: Set<String>()) { partialResult, next in
            partialResult.insert(next)
        }
    }
    
    lazy private(set) var skuData: SKUData = {
        let country = Countries[preferredCountry] ?? USData
        return SkuDataForCountry(country)
    }()
    
    private let isTest: Bool
    
    init(isTest: Bool = false) {
        self.isTest = isTest
    }
    
    func fetchLatestInventory() throws {
        guard !isTest else {
            return
        }
        
        isLoading = true
        
        let urlRoot = "https://www.apple.com/\(countryPathElement)shop/fulfillment-messages?"
        let query = generateQueryString()
        
        guard let url = URL(string: urlRoot + query) else {
            throw ModelError.couldNotGenerateURL
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            do {
                try self.parseStoreResponse(data)
            } catch {
                print(error)
            }
        }.resume()
    }
    
    private func parseStoreResponse(_ responseData: Data?) throws {
        guard let responseData = responseData else {
            throw ModelError.couldNotGenerateURL
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String : Any] else {
            throw ModelError.couldNotGenerateURL
        }
        
        guard
            let body = json["body"] as? [String: Any],
                let content = body["content"] as? [String: Any],
                let pickupMessage = content["pickupMessage"] as? [String: Any]
        else {
            throw ModelError.couldNotGenerateURL
        }
        
        guard let storeList = pickupMessage["stores"] as? [[String: Any]] else {
            throw ModelError.couldNotGenerateURL
        }
        
        let collectedStores: [Store] = storeList.compactMap { storeJSON in
            guard let name = storeJSON["storeName"] as? String else { return nil }
            guard let number = storeJSON["storeNumber"] as? String else { return nil }
            guard let state = storeJSON["state"] as? String else { return nil }
            guard let city = storeJSON["city"] as? String else { return nil }
            
            guard let partsAvailability = storeJSON["partsAvailability"] as? [String: [String: Any]] else { return nil }
            let parsedParts: [PartAvailability] = partsAvailability.values.compactMap { part in
                guard let partNumber = part["partNumber"] as? String else { return nil }
                guard
                    let availabilityString = part["pickupDisplay"] as? String,
                        let availability = PartAvailability.PickupAvailability(rawValue: availabilityString)
                else {
                    return nil
                }
                
                return PartAvailability(partNumber: partNumber, availability: availability)
            }
            
            return Store(storeName: name, storeNumber: number, city: city, state: state, partsAvailability: parsedParts)
        }
        
        try self.parseAvailableModels(from: collectedStores)
    }
    
    private func parseAvailableModels(from stores: [Store]) throws {
        let allAvailableModels: [(Store, [PartAvailability])] = stores.compactMap { store in
            let rv: [PartAvailability] = store.partsAvailability.filter { part in
                switch part.availability {
                case .available:
                    return true
                case .unavailable, .ineligible:
                    return false
                }
            }
            
            if rv.isEmpty {
                return nil
            } else {
                return (store, rv)
            }
        }
        
        DispatchQueue.main.async {
            self.availableParts = allAvailableModels
            self.isLoading = false
            
            var hasPreferredModel = false
            let preferredModels = self.preferredSKUs
            for model in allAvailableModels {
                for submodel in model.1 {
                    if hasPreferredModel == false && preferredModels.contains(submodel.partNumber) {
                        hasPreferredModel = true
                        break
                    }
                }
            }
            
            if !self.isTest {
                let message = self.generateNotificationText(from: allAvailableModels)
                NotificationManager.shared.sendNotification(title: hasPreferredModel ? "Preferred Model Found" : "Apple Store Invetory Found", body: message)
            }
        }
    }
    
    private func generateNotificationText(from data: [(Store, [PartAvailability])]) -> String {
        var collector: [String: Int] = [:]
        for (_, parts) in data {
            for part in parts {
                collector[part.partNumber, default: 0] += 1
            }
        }
        
        let combined: [String] = collector.reduce(into: []) { partialResult, next in
            let (key, value) = next
            let name = skuData.productName(forSKU: key) ?? key
            partialResult.append("\(name): \(value) found")
        }
        
        return combined.joined(separator: ", ")
    }
    
    private func generateQueryString() -> String {
        // let query = "parts.0=MKGR3LL%2FA&parts.1=MKGP3LL%2FA&parts.2=MKGT3LL%2FA&parts.3=MKGQ3LL%2FA&parts.4=MMQX3LL%2FA&parts.5=MKH53LL%2FA&parts.6=MK1E3LL%2FA&parts.7=MK183LL%2FA&parts.8=MK1F3LL%2FA&parts.9=MK193LL%2FA&parts.10=MK1H3LL%2FA&parts.11=MK1A3LL%2FA&parts.12=MK233LL%2FA&parts.13=MMQW3LL%2FA&parts.14=MYD92LL%2FA&searchNearby=true&store=R133"
        
        var queryItems: [String] = skuData.orderedSKUs
            .enumerated()
            .map { next in
                let count = next.offset
                let sku = next.element
                return "parts.\(count)=\(sku)"
            }
        
        queryItems.append("searchNearby=true")
        queryItems.append("store=\(preferredStoreNumber)")
        
        return queryItems.joined(separator: "&")
    }
    
    func productName(forSKU sku: String) -> String {
        return skuData.productName(forSKU: sku) ?? sku
    }
}

extension Model {
    static var testData: Model {
        let model = Model(isTest: true)
        
        let testParts: [PartAvailability] = [
            PartAvailability(partNumber: "MKGT3LL/A", availability: .available),
            PartAvailability(partNumber: "MKGQ3LL/A", availability: .available),
            PartAvailability(partNumber: "MMQX3LL/A", availability: .available),
        ]
        
        let testStores: [Store] = [
            Store(storeName: "Twenty Ninth St", storeNumber: "R452", city: "Boulder", state: "CO", partsAvailability: testParts),
            Store(storeName: "Flatirons Crossing", storeNumber: "R462", city: "Louisville", state: "CO", partsAvailability: testParts),
            Store(storeName: "Cherry Creek", storeNumber: "R552", city: "Denver", state: "CO", partsAvailability: testParts)
        ]
        
        model.availableParts = testStores.map { ($0, testParts) }
        return model
    }
}