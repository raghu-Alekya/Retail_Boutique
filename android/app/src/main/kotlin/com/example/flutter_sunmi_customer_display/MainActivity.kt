package com.pinaka.boutique
//com.pinaka.pos

//com.pinakapos.alekta

import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
//import java.net.URL
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import org.json.JSONArray
import java.text.NumberFormat
import java.util.Locale
import android.content.Intent
import android.graphics.Paint
import android.graphics.Bitmap
import android.widget.EditText
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.GridLayout
import android.widget.Toast
import java.net.HttpURLConnection
import java.net.URL
import android.app.Dialog
import android.view.LayoutInflater

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.flutter_customer_display/sunmi_display"
    private var customerDisplayPresentation: CustomerDisplayPresentation? = null
    private var currentStoreId: String = ""
    private var currentStoreName: String = ""
    private var currentStoreLogoUrl: String? = null
    private var currentStoreBaseUrl: String = ""
    private val PAYMENT_CHANNEL = "sunmi_payment_channel"
    private var saleResultCallback: MethodChannel.Result? = null
    private var isOrderActive = false
    private var authToken: String = ""
    private var isShowingThankYou = false
//    private var redeemPointsTextView: TextView? = null


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d("CustomerDisplay", "🔧 configureFlutterEngine called")



        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            Log.d(
                "CustomerDisplay",
                "📢 MethodChannel call → method=${call.method}, args=${call.arguments}"
            )

            when (call.method) {

                "showWelcome" -> {
                    Log.d("CustomerDisplay", "➡ showWelcome invoked")
                    if (showWelcomeOnCustomerDisplay()) {
                        Log.d("CustomerDisplay", "✔ Welcome displayed")
                        result.success("Welcome shown")
                    } else {
                        Log.e("CustomerDisplay", "❌ No secondary display found for Welcome")
                        result.error("NO_DISPLAY", "No secondary display found", null)
                    }
                }

                "showWelcomeWithStore" -> {
                    val storeId = call.argument<String>("storeId") ?: ""
                    val storeName = call.argument<String>("storeName") ?: ""
                    val storeLogoUrl = call.argument<String>("storeLogoUrl")
                    val storeBaseUrl = call.argument<String>("storeBaseUrl") ?: ""

                    Log.d(
                        "CustomerDisplay",
                        "➡ showWelcomeWithStore invoked → storeId=$storeId, storeName=$storeName, logoUrl=$storeLogoUrl, baseUrl=$storeBaseUrl"
                    )

                    currentStoreId = storeId
                    currentStoreName = storeName
                    currentStoreLogoUrl = storeLogoUrl
                    currentStoreBaseUrl = storeBaseUrl

                    // --- Call the slideshow API first to see logs ---
                    if (customerDisplayPresentation == null) {
                        showWelcomeOnCustomerDisplay()
                    }

// ✅ Prevent override during active order
                    if (!isOrderActive) {

                        customerDisplayPresentation?.showWelcomeLayout(
                            storeId,
                            storeName,
                            storeLogoUrl,
                            storeBaseUrl
                        )

                    } else {

                        Log.d(
                            "CustomerDisplay",
                            "⛔ Skipping welcome update — order is active"
                        )
                    }

                    // --- Show Welcome layout on customer display ---
                    if (customerDisplayPresentation == null) {
                        showWelcomeOnCustomerDisplay()
                    }

// ✅ Prevent override during active order
                    if (!isOrderActive) {
                        customerDisplayPresentation?.showWelcomeLayout(
                            storeId,
                            storeName,
                            storeLogoUrl,
                            storeBaseUrl
                        )
                    } else {
                        Log.d("CustomerDisplay", "⛔ Skipping welcome update — order is active")
                    }

                    result.success("Welcome updated with store")
                }


                "showCustomerData" -> {

                    // BLOCK refresh while Thank You is active
                    if (isShowingThankYou) {
                        Log.d("CustomerDisplay", "⛔ Thank You active → skipping customer data update")
                        result.success("Skipped")
                        return@setMethodCallHandler
                    }
                    val orderId = call.argument<Int>("orderId") ?: 0
                    val items = call.argument<List<Map<String, Any>>>("items") ?: emptyList()
                    val grossTotal = call.argument<Double>("grossTotal") ?: 0.0
                    val discount = call.argument<Double>("discount") ?: 0.0
                    val merchantDiscount = call.argument<Double>("merchantDiscount") ?: 0.0
                    val netTotal = call.argument<Double>("netTotal") ?: 0.0
                    val tax = call.argument<Double>("tax") ?: 0.0
                    val netPayable = call.argument<Double>("netPayable") ?: 0.0
                    val orderDate = call.argument<String>("orderDate") ?: ""
                    val orderTime = call.argument<String>("orderTime") ?: ""
                    val cashbackFee = call.argument<Double>("cashbackFee") ?: 0.0
                    val loyaltyContact = call.argument<String>("loyaltyContact") ?: ""
                    val availablePoints = call.argument<Int>("availablePoints") ?: 0
                    val summaryEnabled = call.argument<Boolean>("summaryEnabled") ?: false
                    val redeemedAmount = call.argument<Double>("redeemedAmount") ?: 0.0

                    Log.d("CustomerDisplay", "☎ Loyalty Contact received: $loyaltyContact")

                    Log.d(
                        "CustomerDisplay",
                        "➡ showCustomerData invoked → orderId=$orderId, items=${items.size}, grossTotal=$grossTotal, discount=$discount, merchantDiscount=$merchantDiscount, netTotal=$netTotal, tax=$tax, netPayable=$netPayable"
                    )
                    Log.d("CustomerDisplay", "➡ orderDate='$orderDate'")
                    Log.d("CustomerDisplay", "➡ orderTime='$orderTime'")
                    val success = showDataOnCustomerDisplay(
                        orderId,
                        currentStoreId,
                        currentStoreName,
                        currentStoreLogoUrl,
                        items,
                        grossTotal,
                        discount,
                        merchantDiscount,
                        netTotal,
                        tax,
                        netPayable,
                        orderDate,
                        orderTime,
                        cashbackFee,
                        loyaltyContact,
                        availablePoints,
                        summaryEnabled,
                        redeemedAmount
                    )
                    if (success) {
                        Log.d("CustomerDisplay", "✔ Customer data displayed")
                        result.success("Data displayed")
                    } else {
                        Log.e("CustomerDisplay", "❌ No secondary display found for Customer data")
                        result.error("NO_DISPLAY", "No secondary display found", null)
                    }
                }

                "showThankYou" -> {
                    isShowingThankYou = true

                    Log.d("CustomerDisplay", "➡ showThankYou invoked")

                    if (showThankYouOnCustomerDisplay()) {
                        Log.d("CustomerDisplay", "✔ Thank You displayed")
                        result.success("Thank You shown")
                    } else {
                        isShowingThankYou = false
                        Log.e("CustomerDisplay", "❌ No secondary display found for Thank You")
                        result.error("NO_DISPLAY", "No secondary display found", null)
                    }
                }
                "enablePhoneInput" -> {
                    Handler(Looper.getMainLooper()).post {
                        customerDisplayPresentation?.enablePhoneInput()
                    }
                    result.success(true)
                }
                "customerDisplayResult" -> {

                    val success =
                        call.argument<Boolean>("success") ?: false

                    val message =
                        call.argument<String>("message") ?: ""

                    val points =
                        call.argument<Int>("points") ?: 0

                    val redeemedAmount =
                        call.argument<Double>("redeemedAmount") ?: 0.0

                    Log.d(
                        "CustomerDisplay",
                        "📥 customerDisplayResult → success=$success points=$points redeemedAmount=$redeemedAmount"
                    )

                    Handler(Looper.getMainLooper()).post {

                        if (!success) {

                            Toast.makeText(
                                this@MainActivity,
                                if (message.isNotEmpty())
                                    message
                                else
                                    "Something went wrong",
                                Toast.LENGTH_LONG
                            ).show()

                        } else {

                            // popup points
                            customerDisplayPresentation?.updateRedeemPopupPoints(points)

                            // header points DIRECT FROM API
                            customerDisplayPresentation?.updateHeaderPoints(points)

                            if (redeemedAmount > 0) {
                                customerDisplayPresentation?.showRedeemSummary(redeemedAmount)
                            } else {
                                customerDisplayPresentation?.restoreSummaryAfterRedeemRemoval()
                            }
                        }
                    }

                    result.success(true)
                }
                "resetDisplay" -> {
                    Log.d("CustomerDisplay", "🔥 resetDisplay called")

                    isOrderActive = false

                    customerDisplayPresentation?.resetCustomerLayoutState()

                    val displayManager =
                        getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

                    val displays = displayManager.displays

                    if (displays.size > 1) {
                        val secondaryDisplay = displays[1]

                        customerDisplayPresentation?.dismiss()

                        customerDisplayPresentation =
                            CustomerDisplayPresentation(
                                this@MainActivity,
                                this@MainActivity,
                                secondaryDisplay
                            )

                        customerDisplayPresentation?.show()

                        customerDisplayPresentation?.showWelcomeLayout(
                            currentStoreId,
                            currentStoreName,
                            currentStoreLogoUrl,
                            currentStoreBaseUrl
                        )
                    }

                    result.success("Display reset to welcome")
                }

                else -> {
                    Log.w("CustomerDisplay", "⚠ Method not implemented: ${call.method}")
                    result.notImplemented()
                }
            }
        }
        // ================= PAYMENT CHANNEL =================
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PAYMENT_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "startSale" -> {
                    val amount = call.argument<String>("amount")
                    val orderId = call.argument<String>("orderId")

                    val intent = Intent().apply {
                        setClassName(
                            "com.sunmi.payment.demo",
                            "com.sunmi.payment.demo.page.trans.SaleActivity"
                        )
                        putExtra("amount", amount)
                        putExtra("orderId", orderId)
                    }

                    saleResultCallback = result
                    startActivityForResult(intent, 9090)
                }

                "startVoid" -> {
                    val amount = call.argument<String>("amount")
                    val originOrderId = call.argument<String>("originOrderId")
                    val originTransactionId = call.argument<String>("originTransactionId")

                    Log.d(
                        "SunmiVoid",
                        "➡ startVoid → amount=$amount, originOrderId=$originOrderId, originTxn=$originTransactionId"
                    )

                    // ✅ Basic validation only
                    if (originOrderId.isNullOrEmpty() || originTransactionId.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing origin order or transaction ID", null)
                        return@setMethodCallHandler
                    }

                    val intent = Intent().apply {
                        setClassName(
                            "com.sunmi.payment.demo",
                            "com.sunmi.payment.demo.page.trans.VoidActivity"
                        )
                        putExtra("amount", amount)
                        putExtra("originOrderId", originOrderId)
                        putExtra("originTransactionId", originTransactionId)
                    }

                    saleResultCallback = result
                    startActivityForResult(intent, 9091)
                }


                else -> result.notImplemented()
            }
        }

    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == 9090 || requestCode == 9091) {

            if (resultCode == Activity.RESULT_OK) {
                val paymentResult = data?.getStringExtra("paymentResult")

                if (paymentResult != null) {
                    saleResultCallback?.success(paymentResult)
                } else {
                    saleResultCallback?.error("NO_RESULT", "No payment result", null)
                }
            } else {
                saleResultCallback?.error("CANCELLED", "Operation cancelled", null)
            }

            saleResultCallback = null
        }
    }

    override fun onResume() {
        super.onResume()
        Log.d("CustomerDisplay", "➡ onResume called")
//        showWelcomeOnCustomerDisplay()
    }

    private fun showWelcomeOnCustomerDisplay(): Boolean {

        // ✅ BLOCK welcome if order is active
        if (isOrderActive) {
            Log.d("CustomerDisplay", "⛔ Ignoring Welcome — Order is active")
            return true
        }

        val displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displays = displayManager.displays
        Log.d("CustomerDisplay", "Detected displays: ${displays.size}")

        return if (displays.size > 1) {
            val secondaryDisplay = displays[1]

            if (customerDisplayPresentation == null || customerDisplayPresentation?.display != secondaryDisplay) {
                customerDisplayPresentation?.dismiss()
                customerDisplayPresentation = CustomerDisplayPresentation(
                    this@MainActivity,
                    this@MainActivity,
                    secondaryDisplay
                )
                customerDisplayPresentation?.show()
            }
            true
        } else {
            Log.e("CustomerDisplay", "❌ No secondary display available")
            false
        }
    }

    private fun showDataOnCustomerDisplay(
        orderId: Int,
        storeId: String,
        storeName: String,
        storeLogoUrl: String?,
        items: List<Map<String, Any>>,
        grossTotal: Double,
        discount: Double,
        merchantDiscount: Double,
        netTotal: Double,
        tax: Double,
        netPayable: Double,
        orderDate: String,
        orderTime: String,
        cashbackFee: Double,
        loyaltyContact: String,
        availablePoints: Int,
        summaryEnabled: Boolean,
        redeemedAmount: Double
    ): Boolean {
        // 🔥 ADD THIS LINE HERE (FIRST LINE)
        isOrderActive = true


        if (customerDisplayPresentation == null) {
            Log.d("CustomerDisplay", "CustomerDisplayPresentation null, recreating display")

            val displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val displays = displayManager.displays

            if (displays.size > 1) {
                val secondaryDisplay = displays[1]
                customerDisplayPresentation = CustomerDisplayPresentation(
                    this@MainActivity,
                    this@MainActivity,
                    secondaryDisplay
                )
                customerDisplayPresentation?.show()
            }
        }

        customerDisplayPresentation?.updateCustomerData(
            orderId,
            storeId,
            storeName,
            storeLogoUrl,
            items,
            grossTotal,
            discount,
            merchantDiscount,
            netTotal,
            tax,
            netPayable,
            orderDate,
            orderTime,
            cashbackFee,
            loyaltyContact,
            availablePoints,
            summaryEnabled,
            redeemedAmount
        )

        Log.d("CustomerDisplay", "✔ CustomerDisplayPresentation updated with order #$orderId")

        return customerDisplayPresentation != null
    }


    private fun showThankYouOnCustomerDisplay(): Boolean {

        val displayManager =
            getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

        val displays = displayManager.displays

        Log.d(
            "CustomerDisplay",
            "Detected displays: ${displays.size} for Thank You"
        )

        return if (displays.size > 1) {

            val secondaryDisplay = displays[1]

            if (
                customerDisplayPresentation == null ||
                customerDisplayPresentation?.display != secondaryDisplay
            ) {
                customerDisplayPresentation?.dismiss()

                customerDisplayPresentation =
                    CustomerDisplayPresentation(
                        this@MainActivity,
                        this@MainActivity,
                        secondaryDisplay
                    )

                customerDisplayPresentation?.show()
            }

            isShowingThankYou = true
            customerDisplayPresentation?.showThankYouLayout()

            Handler(Looper.getMainLooper()).postDelayed({

                Log.d("CustomerDisplay", "Thank You timeout finished")

                isShowingThankYou = false
                isOrderActive = false

                customerDisplayPresentation?.resetCustomerLayoutState()

                MethodChannel(
                    flutterEngine?.dartExecutor?.binaryMessenger!!,
                    "com.example.flutter_customer_display/sunmi_display"
                ).invokeMethod("showNextActiveOrder", null)

            }, 5000)

            true

        } else {
            isShowingThankYou = false
            false
        }
    }
    override fun onDestroy() {
        Log.d("CustomerDisplay", "➡ onDestroy called, dismissing CustomerDisplayPresentation")
        customerDisplayPresentation?.dismiss()
        super.onDestroy()
    }

    // ---------------------- CustomerDisplayPresentation ----------------------
    class CustomerDisplayPresentation(
        private val mainActivity: MainActivity,
        context: Context,
        display: Display
    ) : Presentation(context, display) {
        private var firstOrderShown = false

        private lateinit var orderIdView: TextView
        private lateinit var pointsView: TextView

        private lateinit var itemsContainer: LinearLayout
        private lateinit var grossView: TextView
        private lateinit var discountView: TextView
        private lateinit var merchantDiscountView: TextView
        private lateinit var netTotalView: TextView
        private lateinit var taxView: TextView
        private lateinit var netPayableView: TextView
        private lateinit var welcomeText: TextView

        private lateinit var storeLogoView: ImageView
        private lateinit var storeInfoText: TextView

        private lateinit var paymentDate: TextView
        private lateinit var paymentTime: TextView
        private lateinit var totalItemsView: TextView

        private var currentStoreId: String = ""
        private var currentStoreName: String = ""
        private var currentStoreLogoUrl: String? = null
        private var currentStoreBaseUrl: String = ""
        private var cachedLogoBitmap: Bitmap? = null
        private var cachedLogoUrl: String? = null
        private val imageCache = mutableMapOf<String, Bitmap>()
        private val slideshowBitmapCache = mutableMapOf<String, Bitmap>()
        private var cachedSlideshowUrls = mutableListOf<String>()
        private var redeemedAmount = 0.0
        private var redeemPointsTextView: TextView? = null

        private var availablePoints = 0
        private var isCustomerLayoutActive = false
        private var isRedeemPopupOpen = false
        private var phoneInputUnlocked = false
        private var keepSummaryVisible = false
        private var currentDisplayedOrderId = -1


        private lateinit var slideshowContainer: LinearLayout

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            Log.d("CustomerDisplay", "➡ CustomerDisplayPresentation onCreate")
            setContentView(R.layout.welcome_layout)
            welcomeText = findViewById(R.id.welcome_text)
        }

        fun resetFirstOrderShown() {

            firstOrderShown = false

            Log.d(
                "CustomerDisplay",
                "🔄 firstOrderShown reset"
            )
        }
        fun updateHeaderPoints(points: Int) {
            Handler(Looper.getMainLooper()).post {

                availablePoints = points

                val headerPoints =
                    findViewById<TextView>(R.id.customer_points)

                if (headerPoints != null) {
                    headerPoints.text = points.toString()
                    headerPoints.visibility = View.VISIBLE
                    headerPoints.invalidate()
                    headerPoints.requestLayout()

                    Log.d(
                        "CustomerDisplay",
                        "HEADER POINTS UPDATED DIRECT FROM API = ${headerPoints.text}"
                    )
                } else {
                    Log.e(
                        "CustomerDisplay",
                        "customer_points header not found"
                    )
                }
            }
        }
        fun restoreSummaryAfterRedeemRemoval() {
            Handler(Looper.getMainLooper()).post {

                val summaryContainer =
                    findViewById<LinearLayout>(R.id.summary_container)

                val redeemRow =
                    findViewById<LinearLayout>(R.id.redeem_row)

                summaryContainer?.visibility = View.VISIBLE
                redeemRow?.visibility = View.GONE

                val currentNetText = netPayableView.text.toString()
                    .replace("Total :", "")
                    .replace("$", "")
                    .replace(",", "")
                    .trim()

                val currentNet = currentNetText.toDoubleOrNull() ?: 0.0

                val restoredNet = currentNet + redeemedAmount

                this.redeemedAmount = 0.0

                netPayableView.text = "Total : ${formatCurrency(restoredNet)}"

                Log.d(
                    "CustomerDisplay",
                    "Restored net payable = $restoredNet"
                )
            }
        }
        fun hideRedeemSummary() {

            Log.d("CustomerDisplay", "hideRedeemSummary called")

            this.redeemedAmount = 0.0
            val redeemRow =
                findViewById<LinearLayout>(R.id.redeem_row)

            val redeemValue =
                findViewById<TextView>(R.id.value_redeem_amount)

            redeemRow?.visibility = View.GONE
            redeemValue?.text = formatCurrency(0.0)
        }

        fun resetCustomerLayoutState() {
            isCustomerLayoutActive = false
            firstOrderShown = false
            isRedeemPopupOpen = false
            phoneInputUnlocked = false
            keepSummaryVisible = false
            this.redeemedAmount = 0.0
            currentDisplayedOrderId = -1

            Log.d("CustomerDisplay", "🔄 Customer layout state reset")
        }

        fun updateWelcomeWithStore(
            storeId: String,
            storeName: String,
            storeLogoUrl: String? = null,
            storeBaseUrl: String? = null // new param
        ) {
            stopSlideshow()
            currentStoreId = storeId
            currentStoreName = storeName
            currentStoreLogoUrl = storeLogoUrl
            currentStoreBaseUrl = storeBaseUrl ?: ""

            welcomeText.text =
                if (storeName.isNotEmpty()) "Welcome to $storeName" else "👋 Welcome to Pinaka"

            val footerText = findViewById<TextView>(R.id.footer_text)
            footerText?.visibility = if (storeName.isNotEmpty()) View.VISIBLE else View.GONE

            val logoView = findViewById<ImageView>(R.id.welcome_logo)
            if (!storeLogoUrl.isNullOrEmpty()) {
                Thread {
                    try {
                        val input = URL(storeLogoUrl).openStream()
                        val bitmap = BitmapFactory.decodeStream(input)
                        Handler(Looper.getMainLooper()).post {
                            logoView?.setImageBitmap(bitmap)
                            Log.d("CustomerDisplay", "✅ Welcome logo loaded from URL")
                        }
                    } catch (e: Exception) {
                        Handler(Looper.getMainLooper()).post {
                            logoView?.setImageResource(R.drawable.pinaka_logo)
                            Log.e("CustomerDisplay", "❌ Failed to load Welcome logo: ${e.message}")
                        }
                    }
                }.start()
            } else {
                logoView?.setImageResource(R.drawable.pinaka_logo)
                Log.d("CustomerDisplay", "✅ Using default Welcome logo")
            }

            if (storeName.isNotEmpty()) {
                loadSlideshowFromApi(currentStoreBaseUrl)
            }
        }

        private fun loadSlideshowFromApi(storeBaseUrl: String) {

            // ✅ Use cached slideshow immediately
            if (cachedSlideshowUrls.isNotEmpty()) {

                Log.d(
                    "CustomerDisplay",
                    "⚡ Using cached slideshow (${cachedSlideshowUrls.size} images)"
                )

                displaySlideshow(cachedSlideshowUrls)

                return
            }

            if (storeBaseUrl.isEmpty()) {

                Log.e(
                    "CustomerDisplay",
                    "❌ storeBaseUrl empty"
                )

                return
            }

            Thread {

                try {

                    val apiUrl =
                        "$storeBaseUrl/wp-content/plugins/pinaka-pos-wp/promotion_images.php"

                    val json = URL(apiUrl).readText()

                    val jsonArray = JSONArray(json)

                    val imageUrls = mutableListOf<String>()

                    for (i in 0 until jsonArray.length()) {

                        val obj = jsonArray.getJSONObject(i)

                        val url = obj.getString("url")

                        imageUrls.add(url)

                        // ✅ Preload bitmap into cache
                        if (!slideshowBitmapCache.containsKey(url)) {

                            try {

                                val bitmap = BitmapFactory.decodeStream(
                                    URL(url).openStream()
                                )

                                if (bitmap != null) {

                                    slideshowBitmapCache[url] = bitmap

                                    Log.d(
                                        "CustomerDisplay",
                                        "✅ Cached slide: $url"
                                    )
                                }

                            } catch (e: Exception) {

                                Log.e(
                                    "CustomerDisplay",
                                    "❌ Cache failed for $url"
                                )
                            }
                        }
                    }

                    cachedSlideshowUrls.clear()
                    cachedSlideshowUrls.addAll(imageUrls)

                    Handler(Looper.getMainLooper()).post {

                        displaySlideshow(cachedSlideshowUrls)
                    }

                } catch (e: Exception) {

                    Log.e(
                        "CustomerDisplay",
                        "❌ Slideshow API failed: ${e.message}"
                    )

                    Handler(Looper.getMainLooper()).post {

                        // ✅ fallback to cache
                        if (cachedSlideshowUrls.isNotEmpty()) {

                            displaySlideshow(cachedSlideshowUrls)
                        }
                    }
                }

            }.start()
        }

        private fun bindSlideshowViewSafely(): Boolean {

            return try {

                slideshowImageView =
                    findViewById(R.id.slideshow_image)

                true

            } catch (e: Exception) {

                Log.e(
                    "CustomerDisplay",
                    "❌ slideshow_image not found"
                )

                false
            }
        }

        private lateinit var slideshowImageView: ImageView
        private var slideshowUrls = listOf<String>()
        private var currentSlide = 0
        private var slideshowHandler: Handler? = null
        private val slideshowInterval = 3000L

        private fun displaySlideshow(imageUrls: List<String>) {

            slideshowImageView = findViewById(R.id.slideshow_image)

            slideshowUrls = imageUrls

            slideshowHandler?.removeCallbacksAndMessages(null)

            slideshowHandler = Handler(Looper.getMainLooper())

            startSlideshow()
        }

        private fun startSlideshow() {

            if (slideshowHandler == null) {
                slideshowHandler = Handler(Looper.getMainLooper())
            }

            slideshowHandler?.removeCallbacksAndMessages(null)

            slideshowHandler?.post(object : Runnable {

                override fun run() {

                    // ✅ No slides yet
                    if (slideshowUrls.isEmpty()) {

                        Log.d(
                            "CustomerDisplay",
                            "⚠ No slideshow images available"
                        )

                        slideshowHandler?.postDelayed(this, 1000)
                        return
                    }

                    // ✅ Safety
                    if (currentSlide >= slideshowUrls.size) {
                        currentSlide = 0
                    }

                    val url = slideshowUrls[currentSlide]

                    Log.d(
                        "CustomerDisplay",
                        "🖼 Showing slide: $url"
                    )

                    // ✅ ALWAYS get latest ImageView
                    try {

                        slideshowImageView =
                            findViewById(R.id.slideshow_image)

                    } catch (e: Exception) {

                        Log.e(
                            "CustomerDisplay",
                            "❌ slideshow_image missing"
                        )

                        slideshowHandler?.postDelayed(
                            this,
                            slideshowInterval
                        )

                        return
                    }

                    // ✅ Use cache first
                    val cachedBitmap = slideshowBitmapCache[url]

                    if (cachedBitmap != null) {

                        Handler(Looper.getMainLooper()).post {

                            slideshowImageView.setImageBitmap(
                                cachedBitmap
                            )

                            slideshowImageView.scaleType =
                                ImageView.ScaleType.CENTER_CROP
                        }

                        Log.d(
                            "CustomerDisplay",
                            "⚡ Loaded from cache"
                        )

                    } else {

                        // ✅ Download if not cached
                        Thread {

                            try {

                                val bitmap =
                                    BitmapFactory.decodeStream(
                                        URL(url).openStream()
                                    )

                                if (bitmap != null) {

                                    slideshowBitmapCache[url] =
                                        bitmap

                                    Handler(Looper.getMainLooper()).post {

                                        try {

                                            slideshowImageView =
                                                findViewById(
                                                    R.id.slideshow_image
                                                )

                                            slideshowImageView
                                                .setImageBitmap(bitmap)

                                            slideshowImageView.scaleType =
                                                ImageView.ScaleType.CENTER_CROP

                                            Log.d(
                                                "CustomerDisplay",
                                                "✅ Downloaded & cached slide"
                                            )

                                        } catch (e: Exception) {

                                            Log.e(
                                                "CustomerDisplay",
                                                "❌ Failed updating ImageView"
                                            )
                                        }
                                    }
                                }

                            } catch (e: Exception) {

                                Log.e(
                                    "CustomerDisplay",
                                    "❌ Failed to load slide: ${e.message}"
                                )
                            }

                        }.start()
                    }

                    // ✅ Next slide
                    currentSlide =
                        (currentSlide + 1) % slideshowUrls.size

                    // ✅ Continue slideshow
                    slideshowHandler?.postDelayed(
                        this,
                        slideshowInterval
                    )
                }
            })
        }

        fun showWelcomeLayout(
            storeId: String,
            storeName: String,
            storeLogoUrl: String?,
            storeBaseUrl: String? = null
        ) {
            Log.d("CustomerDisplay", "➡ Switching back to Welcome layout")

            Handler(Looper.getMainLooper()).post {
                isCustomerLayoutActive = false
                isRedeemPopupOpen = false
                firstOrderShown = false
                currentDisplayedOrderId = -1
                this.redeemedAmount = 0.0// IMPORTANT RESET

                setContentView(R.layout.welcome_layout)

                currentStoreId = storeId
                currentStoreName = storeName
                currentStoreLogoUrl = storeLogoUrl
                currentStoreBaseUrl = storeBaseUrl ?: ""

                welcomeText = findViewById(R.id.welcome_text)

                val footerText = findViewById<TextView>(R.id.footer_text)
                val logoView = findViewById<ImageView>(R.id.welcome_logo)
                slideshowImageView = findViewById(R.id.slideshow_image)

                welcomeText.text =
                    if (storeName.isNotEmpty()) "Welcome to $storeName"
                    else "👋 Welcome to Pinaka"

                footerText.visibility =
                    if (storeName.isNotEmpty()) View.VISIBLE
                    else View.GONE

                if (!storeLogoUrl.isNullOrEmpty()) {
                    Thread {
                        try {
                            val bitmap = BitmapFactory.decodeStream(URL(storeLogoUrl).openStream())

                            Handler(Looper.getMainLooper()).post {
                                logoView.setImageBitmap(bitmap)
                            }

                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                logoView.setImageResource(R.drawable.pinaka_logo)
                            }
                        }
                    }.start()
                } else {
                    logoView.setImageResource(R.drawable.pinaka_logo)
                }

                if (currentStoreBaseUrl.isNotEmpty() && storeName.isNotEmpty()) {
                    loadSlideshowFromApi(currentStoreBaseUrl)
                }
            }
        }


        fun formatCurrency(value: Double): String {
            val formatter = NumberFormat.getCurrencyInstance(Locale.US)

            return if (value < 0) {
                "-" + formatter.format(kotlin.math.abs(value))
            } else {
                formatter.format(value)
            }
        }

        private fun bindOrderViews() {
            orderIdView = findViewById(R.id.customer_order_id)
            pointsView = findViewById(R.id.customer_points)
            totalItemsView = findViewById(R.id.label_total_items)

            itemsContainer = findViewById(R.id.customer_items_container)
            grossView = findViewById(R.id.value_gross_total)
            discountView = findViewById(R.id.value_discount)
            merchantDiscountView = findViewById(R.id.value_merchant_discount)
            netTotalView = findViewById(R.id.value_net_total)
            taxView = findViewById(R.id.value_tax)
            netPayableView = findViewById(R.id.value_net_payable)

            storeLogoView = findViewById(R.id.store_logo)
            storeInfoText = findViewById(R.id.store_info_text)

            paymentDate = findViewById(R.id.payment_date)
            paymentTime = findViewById(R.id.payment_time)

            Log.d("CustomerDisplay", "✔ Customer order views bound")
        }
        private fun updateStoreInfo(
            storeId: String,
            storeName: String,
            storeLogoUrl: String?,
            orderDate: String,
            orderTime: String
        ) {

            storeInfoText.text = storeName

            paymentDate.text = orderDate
            paymentTime.text = orderTime

            // ✅ Always configure ImageView properly
            storeLogoView.scaleType =
                ImageView.ScaleType.FIT_CENTER

            storeLogoView.adjustViewBounds = true

            // ✅ Store logo available
            if (!storeLogoUrl.isNullOrEmpty()) {

                // ✅ Use cached bitmap
                if (
                    storeLogoUrl == cachedLogoUrl &&
                    cachedLogoBitmap != null
                ) {

                    storeLogoView.setImageBitmap(
                        cachedLogoBitmap
                    )

                    Log.d(
                        "CustomerDisplay",
                        "⚡ Using cached logo"
                    )

                } else {

                    cachedLogoUrl = storeLogoUrl

                    Thread {

                        try {

                            val input =
                                URL(storeLogoUrl).openStream()

                            val bitmap =
                                BitmapFactory.decodeStream(input)

                            if (bitmap != null) {

                                cachedLogoBitmap = bitmap

                                Handler(Looper.getMainLooper()).post {

                                    storeLogoView.setImageBitmap(bitmap)

                                    storeLogoView.scaleType =
                                        ImageView.ScaleType.FIT_CENTER

                                    Log.d(
                                        "CustomerDisplay",
                                        "✅ Logo loaded & cached"
                                    )
                                }

                            } else {

                                Handler(Looper.getMainLooper()).post {

                                    storeLogoView.setImageResource(
                                        R.drawable.pinaka_logo
                                    )

                                    storeLogoView.scaleType =
                                        ImageView.ScaleType.FIT_CENTER
                                }
                            }

                        } catch (e: Exception) {

                            Handler(Looper.getMainLooper()).post {

                                storeLogoView.setImageResource(
                                    R.drawable.pinaka_logo
                                )

                                storeLogoView.scaleType =
                                    ImageView.ScaleType.FIT_CENTER

                                Log.e(
                                    "CustomerDisplay",
                                    "❌ Failed loading store logo"
                                )
                            }
                        }

                    }.start()
                }

            } else {

                // ✅ Proper Pinaka fallback
                storeLogoView.setImageResource(
                    R.drawable.pinaka_logo
                )

                storeLogoView.scaleType =
                    ImageView.ScaleType.FIT_CENTER

                Log.d(
                    "CustomerDisplay",
                    "⚡ Showing default Pinaka logo"
                )
            }
        }
        fun enablePhoneInput() {
            Handler(Looper.getMainLooper()).post {

                val emailInput = findViewById<EditText>(R.id.email_input)
                val customKeypad = findViewById<GridLayout>(R.id.custom_keypad)

                if (emailInput == null || customKeypad == null) {
                    Log.e("CustomerDisplay", "emailInput/customKeypad not found")
                    return@post
                }

                // enable only after checkout
                phoneInputUnlocked = true

                emailInput.isEnabled = true
                emailInput.isFocusable = true
                emailInput.isFocusableInTouchMode = true
                emailInput.isClickable = true
                emailInput.isCursorVisible = true
                emailInput.showSoftInputOnFocus = false

                emailInput.setOnClickListener {
                    Log.d("CustomerDisplay", "Email clicked → opening keypad")
                    customKeypad.visibility = View.VISIBLE
                }

                emailInput.setOnTouchListener { _, _ ->
                    customKeypad.visibility = View.VISIBLE
                    false
                }

                Log.d("CustomerDisplay", "Phone input enabled after checkout")
            }
        }
        fun updateCustomerData(
            orderId: Int,
            storeId: String?,
            storeName: String?,
            storeLogoUrl: String?,
            items: List<Map<String, Any>>,
            grossTotal: Double,
            discount: Double,
            merchantDiscount: Double,
            netTotal: Double,
            tax: Double,
            netPayable: Double,
            orderDate: String,
            orderTime: String,
            cashbackFee: Double,
            loyaltyContact: String,
            availablePoints: Int,
            summaryEnabled: Boolean,
            redeemedAmount: Double
        ) {

            firstOrderShown = true
            this.redeemedAmount = redeemedAmount


// detect new order BEFORE popup check
            if (currentDisplayedOrderId != -1 &&
                currentDisplayedOrderId != orderId
            ) {
                Log.d(
                    "CustomerDisplay",
                    "🆕 New order detected → clearing redeem state"
                )

                this.redeemedAmount = 0.0
                isRedeemPopupOpen = false
                keepSummaryVisible = false

                hideRedeemSummary()
            }

            currentDisplayedOrderId = orderId
            keepSummaryVisible = summaryEnabled
//
//            keepSummaryVisible = summaryEnabled
//
//            if (!summaryEnabled) {
//                findViewById<LinearLayout>(R.id.summary_container)?.visibility = View.GONE
//                findViewById<LinearLayout>(R.id.redeem_row)?.visibility = View.GONE
//            }

// same order + popup open → skip refresh
            if (isRedeemPopupOpen) {
                Log.d(
                    "CustomerDisplay",
                    "Redeem popup open for same order → skip refresh"
                )
                return
            }
            val defaultStoreId = "STORE001"
            val defaultStoreName = "Pinaka"
            val defaultStoreLogoUrl: String? = null

            Log.d(
                "CustomerDisplay",
                "🟢 updateCustomerData() called → orderId=$orderId, items=${items.size}, gross=$grossTotal, tax=$tax, net=$netPayable"
            )


            currentStoreId = storeId?.takeIf { it.isNotEmpty() } ?: defaultStoreId
            currentStoreName = storeName?.takeIf { it.isNotEmpty() } ?: defaultStoreName
            currentStoreLogoUrl =
                storeLogoUrl?.takeIf { it?.isNotEmpty() == true } ?: defaultStoreLogoUrl

            Log.d("CustomerDisplay", "📱 Displaying Customer Contact: $loyaltyContact")
            val showDiscountDetails = summaryEnabled

//            if (!isCustomerLayoutActive && !isRedeemPopupOpen) {
//                setContentView(R.layout.customer_display_layout)
//                bindOrderViews()
//                isCustomerLayoutActive = true
//            }
//            setContentView(R.layout.customer_display_layout)
//            bindOrderViews()
            if (!isCustomerLayoutActive ||
                findViewById<EditText>(R.id.email_input) == null) {
                Log.d("CustomerDisplay", "➡ Switching to customer display layout")

                setContentView(R.layout.customer_display_layout)
                bindOrderViews()
                isCustomerLayoutActive = true
            } else {
                Log.d("CustomerDisplay", "➡ Reusing existing customer layout")
            }

// Control summary visibility
            val summaryContainer = findViewById<LinearLayout>(R.id.summary_container)
            val redeemRow = findViewById<LinearLayout>(R.id.redeem_row)

            // ================= CUSTOMER INPUT + CUSTOM KEYPAD =================
// ================= CUSTOMER INPUT + CUSTOM KEYPAD =================

            // ================= CUSTOMER INPUT + CUSTOM KEYPAD =================
            val emailInput = findViewById<EditText>(R.id.email_input)
            val customKeypad = findViewById<GridLayout>(R.id.custom_keypad)
            val addButton = findViewById<Button>(R.id.btn_add_customer)

// restore contact
            emailInput.setText(loyaltyContact)

// always prevent Android keyboard
            emailInput.showSoftInputOnFocus = false

            if (!phoneInputUnlocked) {
                // BEFORE CHECKOUT → FULLY DISABLE
                customKeypad.visibility = View.GONE

                emailInput.isEnabled = false
                emailInput.isFocusable = false
                emailInput.isFocusableInTouchMode = false
                emailInput.isClickable = false
                emailInput.isCursorVisible = false
                emailInput.isLongClickable = false
                emailInput.clearFocus()
                emailInput.setOnTouchListener { _, _ -> true } // block touch completely

                addButton.isEnabled = false
                addButton.alpha = 0.5f // optional disabled look

            } else {
                // AFTER CHECKOUT → ENABLE
                emailInput.isEnabled = true
                emailInput.isFocusable = false
                emailInput.isFocusableInTouchMode = false
                emailInput.isClickable = true
                emailInput.isCursorVisible = false
                emailInput.isLongClickable = false

                addButton.isEnabled = true
                addButton.alpha = 1f

                emailInput.setOnTouchListener { _, _ ->
                    Log.d("CustomerDisplay", "⌨ Custom keypad opened")
                    customKeypad.visibility = View.VISIBLE
                    true
                }
            }
// add button
            addButton.setOnClickListener {

                val customerValue =
                    emailInput.text.toString().trim()

                if (customerValue.isEmpty()) {
                    Toast.makeText(
                        context,
                        "Enter customer number",
                        Toast.LENGTH_SHORT
                    ).show()
                    return@setOnClickListener
                }

                Log.d(
                    "CustomerDisplay",
                    "ADD CLICKED: $customerValue"
                )

//                showRedeemPopup(customerValue)

                MethodChannel(
                    mainActivity.flutterEngine!!
                        .dartExecutor.binaryMessenger,
                    "com.example.flutter_customer_display/sunmi_display"
                ).invokeMethod(
                    "customerDisplayRedeemClicked",
                    mapOf(
                        "contact" to customerValue
                    )
                )
            }
// ======================================================
// APPEND FUNCTION
// ======================================================

            fun appendText(value: String) {

                val currentText =
                    emailInput.text.toString()

                emailInput.setText(currentText + value)

                emailInput.setSelection(
                    emailInput.text.length
                )
            }

// ======================================================
// REUSABLE KEY SETUP
// ======================================================

            fun setupKey(buttonId: Int, value: String) {

                findViewById<Button>(buttonId)
                    .setOnClickListener {

                        appendText(value)
                    }
            }

// ======================================================
// NUMBER KEYS
// ======================================================

            setupKey(R.id.key_0, "0")
            setupKey(R.id.key_1, "1")
            setupKey(R.id.key_2, "2")
            setupKey(R.id.key_3, "3")
            setupKey(R.id.key_4, "4")
            setupKey(R.id.key_5, "5")
            setupKey(R.id.key_6, "6")
            setupKey(R.id.key_7, "7")
            setupKey(R.id.key_8, "8")
            setupKey(R.id.key_9, "9")

// ======================================================
// SPECIAL KEYS
// ======================================================

//            setupKey(R.id.key_at, "@")
//            setupKey(R.id.key_dot, ".")
//            setupKey(R.id.key_space, " ")

// ======================================================
// ALPHABET KEYS
// ======================================================

//            setupKey(R.id.key_a, "a")
//            setupKey(R.id.key_b, "b")
//            setupKey(R.id.key_c, "c")
//            setupKey(R.id.key_d, "d")
//            setupKey(R.id.key_e, "e")
//            setupKey(R.id.key_f, "f")
//            setupKey(R.id.key_g, "g")
//            setupKey(R.id.key_h, "h")
//            setupKey(R.id.key_i, "i")
//            setupKey(R.id.key_j, "j")
//            setupKey(R.id.key_k, "k")
//            setupKey(R.id.key_l, "l")
//            setupKey(R.id.key_m, "m")
//            setupKey(R.id.key_n, "n")
//            setupKey(R.id.key_o, "o")
//            setupKey(R.id.key_p, "p")
//            setupKey(R.id.key_q, "q")
//            setupKey(R.id.key_r, "r")
//            setupKey(R.id.key_s, "s")
//            setupKey(R.id.key_t, "t")
//            setupKey(R.id.key_u, "u")
//            setupKey(R.id.key_v, "v")
//            setupKey(R.id.key_w, "w")
//            setupKey(R.id.key_x, "x")
//            setupKey(R.id.key_y, "y")
//            setupKey(R.id.key_z, "z")

// ======================================================
// BACKSPACE
// ======================================================

            findViewById<Button>(R.id.key_clear)
                .setOnClickListener {

                    val text =
                        emailInput.text.toString()

                    if (text.isNotEmpty()) {

                        val updated =
                            text.dropLast(1)

                        emailInput.setText(updated)

                        emailInput.setSelection(
                            emailInput.text.length
                        )
                    }
                }

// ======================================================
// DONE BUTTON
// ======================================================
            findViewById<Button>(R.id.key_done)
                .setOnClickListener {
                    customKeypad.visibility = View.GONE
                }
            // Update store info
            updateStoreInfo(
                currentStoreId,
                currentStoreName,
                currentStoreLogoUrl,
                orderDate,
                orderTime
            )

            // Slideshow
            slideshowImageView = findViewById(R.id.slideshow_image)
            if (currentStoreBaseUrl.isNotEmpty()) {

                Log.d("CustomerDisplay", "▶ Restarting slideshow")

                loadSlideshowFromApi(currentStoreBaseUrl)

            } else {

                slideshowImageView.setImageResource(R.drawable.pinaka_logo)

                slideshowImageView.scaleType =
                    ImageView.ScaleType.FIT_CENTER

                slideshowImageView.adjustViewBounds = true

                slideshowImageView.setBackgroundColor(Color.WHITE)
            }
//            val summaryContainer = findViewById<LinearLayout>(R.id.summary_container)
//            summaryContainer.visibility =
//                if (summaryEnabled) View.VISIBLE else View.GONE

            // -----------------------------------------------------
            // CASE A: Empty cart (items empty OR grossTotal = 0.0)
            // -----------------------------------------------------
            itemsContainer.removeAllViews()

            if (items.isEmpty() || grossTotal == 0.0) {
                Log.d("CustomerDisplay", "📢 Empty cart → hide summary")
                Log.d("CustomerDisplay", "🆔 EMPTY ORDER ID = $orderId")

                summaryContainer.visibility = View.GONE

                // ✅ ADD THIS LINE (CRITICAL)
                orderIdView.text = " #$orderId"

                // 🔲 Frame container
                val frameLayout = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER

                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.MATCH_PARENT
                    )

                    background = GradientDrawable().apply {
                        setColor(Color.WHITE)
                        setStroke(dpToPx(2), Color.LTGRAY)
                        cornerRadius = dpToPx(0).toFloat()
                    }

                    // ✅ SMALL, EVEN padding only
                    setPadding(
                        dpToPx(24),
                        dpToPx(24),
                        dpToPx(24),
                        dpToPx(24)
                    )
                }

                val emptyImage = ImageView(context).apply {
                    setImageResource(R.drawable.empty_cart)
                    scaleType = ImageView.ScaleType.CENTER_INSIDE
                    layoutParams = LinearLayout.LayoutParams(
                        dpToPx(180),
                        dpToPx(180)
                    ).apply {
                        setMargins(0, 0, 0, dpToPx(16))
                    }
                }

                val emptyMessage = TextView(context).apply {
                    text = "No items in the Order panel"
                    textSize = 28f
                    setTextColor(Color.BLACK)
                    gravity = Gravity.CENTER
                }

                frameLayout.addView(emptyImage)
                frameLayout.addView(emptyMessage)

                // ✅ Container centers frameLayout
                val container = FrameLayout(context).apply {
                    layoutParams = FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                    addView(
                        frameLayout,
                        FrameLayout.LayoutParams(
                            FrameLayout.LayoutParams.MATCH_PARENT,
                            FrameLayout.LayoutParams.MATCH_PARENT,
                            Gravity.CENTER
                        )
                    )
                }

                itemsContainer.addView(container)
                return
            }

            // -----------------------------------------------------
            // CASE B: Items exist but tax = 0.0 → hide summary
            // -----------------------------------------------------
