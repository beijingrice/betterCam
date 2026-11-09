package com.ppschool.bettercam.billing

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.consumePurchase
import com.android.billingclient.api.queryProductDetails
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * StoreManager.swift on Google Play Billing: a consumable "buy me a coffee" tip.
 * Play product IDs must be lower case, so the iOS ID is lower-cased here; create the
 * same ID as an in-app product in Play Console.
 */
class StoreManager(context: Context) : PurchasesUpdatedListener {
    var isPurchasing by mutableStateOf(false)
        private set

    private val client = BillingClient.newBuilder(context)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .build()
    private var product: ProductDetails? = null
    @Volatile private var pending: CompletableDeferred<Boolean>? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private suspend fun connect(): Boolean {
        if (client.isReady) return true
        return suspendCancellableCoroutine { cont ->
            client.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (cont.isActive) cont.resume(result.responseCode == BillingClient.BillingResponseCode.OK)
                }

                override fun onBillingServiceDisconnected() {
                    if (cont.isActive) cont.resume(false)
                }
            })
        }
    }

    private suspend fun fetchProduct(): ProductDetails? {
        product?.let { return it }
        val params = QueryProductDetailsParams.newBuilder().setProductList(
            listOf(
                QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(PRODUCT_ID)
                    .setProductType(BillingClient.ProductType.INAPP)
                    .build()
            )
        ).build()
        val result = client.queryProductDetails(params)
        product = result.productDetailsList?.firstOrNull()
        return product
    }

    suspend fun purchase(activity: Activity): Boolean {
        if (isPurchasing) return false
        isPurchasing = true
        try {
            var details: ProductDetails? = null
            var retries = 0
            while (details == null && retries < 3) {
                if (connect()) details = fetchProduct()
                if (details == null) { delay(1000); retries++ }
            }
            if (details == null) {
                Log.w(TAG, "product unavailable after retries")
                return false
            }
            val deferred = CompletableDeferred<Boolean>()
            pending = deferred
            val flow = BillingFlowParams.newBuilder().setProductDetailsParamsList(
                listOf(BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(details).build())
            ).build()
            val launch = client.launchBillingFlow(activity, flow)
            if (launch.responseCode != BillingClient.BillingResponseCode.OK) return false
            return deferred.await()
        } finally {
            isPurchasing = false
            pending = null
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        val ok = result.responseCode == BillingClient.BillingResponseCode.OK
        val bought = purchases?.firstOrNull { it.purchaseState == Purchase.PurchaseState.PURCHASED }
        if (!ok || bought == null) {
            pending?.complete(false); return
        }
        scope.launch {
            val r = client.consumePurchase(ConsumeParams.newBuilder().setPurchaseToken(bought.purchaseToken).build())
            pending?.complete(r.billingResult.responseCode == BillingClient.BillingResponseCode.OK)
        }
    }

    fun close() = client.endConnection()

    companion object {
        private const val TAG = "StoreManager"
        const val PRODUCT_ID = "com.ppschool.bettercam.buy_me_a_coffee_consumable"
    }
}
