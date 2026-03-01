//
//  StoreManager.swift
//  betterCam
//
//  Created by Rice on 2026/2/8.
//

import StoreKit
import Combine

class StoreManager: ObservableObject {
    @Published var products: [Product] = []
    @Published var isPurchasing: Bool = false
    var updateListenerTask: Task<Void, Error>? = nil // 持有引用
    
    @Published var hasPurchased: Bool = false

    // 在 init 中增加：
    
    init() {
        updateListenerTask = listenForTransactions()
        // 使用 Detached Task 并设置较高优先级
        Task(priority: .userInitiated) {
            await fetchProducts()
        }
    }
    
    // 获取商品信息
    @MainActor
    func fetchProducts() async {
        do {
            // 替换成你在 App Store Connect 定义的 ID
            let storeProducts = try await Product.products(for: ["com.ppschool.betterCam.buy_me_a_coffee_consumable"])
            print(storeProducts.count)
            self.products = storeProducts
        } catch {
            print("Failed to fetch products: \(error)")
        }
    }
    
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)
                    // 处理成功的后台交易
                    await transaction.finish()
                } catch {
                    print("Transaction update failed verification")
                }
            }
        }
    }
    
    // 执行购买
    func purchase() async -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }
        
        var retryCount = 0
            let maxRetries = 3 // 最多尝试 3 次
            
            while products.isEmpty && retryCount < maxRetries {
                print("⚠️ 尝试获取商品信息... 第 \(retryCount + 1) 次")
                await fetchProducts() // 调用你原有的获取方法
                
                if products.isEmpty {
                    // 如果还没拿到，等待 1 秒（给 App Store 服务器一点响应时间）
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    retryCount += 1
                }
            }
            
            // 3. 经过重试后再次检查
        guard let product = products.first else {
            print("❌ 经过重试仍无法获取商品，请检查网络或内购配置")
            return false
        }
        
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                return true
            case .userCancelled, .pending:
                print("userCancelled OR pending")
                return false
            @unknown default:
                print("Unknown!")
                return false
            }
        } catch {
            print("Error!", error)
            return false
        }
    }
    
    // 验证交易有效性
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    @MainActor
    func restorePurchases() async -> Bool {
        do {
            // 💡 使用 StoreKit 2 的同步方法
            try await AppStore.sync()
            return true
        } catch {
            print("Restore failed: \(error)")
            return false
        }
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
}

enum StoreError: Error {
    case failedVerification
}