//            summaryContainer.visibility =
//                if (summaryEnabled) View.VISIBLE else View.GONE
//            keepSummaryVisible = summaryEnabled
//
//            summaryContainer.visibility =
//                if (keepSummaryVisible)
//                    View.VISIBLE
//                else
//                    View.GONE
            // -----------------------------------------------------
            // Items exist → Show list
            // -----------------------------------------------------
            orderIdView.text = "#$orderId"
            this.availablePoints =
                if (availablePoints > 0) availablePoints else this.availablePoints

            pointsView.text = this.availablePoints.toString()

            Log.d(
                "CustomerDisplay",
                "HEADER POINTS = ${this.availablePoints}"
            )
            Log.d(
                "CustomerDisplay",
                "HEADER POINTS FROM updateCustomerData = ${availablePoints}"
            )
            itemsContainer.removeAllViews()

            var totalItemCount = 0
            val itemsHeader = findViewById<LinearLayout>(R.id.items_header)

// ✅ Show header only when real items exist
            val hasRealItems = items.any {
                val n = it["name"] as? String ?: ""
                !n.equals("Payout", true) && !n.equals("Cashback", true)
            }
            itemsHeader.visibility = if (hasRealItems) View.VISIBLE else View.GONE



            for ((index, item) in items.withIndex()) {

                val name = (item["name"] as? String) ?: ""

                val qty: Int = when {
                    item["qty"] is Number ->
                        (item["qty"] as Number).toInt()

                    item["quantity"] is Number ->
                        (item["quantity"] as Number).toInt()

                    item["items_count"] is Number ->
                        (item["items_count"] as Number).toInt()

                    item["itemCount"] is Number ->
                        (item["itemCount"] as Number).toInt()

                    item["count"] is Number ->
                        (item["count"] as Number).toInt()

                    item["item_count"] is Number ->
                        (item["item_count"] as Number).toInt()

                    item["qty"] != null ->
                        item["qty"].toString().toDoubleOrNull()?.toInt() ?: 1

                    item["quantity"] != null ->
                        item["quantity"].toString().toDoubleOrNull()?.toInt() ?: 1

                    item["items_count"] != null ->
                        item["items_count"].toString().toDoubleOrNull()?.toInt() ?: 1

                    item["itemCount"] != null ->
                        item["itemCount"].toString().toDoubleOrNull()?.toInt() ?: 1

                    item["count"] != null ->
                        item["count"].toString().toDoubleOrNull()?.toInt() ?: 1

                    item["item_count"] != null ->
                        item["item_count"].toString().toDoubleOrNull()?.toInt() ?: 1

                    else -> 1
                }

                val price =
                    (item["price"] as? Number)?.toDouble() ?: 0.0

                val originalPrice =
                    (item["original_price"] as? Number)?.toDouble() ?: price

                val discountValue =
                    (item["auto_discount"] as? Number)?.toDouble() ?: 0.0

                val discountType =
                    (item["discount_type"] as? String)?.trim() ?: ""

                val hasDiscount = discountValue > 0
                val originalTotal = price * qty
                val discountedTotal = originalTotal - discountValue

                // count total items
                if (!name.equals("Payout", true) &&
                    !name.equals("Cashback", true)
                ) {
                    totalItemCount += qty
                }
                Log.d(
                    "CustomerDisplay",
                    """
    🧮 CALC[$index]
      name          = $name
      qty           = $qty
      price         = $price
      discountValue = $discountValue
      discountType  = $discountType
    """.trimIndent()
                )


//                val hasDiscount = discountValue > 0
//                val originalTotal = price * qty
//                val discountedTotal = originalTotal - discountValue


//                // ✔ SAME CALCULATION
//                if (!name.equals("Payout", true) && !name.equals("Cashback", true)) {
//                    totalItemCount += qty
//                }

                // ================= ROW =================
                val row = LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dpToPx(12), dpToPx(8), dpToPx(12), dpToPx(8))
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                    setBackgroundColor(Color.WHITE)
                }

// ================= ITEM COLUMN (1.6f) =================
                val itemColumn = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1.6f)
                }

                val nameView = TextView(context).apply {
                    text = if (name.length > 26) "${name.take(26)}…" else name
                    textSize = 20f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(Color.BLACK)
                }
                itemColumn.addView(nameView)

                val rawType = discountType.trim().lowercase()

                val (displayText, displayColor) = when {
                    rawType.contains("mixmatch") || rawType.contains("mix_match") ->
                        "COMBO DISCOUNT" to Color.parseColor("#FF9800") // 🟠 Orange

                    rawType.contains("multipack") || rawType.contains("multi_pack") ->
                        "MULTIPACK DISCOUNT" to Color.parseColor("#2196F3") // 🔵 Blue

                    rawType.contains("auto") ->
                        "AUTO DISCOUNT" to Color.RED

                    else ->
                        rawType.uppercase() to Color.RED
                }


                if (hasDiscount && showDiscountDetails) {
                    val discountText = TextView(context).apply {
                        text = "$displayText -${formatCurrency(discountValue)}"
                        textSize = 14f
                        setTextColor(displayColor)
                    }
                    itemColumn.addView(discountText)
                }


// ================= QTY × PRICE (1.0f) =================
                val qtyPriceView = TextView(context).apply {
                    layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
                    gravity = Gravity.START   // 👈 move left
                    textSize = 18f
                    setTextColor(Color.DKGRAY)
                    text = if (
                        name.equals("Payout", true) ||
                        name.equals("Cashback", true)
                    ) "" else "$qty × ${formatCurrency(price)}"
                }

// ================= PRICE COLUMN (0.8f) =================
                val priceColumn = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.END
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    ).apply {
                        marginStart = dpToPx(6)
                    }
                }

                val finalPriceView = TextView(context).apply {
                    text = formatCurrency(
                        if (hasDiscount && showDiscountDetails) discountedTotal else originalTotal
                    )
                    textSize = 17f
                    setTypeface(typeface, Typeface.BOLD)
                    setTextColor(
                        if (name.equals("Payout", true)) Color.RED else Color.BLACK
                    )
                }
                priceColumn.addView(finalPriceView)

                if (hasDiscount && showDiscountDetails) {
                    val originalPriceView = TextView(context).apply {
                        text = formatCurrency(originalTotal)
                        textSize = 16f
                        setTextColor(Color.GRAY)
                        paintFlags = paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
                    }
                    priceColumn.addView(originalPriceView)
                }

// ================= ADD TO ROW =================
                row.addView(itemColumn)
                row.addView(qtyPriceView)
                row.addView(priceColumn)

                itemsContainer.addView(row)


//                // ================= ROW =================
//                val row = LinearLayout(context).apply {
//                    orientation = LinearLayout.HORIZONTAL
//                    gravity = Gravity.CENTER_VERTICAL
//                    setPadding(dpToPx(12), dpToPx(8), dpToPx(12), dpToPx(8))
//                    layoutParams = LinearLayout.LayoutParams(
//                        LinearLayout.LayoutParams.MATCH_PARENT,
//                        LinearLayout.LayoutParams.WRAP_CONTENT
//                    )
//                    setBackgroundColor(Color.WHITE)
//                }
//
//                // ================= ITEM COLUMN (1.5f) =================
//                val itemColumn = LinearLayout(context).apply {
//                    orientation = LinearLayout.HORIZONTAL
//                    gravity = Gravity.CENTER_VERTICAL
//                    layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1.5f)
//                }
//
//// ❌ Image removed from UI — no empty gap
//// (ImageView not added to itemColumn)
//
//// ================================================
//// IMAGE LOADING LOGIC (kept for future use)
//// ================================================
//                /*
//                val imageView = ImageView(context).apply {
//                    layoutParams = LinearLayout.LayoutParams(dpToPx(40), dpToPx(40))
//                        .apply { marginEnd = dpToPx(8) }
//                    scaleType = ImageView.ScaleType.CENTER_CROP
//                }
//
//                when {
//                    name.equals("Payout", true) -> imageView.setImageResource(R.drawable.ic_payout)
//                    name.equals("Coupon", true) -> imageView.setImageResource(R.drawable.ic_coupon)
//                    else -> {
//                        (item["image"] as? String)?.let { url ->
//                            Thread {
//                                try {
//                                    val bmp = BitmapFactory.decodeStream(URL(url).openStream())
//                                    Handler(Looper.getMainLooper()).post {
//                                        imageView.setImageBitmap(bmp)
//                                    }
//                                } catch (_: Exception) {
//                                    Handler(Looper.getMainLooper()).post {
//                                        imageView.setImageResource(R.drawable.custom)
//                                    }
//                                }
//                            }.start()
//                        }
//                    }
//                }
//
//                // To re-enable images later:
//                // itemColumn.addView(imageView)
//                */
//
//                val nameView = TextView(context).apply {
//                    text = if (name.length > 26) "${name.take(26)}…" else name
//                    textSize = 20f
//                    setTypeface(typeface, Typeface.BOLD)
//                    setTextColor(Color.BLACK)
//                }
//
////                itemColumn.addView(imageView)
//                itemColumn.addView(nameView)
//
//                // ================= QTY × PRICE COLUMN (1.0f) =================
//                val qtyPriceView = TextView(context).apply {
//                    layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
//                    gravity = Gravity.CENTER
//                    textSize = 18f
//                    setTextColor(Color.DKGRAY)
//                    text = when {
//                        name.equals("Payout", true) -> ""
//                        name.equals("Cashback", true) -> ""
//                        else -> "$qty × ${formatCurrency(price)}"
//                    }
//                }
//
//                // ================= TOTAL COLUMN (0.8f) =================
//                val totalView = TextView(context).apply {
//                    layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 0.8f)
//                    gravity = Gravity.END
//                    textSize = 17f
//                    setTypeface(typeface, Typeface.BOLD)
//
//                    // 🔥 Color rule for payout
//                    setTextColor(
//                        if (name.equals("Payout", true)) Color.RED
//                        else Color.BLACK
//                    )
//
//                    // ✅ THIS IS THE KEY CHANGE
//                    text = formatCurrency(
//                        if (discountValue > 0) discountedTotal else originalTotal
//                    )
//                }
//
//
//                // Add columns into row
//                row.addView(itemColumn)
//                row.addView(qtyPriceView)
//                row.addView(totalView)
//
//                itemsContainer.addView(row)

                // ================= DISCOUNT ROW =================
//                if (hasDiscount) {
//
//                    val discountLayout = LinearLayout(context).apply {
//                        orientation = LinearLayout.VERTICAL
//                        setPadding(dpToPx(12), 0, dpToPx(12), dpToPx(6))
//                    }
//
//                    // 🔸 Discount label (Combo Discount -$2.00)
//                    val discountText = TextView(context).apply {
//                        text = "$discountType -${formatCurrency(discountValue)}"
//                        textSize = 14f
//                        setTextColor(Color.parseColor("#E67E22")) // orange like screenshot
//                    }
//
//                    // 🔸 Original price (strike-through)
//                    val originalPriceText = TextView(context).apply {
//                        text = formatCurrency(originalPrice * qty)
//                        textSize = 14f
//                        setTextColor(Color.GRAY)
//                        paintFlags = paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
//                    }
//
//                    discountLayout.addView(discountText)
//                    discountLayout.addView(originalPriceText)
//
//                    itemsContainer.addView(discountLayout)
//                }


                // ===== Divider =====
                if (index < items.size - 1) {
                    itemsContainer.addView(View(context).apply {
                        layoutParams = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT,
                            1
                        )
                        setBackgroundColor(Color.LTGRAY)
                    })
                }
            }

// ================= TOTALS (UNCHANGED) =================
            grossView.text = formatCurrency(grossTotal)
            discountView.text = formatCurrency(-discount)
            totalItemsView.text = "Total Items : $totalItemCount"

            findViewById<TextView>(R.id.label_cashback_fee).text = "Cashback Fee"
            findViewById<TextView>(R.id.value_cashback_fee).text =
                formatCurrency(cashbackFee)

            merchantDiscountView.text = formatCurrency(-merchantDiscount)

            val calculatedNetTotal = grossTotal - discount
            netTotalView.text = formatCurrency(calculatedNetTotal)

            taxView.text = formatCurrency(tax)

            netPayableView.text = "Total : ${formatCurrency(netPayable)}"
// show redeem row separately
            if (summaryEnabled && this.redeemedAmount > 0) {
                showRedeemSummary(redeemedAmount)
            } else {
                redeemRow.visibility = View.GONE
            }

            paymentDate.text = orderDate
            paymentTime.text = orderTime
            paymentDate.setTextColor(Color.WHITE)
            paymentTime.setTextColor(Color.WHITE)

            if (!summaryEnabled) {
                summaryContainer.visibility = View.GONE
                redeemRow.visibility = View.GONE
            } else {
                summaryContainer.visibility = View.VISIBLE
                redeemRow.visibility =
                    if (redeemedAmount > 0) View.VISIBLE else View.GONE
            }

            Log.d(
                "CustomerDisplay",
                "✔ Order #$orderId totals updated, Total Items: $totalItemCount, Final Payable: $netPayable"
            )
        }
        private fun dpToPx(dp: Int): Int {
            return (dp * context.resources.displayMetrics.density).toInt()
        }

        fun showRedeemSummary(amount: Double) {

            Log.d("CustomerDisplay", "showRedeemSummary called amount=$amount")

            redeemedAmount = amount

            val summaryContainer = findViewById<LinearLayout>(R.id.summary_container)
            val redeemRow = findViewById<LinearLayout>(R.id.redeem_row)
            val redeemLabel = findViewById<TextView>(R.id.label_redeem_amount)
            val redeemValue = findViewById<TextView>(R.id.value_redeem_amount)

            summaryContainer?.visibility = View.VISIBLE
            redeemRow?.visibility = View.VISIBLE
            redeemLabel?.visibility = View.VISIBLE
            redeemValue?.visibility = View.VISIBLE

            redeemLabel?.text = "Redeemed Amount"
            redeemValue?.text = "-${formatCurrency(kotlin.math.abs(amount))}"

            // DEDUCT FROM NET PAYABLE
            val currentNetText = netPayableView.text.toString()
                .replace("Total :", "")
                .replace("$", "")
                .replace(",", "")
                .trim()

            val currentNet = currentNetText.toDoubleOrNull() ?: 0.0
            val updatedNet = (currentNet - amount).coerceAtLeast(0.0)

            netPayableView.text = "Total : ${formatCurrency(updatedNet)}"
        }
        fun updateRedeemPopupPoints(points: Int) {

            Handler(Looper.getMainLooper()).post {

                Log.d("CustomerDisplay", "UPDATING API POINTS = $points")

                this.availablePoints = points

                redeemPointsTextView?.let {
                    it.text = "Available Points: $points"
                    it.visibility = View.VISIBLE
                }

                pointsView.text = points.toString()
                pointsView.visibility = View.VISIBLE

                Log.d(
                    "CustomerDisplay",
                    "MAIN HEADER POINTS UPDATED = ${pointsView.text}"
                )
            }
        }
//        fun showRedeemPopup(contact: String) {
//            Handler(Looper.getMainLooper()).post {
//                isRedeemPopupOpen = true
//
//                val root = findViewById<FrameLayout>(android.R.id.content)
//
//                root.findViewWithTag<View>("redeem_popup")?.let {
//                    root.removeView(it)
//                }
//
//                val popupView = LayoutInflater.from(context).inflate(
//                    R.layout.redeem_popup_layout,
//                    root,
//                    false
//                )
//
//                popupView.tag = "redeem_popup"
//
//                redeemPointsTextView =
//                    popupView.findViewById<TextView>(R.id.txt_points)
//
//                redeemPointsTextView?.visibility = View.VISIBLE
//                redeemPointsTextView?.text = "Fetching points..."
//                popupView.findViewById<Button>(R.id.btn_ok)
//                    .setOnClickListener {
//                        isRedeemPopupOpen = false
//
//                        root.removeView(popupView)
//                        redeemPointsTextView = null
//
//                        MethodChannel(
//                            mainActivity.flutterEngine!!
//                                .dartExecutor.binaryMessenger,
//                            "com.example.flutter_customer_display/sunmi_display"
//                        ).invokeMethod(
//                            "customerDisplayPopupClosed",
//                            null
//                        )
//                    }
//                root.addView(popupView)
//            }
//        }
        fun showThankYouLayout() {
            isCustomerLayoutActive = false
            isRedeemPopupOpen = false

            setContentView(R.layout.thank_you_layout)

            slideshowImageView = findViewById(R.id.slideshow_image)

            val thankYouText = findViewById<TextView>(R.id.thank_you_text)
            val visitAgainText = findViewById<TextView>(R.id.visit_again_text)

            thankYouText.text = "Thank You!"
            visitAgainText.text = "Please Visit Again"

            if (currentStoreBaseUrl.isNotEmpty()) {

                Log.d(
                    "CustomerDisplay",
                    "▶ Loading Thank You slideshow"
                )

                loadSlideshowFromApi(currentStoreBaseUrl)

            } else {

                slideshowImageView.setImageResource(R.drawable.pinaka_logo)

                slideshowImageView.scaleType =
                    ImageView.ScaleType.FIT_CENTER

                slideshowImageView.adjustViewBounds = true

                slideshowImageView.setBackgroundColor(Color.WHITE)
            }
        }

        private fun stopSlideshow() {

            slideshowHandler?.removeCallbacksAndMessages(null)

            slideshowHandler = null

            currentSlide = 0

            Log.d("CustomerDisplay", "🛑 Slideshow stopped")
        }

        override fun onDetachedFromWindow() {

            super.onDetachedFromWindow()

            stopSlideshow()
        }
    }
}
