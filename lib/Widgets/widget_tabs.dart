import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:pinaka_pos/Database/storage/storage_provider.dart';
import 'package:isar/isar.dart';
import 'package:pinaka_pos/Database/isar_cache_entry.dart';
import 'package:provider/provider.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';

// Import your custom numpad
import '../Blocs/Assets/asset_bloc.dart';
import '../Blocs/Orders/order_bloc.dart';
import '../Blocs/Search/product_search_bloc.dart';
import '../Constants/misc_features.dart';
import '../Constants/text.dart';
import '../Database/assets_db_helper.dart';
import '../Database/db_helper.dart';
import '../Database/isar_service.dart';
import '../Database/order_panel_db_helper.dart';
import '../Helper/Extentions/theme_notifier.dart';
import '../Helper/api_response.dart';
import '../Helper/cashbackhelper.dart';
import '../Helper/customerdisplayhelper.dart';
import '../Helper/url_helper.dart';
import '../Models/Assets/asset_model.dart';
import '../Models/Orders/orders_model.dart';
import '../Models/Search/product_custom_item_model.dart' as model;
import '../Repositories/Assets/asset_repository.dart';
import '../Repositories/Orders/order_repository.dart';
import '../Repositories/Search/product_search_repository.dart';
import '../Utilities/svg_images_utility.dart';
import 'OrderPopupHelper.dart';
import 'widget_custom_num_pad.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class AppScreenTabWidget extends StatefulWidget {
  AppScreenTabWidget(
      {this.selectedTabIndex = 0,
      this.barcode = "",
      this.refreshOrderList,
      required this.scaffoldMessengerContext,
      super.key});
  int selectedTabIndex = 0;
  String barcode = "";
  final BuildContext scaffoldMessengerContext;
  final VoidCallback? refreshOrderList; // Callback to refresh order panel

  @override
  State<AppScreenTabWidget> createState() => _AppScreenTabWidgetState();
}

class _AppScreenTabWidgetState extends State<AppScreenTabWidget>
    with LayoutSelectionMixin {
  // Tab selection
  bool _isPayoutLoading = false;
  // bool _isCouponLoading = false;
  bool _isCashbackLoading = false;
  bool _isDiscountLoading = false;
  bool _isCustomItemLoading = false;
  final OrderHelper _orderHelper = OrderHelper(); // Add OrderHelper instance
  late OrderBloc orderBloc;
  late ProductBloc productBloc;
  int? orderId; // Store order ID
  double orderTotal = 0.0; // Store order total
  // Discount values
  String _discountValue = "0.00%";
  bool _isPercentageSelected = true;
  bool isPayoutEnabled = false;
  bool isCashbackEnabled = false;
  final FocusNode _barcodeFocusNode = FocusNode();
  // Coupon value
  String _couponCode = "";
  String _cashbackAmount = "";

  // Custom item values
  String _customItemName = "";
  String _customItemPrice = "";
  String _sku = "";
  List<TaxModel> _taxList = [];
  TaxModel? _selectedTax;
  bool _isTaxLoading = false;
  bool _isSkuGenerated = false;
  // Tax slab options
  late List<String> _taxSlabOptions = [];
  String _selectedTaxSlab = '';
  final AssetDBHelper _assetDBHelper = AssetDBHelper.instance;
  bool _isTaxAvailable = false;

  // Payout value
  String _payoutAmount = "";
  double _maxCashbackLimit = 0.0;
  late final OrderRepository _orderRepository;

  // Adding a separate state variable for selected tab
  late int _selectedTabIndex;
  // Map<String, dynamic>? _customItemTemplate;

  // Add after existing custom item variables
  List<Map<String, dynamic>> _categoriesList = [];
  String _selectedCategoryName = "Custom Product"; // default
  bool _isCategoriesLoading = false;

  // Text editing controllers
  final TextEditingController _customItemNameController =
      TextEditingController();
  final TextEditingController _customItemPriceController =
      TextEditingController();
  final TextEditingController _skuController = TextEditingController();

  // Focus nodes
  final FocusNode _nameFocusNode = FocusNode();

  bool _isTaxDropdownEnabled = true;

  // Add this boolean variable to track when user is entering item price
  bool _isEnteringItemPrice = false;
  bool _isAmountEntered = false;

  Map<String, dynamic>? _customItemTemplate;
  List<Map<String, dynamic>> _customItemsList = []; // ← NEW
  String _selectedCustomItemName = "Custom Item";

  static int _persistedTabIndex = 0;

  // Function to check if the item name is empty
  bool _isItemNameEmpty() {
    return _customItemNameController.text.trim().isEmpty;
  }

  /// Generate SKU only when name is set and SKU is still empty (e.g. not scanner-prefilled).
  bool _isGenerateSkuEnabled() {
    return !_isItemNameEmpty() && _skuController.text.trim().isEmpty;
  }

  String normalizeSku(String s) {
    return OrderHelper.normalizeSku(s);
  }
  void _restoreScannerFocus() {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        // Barcode scanning is handled globally (order panel listener).
        // Clearing focus prevents scanner Enter/key events from reopening dropdowns.
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });
  }
  Future<String> _getTokenFromDb() async {
    try {
      final db = await DBHelper.instance.database;
      final result = await db.query(
        AppDBConst.userTable,
        where:
            '${AppDBConst.userToken} IS NOT NULL AND ${AppDBConst.userToken} != ""',
        orderBy: '${AppDBConst.userId} DESC',
        limit: 1,
      );

      if (result.isNotEmpty) {
        final token = result.first[AppDBConst.userToken] as String;
        if (kDebugMode) print('🔑 Token fetched from DB for Custom Items');
        return token;
      } else {
        throw Exception('No active user token found');
      }
    } catch (e) {
      print("❌ Error getting token: $e");
      // Fallback to hardcoded token (as safety net)
      return '';
    }
  }

// ==================== FINAL FIXED: FETCH CUSTOM ITEM TEMPLATE ====================
  Future<void> _fetchCustomItemTemplate() async {
    try {
      // Initialize dynamic base URL
      await UrlHelper.initializeBaseUrl();

      final String token = await _getTokenFromDb();
      if (token.isEmpty) {
        print("⚠️ No token available");
        return;
      }

      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

      // Use wooBaseUrl + your exact query parameter
      final String fullUrl =
          '${UrlHelper.wooBaseUrl}products?custom_products=true';
      final uri = Uri.parse(fullUrl);

      final request = http.Request('GET', uri);
      request.headers.addAll(headers);

      if (kDebugMode) {
        print(" Fetching Custom Items → $uri");
      }

      final response = await request.send();

      if (response.statusCode == 200) {
        final String body = await response.stream.bytesToString();
        final List<dynamic> data = jsonDecode(body);

        if (data.isNotEmpty && mounted) {
          setState(() {
            _customItemTemplate = data.first as Map<String, dynamic>;
            _customItemsList = List<Map<String, dynamic>>.from(data);

            if (_customItemsList.isNotEmpty) {
              _selectedCustomItemName =
                  _customItemsList.first['name']?.toString() ?? "Custom Item";
              _customItemNameController.text = _selectedCustomItemName;
            }
          });

          print(
              "✅ Successfully Loaded ${_customItemsList.length} Custom Items");
          for (var item in _customItemsList) {
            print(
                "   → ${item['name']} (ID: ${item['id']}) | Tax: ${item['tax_percent']}%");
          }
        }
      } else {
        print(
            " Failed to load custom items: ${response.reasonPhrase} (Status: ${response.statusCode})");
      }
    } catch (e) {
      print("Error fetching custom item template: $e");
    }
  }

  // ==================== FETCH CATEGORIES WITH TAX ====================

  Future<void> _fetchCategoriesWithTax() async {
    try {
      await UrlHelper.initializeBaseUrl();

      final String token = await _getTokenFromDb();
      if (token.isEmpty) {
        print("⚠️ No token available for categories");
        return;
      }

      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

      final String fullUrl =
          '${UrlHelper.baseUrl}pinaka-pos/v1/categories/get-categories-with-tax';

      final uri = Uri.parse(fullUrl);

      final request = http.Request('GET', uri);
      request.headers.addAll(headers);

      if (kDebugMode) {
        print("Fetching Categories with Tax → $uri");
      }

      final response = await request.send();

      if (response.statusCode == 200) {
        final String body = await response.stream.bytesToString();
        final Map<String, dynamic> data = jsonDecode(body);

        if (data['status'] == 'success' &&
            data['categories'] is List &&
            mounted) {
          List<Map<String, dynamic>> allCategories =
              List<Map<String, dynamic>>.from(data['categories']);

          final filteredCategories = allCategories.where((cat) {
            final name = (cat['name']?.toString() ?? '').trim().toLowerCase();
            final slug = (cat['slug']?.toString() ?? '').trim().toLowerCase();

            return name != 'uncategorized' &&
                slug != 'uncategorized' &&
                name != 'default' &&
                slug != 'default';
          }).map((cat) {
            String taxSlug = cat['pos_tax_slug']?.toString() ?? '';
            if (taxSlug.isEmpty) {
              final rawTaxClass = cat['pos_tax_class']?.toString() ?? '';
              taxSlug = rawTaxClass.toLowerCase().replaceAll(' ', '-');
            }
            return {
              ...cat,
              'pos_tax_slug': taxSlug,
            };
          }).toList();

          setState(() {
            _categoriesList = filteredCategories;
            _selectedCategoryName = "Select Category";
          });

          print(
              "✅ Loaded ${_categoriesList.length} Categories (after filtering)");

          // 🔥 NEW: Print tax info for all categories
          for (var cat in _categoriesList) {
            print("📋 Category: ${cat['name']} | "
                "pos_tax_class: ${cat['pos_tax_class']} | "
                "pos_tax_percent: ${cat['pos_tax_percent']}");
          }
        }
      } else {
        print(" Failed to load categories: ${response.statusCode}");
      }
    } catch (e) {
      print(" Error fetching categories: $e");
    }
  }

  @override
  void initState() {
    _orderRepository = OrderRepository();
    orderBloc = OrderBloc(OrderRepository()); // Build #1.0.53
    productBloc = ProductBloc(ProductRepository());
    super.initState();
    _loadCashbackLimit();

    _customItemNameController.addListener(() {
      setState(() {
        _customItemName = _customItemNameController.text;

        // 🔥 FIX: re-enable tax + SKU when name entered
        _isTaxDropdownEnabled = _customItemName.trim().isNotEmpty;
        _isSkuGenerated = false; // reset SKU state for new item
      });
    });
    _customItemPriceController.addListener(() {
      _customItemPrice = _customItemPriceController.text;
    });
    _skuController.addListener(() {
      _sku = _skuController.text;
    });

    _loadOrderData(); // Load order data on initialization
    _loadTaxSlabs();
    _loadTaxes();
    // Initialize the selected tab index from widget
    _selectedTabIndex = _persistedTabIndex;

    //  NEW: Load Custom Item Template + List for Dropdown
    // Replace the old fetch block in initState with this:
    _fetchCustomItemTemplate(); // No .then() needed anymore
    _fetchCategoriesWithTax(); // ← NEW
  }

  Future<void> _loadTaxes() async {
    setState(() => _isTaxLoading = true);

    _taxList = await _orderRepository.getAllTaxes();

    setState(() => _isTaxLoading = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    ///It will load sku and text field both with barcode from scanner initially
    if (kDebugMode) {
      print(
          "WidgetTabs.didChangeDependencies assign text field with barcode value ${_skuController.text} = ${widget.barcode}");
    }
    //Build #1.0.234: Fixed Issue [SCRUM - 388] -> SKU Disappears After Device Keyboard is Hidden
    // Only set the barcode value if it's different from current value and not empty
    if (widget.barcode.isNotEmpty && _skuController.text != widget.barcode) {
      if (kDebugMode) {
        print(
            "WidgetTabs.didChangeDependencies assign text field with barcode value ${widget.barcode}");
      }
      _skuController.text = widget.barcode;
      _sku = widget.barcode;

      // Focus Name field after a scan
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_selectedTabIndex == 2 && _customItemName.isEmpty) {
          _nameFocusNode.requestFocus();
        }
      });

      _isTaxDropdownEnabled = true;

      if (kDebugMode) {
        print(
            "WidgetTabs.didChangeDependencies are text field and sku same?  ${_skuController.text} = $_sku");
      }
    } else {
      if (kDebugMode) {
        print("#### DEBUG 200 ${_skuController.text}, $_sku");
      }
    }
  }

  Future<void> _loadTaxSlabs() async {
    try {
      List<Tax> taxes = await _assetDBHelper.getTaxList();
      if (kDebugMode)
        print(
            "#### _loadTaxSlabs: Loaded ${taxes.length} taxes: ${taxes.map((t) => t.toMap()).toList()},  widget.barcode: -${widget.barcode},");
      setState(() {
        _taxSlabOptions = taxes.map((tax) => tax.name).toSet().toList();
        if (_taxSlabOptions.isNotEmpty) {
          _selectedTaxSlab = _taxSlabOptions.first;
          if (kDebugMode)
            print(
                "#### _loadTaxSlabs: Set selected tax slab to: $_selectedTaxSlab");
        } else {
          if (kDebugMode) print("#### _loadTaxSlabs: Tax slabs are empty");
          _selectedTaxSlab = ''; // Ensure reset if no options
        }
      });
    } catch (e) {
      if (kDebugMode) print("#### _loadTaxSlabs: Error loading tax slabs: $e");
      setState(() {
        _taxSlabOptions = [];
        _selectedTaxSlab = '';
      });
    }
  }

  @override
  void dispose() {
    _customItemNameController.dispose();
    _customItemPriceController.dispose();
    _skuController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _loadCashbackLimit() async {
    final config = await CashbackHelper.getCashbackConfig();

    if (config != null &&
        config["cash_back_service"] != null &&
        config["cash_back_service"]["max_cashback"] != null) {
      setState(() {
        _maxCashbackLimit = double.tryParse(
                config["cash_back_service"]["max_cashback"].toString()) ??
            0.0;
      });

      print("🟢 Loaded Max Cashback Limit = $_maxCashbackLimit");
    } else {
      print("❌ max_cashback NOT FOUND");
    }
  }

  // Fetch order ID and total from OrderHelper (use loadData for offline orders)
  Future<void> _loadOrderData() async {
    await _orderHelper.loadData();
    setState(() {
      orderId = _orderHelper.activeOrderId;
      if (kDebugMode) {
        print("####_loadOrderData, orderId: $orderId");
      }
      if (orderId != null) {
        final order =
            _orderHelper.orders.cast<Map<String, dynamic>>().where((o) {
          final oid = o['order_id'] ?? o['id'] ?? o[AppDBConst.orderServerId];
          return oid != null &&
              (oid == orderId || oid.toString() == orderId.toString());
        }).toList();
        if (order.isNotEmpty) {
          final o = order.first;
          orderTotal = (o['gross_total'] ??
                  o['net_payable'] ??
                  o['net_total'] ??
                  o[AppDBConst.orderTotal] ??
                  0.0) is num
              ? ((o['gross_total'] ??
                      o['net_payable'] ??
                      o['net_total'] ??
                      o[AppDBConst.orderTotal]) as num)
                  .toDouble()
              : 0.0;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return
        //backgroundColor: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier.primaryBackground : Colors.white,
        // const Color(0xFFF1F5F9),
        Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 2, 10),
      child: Container(
        decoration: BoxDecoration(
          color: themeHelper.themeMode == ThemeMode.dark
              ? ThemeNotifier.primaryBackground
              : Colors.white,
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? Color(0xFF1A1A1A)
                  : Color(0xFFE1E1E1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 5,
            )
          ],
        ),
        clipBehavior: Clip.antiAlias,
        // Ensures children conform to the rounded corners
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // Top Tabs
            _buildTabs(),

            // Content based on selected tab
            Expanded(
                child: ClipPath(
                    clipper:
                        ContentSideClipper(selectedIndex: _selectedTabIndex),
                    child: _buildTabContent())),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return ClipPath(
      clipper: TabSideClipper(selectedIndex: _selectedTabIndex),
      child: Container(
          width: MediaQuery.of(context).size.width * 0.12,
          decoration: BoxDecoration(
            color: themeHelper.themeMode == ThemeMode.dark
                ? ThemeNotifier.tabsBackground
                : Color(0xFFEAEDFF),
            // borderRadius: BorderRadius.circular(16.0),
          ),
          child: Column(
            //mainAxisAlignment: MainAxisAlignment.spaceAround,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildTab(
                0,
                SvgUtils.addDiscountIcon,
                "Merchant \nDiscounts",

                const Color(0xFF4C5F7D), // default = white for logo
                const Color(0xFF4C5F7D), // Foreground text color
                // Color(0xFF007BFF),      // icon color
                // Color(0xFF007BFF),    // text color
                // color: isSelected
                //     ? const Color(0xFFFFFFFF) // default = white
                //     : Colors.blue,          // selected = blue

                //themeHelper: themeHelper,
              ),
              const SizedBox(width: 10),
              if (_selectedTabIndex != 0 && _selectedTabIndex != 1)
                Divider(
                    height: 1,
                    thickness: 1,
                    indent: 10,
                    endIndent: 10,
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0xFF313441)
                        : Color(0xFF8EAAD8)),
              if (isCashbackEnabled)
              _buildTab(
                  1,
                  SvgUtils.cashbackIcon,
                  "Cashback",
                  // Color(0xFF55CBCD),    // icon color
                  // Color(0xFF55CBCD),     // text color
                  const Color(0xFF4C5F7D), // default = white for logo
                  const Color(0xFF4C5F7D)),
              const SizedBox(width: 10),
              if (_selectedTabIndex != 1 && _selectedTabIndex != 2)
                Divider(
                    height: 1,
                    thickness: 1,
                    indent: 10,
                    endIndent: 10,
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0xFF313441)
                        : Color(0xFF8EAAD8)),
              _buildTab(
                  2,
                  SvgUtils.addCustomItemIcon,
                  "Custom\nItem",
                  // Color(0xFF55709A),    // icon color
                  // Color(0xFF55709A),
                  const Color(0xFF4C5F7D), // default = white for logo
                  const Color(0xFF4C5F7D)),
              const SizedBox(width: 10),
              if (_selectedTabIndex != 2 && _selectedTabIndex != 3)
                Divider(
                    height: 1,
                    thickness: 1,
                    indent: 10,
                    endIndent: 10,
                    color: themeHelper.themeMode == ThemeMode.dark
                        ? Color(0xFF313441)
                        : Color(0xFF8EAAD8)),
              if (isPayoutEnabled)
              _buildTab(
                  3,
                  SvgUtils.addPayoutIcon,
                  "Payouts",
                  // Color(0xFFD93535),    // icon color
                  // Color(0xFFD93535),   // text color
                  const Color(0xFF4C5F7D), // default = white for logo
                  const Color(0xFF4C5F7D)),
            ],
          )),
    );
  }

  Widget _buildTab(
    int index,
    String svgPath,
    String text,
    Color iconColor,
    Color textColor,
  ) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    bool isSelected = _selectedTabIndex == index;
    final isDark = themeHelper.themeMode == ThemeMode.dark;

    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedTabIndex = index;
            _persistedTabIndex = index;
            if (index != 2) _isEnteringItemPrice = false;
          });
        },
        child: SizedBox(
          //height: 80,
          //width: 20,
          // adjust if needed (same for all tabs)

          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              //   color: isSelected
              //       ? (themeHelper.themeMode == ThemeMode.dark
              //       ? ThemeNotifier.primaryBackground
              //       : Colors.white) // this will set the card background
              //       : (themeHelper.themeMode == ThemeMode.dark
              //       ? ThemeNotifier.tabsBackground
              //       : ThemeNotifier.tabsLightBackground),
              //   borderRadius: BorderRadius.circular(16.0),
              // ),//**8Raghu modified the code below, with blue cards when selected it shows white

              color: isSelected
                  ? (isDark
                      ? const Color(
                          0xFF2A2D3E) // 🔹 dark selected (you can tweak)
                      : const Color(0xFFFFFFFF)) // 🔹 light selected
                  : (isDark
                      ? const Color(0xFF1F1D2B) // 🔹 dark unselected
                      : const Color(0xFFECF1FF)), // 🔹 light unselected
              //borderRadius: BorderRadius.circular(2.0),
              /// borderRadius: BorderRadius.circular(0), // REMOVE rounded corners for now
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SvgPicture.asset(
                  svgPath,
                  height: 32,
                  width: 32,
                  colorFilter: ColorFilter.mode(
                    isDark
                        ? (isSelected ? Colors.white : Colors.white70)
                        : (isSelected ? iconColor : iconColor.withOpacity(0.8)),
                    BlendMode.srcIn,
                  ),
                ),
                const SizedBox(width: 5),
                //Padding(
                // padding: const EdgeInsets.only(right: 8, top: 3),
                //child:
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark
                        ? Colors.white
                        : textColor, // keep your existing color for light mode
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTabIndex) {
      case 0:
        return _buildDiscountsTab();
      case 1:
        return isCashbackEnabled
            ? _buildCashbackTab()
            : const SizedBox();
      case 2:
        return _buildCustomItemTab(context);
      case 3:
        return isPayoutEnabled
            ? _buildPayoutsTab()
            : const SizedBox();
      default:
        return const SizedBox();
    }
  }

  // DISCOUNTS TAB
  Widget _buildDiscountsTab() {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        children: [
          // 🏷 Title
          Text(
            TextConstants.applyDiscountToSale,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.textDark
                  : const Color(0xFF1E2745),
            ),
          ),

          const SizedBox(height: 20),

          // 🔘 Toggle Between % / ₹
          _buildDiscountToggle(),

          const SizedBox(height: 20),

          // 💬 Discount Entry Field (Styled like payout, centered)
          Container(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 12,
            margin: const EdgeInsets.only(top: 10),
            child: TextField(
              readOnly: true,
              textAlign: TextAlign.center,
              // ✅ Center alignment
              controller: TextEditingController(
                text: _isPercentageSelected
                    ? "${_discountValue.replaceAll('%', '')}%"
                    : "${TextConstants.currencySymbol}${_discountValue.replaceAll(TextConstants.currencySymbol, '')}",
              ),
              style: TextStyle(
                fontSize: 24,

                // ✔ Bold only when non-zero
                fontWeight: (() {
                  final clean = _discountValue
                      .replaceAll('%', '')
                      .replaceAll(TextConstants.currencySymbol, '');
                  return (clean == "0.00" || clean.isEmpty)
                      ? FontWeight.normal
                      : FontWeight.bold;
                })(),

                // ✔ Light grey when zero or empty
                color: (() {
                  final clean = _discountValue
                      .replaceAll('%', '')
                      .replaceAll(TextConstants.currencySymbol, '');
                  return (clean == "0.00" || clean.isEmpty)
                      ? Colors.grey.shade400
                      : (themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.textDark
                          : const Color(0xFF1E2745));
                })(),
              ),

              decoration: InputDecoration(
                filled: true,
                fillColor: themeHelper.themeMode == ThemeMode.dark
                    ? ThemeNotifier.paymentEntryContainerColor
                    : Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 🔢 Custom Numpad
          SizedBox(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 2.85,
            child: CustomNumPad(
              onDigitPressed: (digit) {
                setState(() {
                  String cleanValue = _discountValue
                      .replaceAll('%', '')
                      .replaceAll(TextConstants.currencySymbol, '')
                      .trim();

                  int rawValue =
                      ((double.tryParse(cleanValue) ?? 0.0) * 100).round();

                  // ✅ Handle both "digit" and "00" properly like payout tab
                  if (digit == '00') {
                    rawValue = (rawValue * 100) % 100000000;
                  } else {
                    int d = int.tryParse(digit) ?? 0;
                    rawValue = (rawValue * 10 + d) % 100000000;
                  }

                  double displayValue = rawValue / 100.0;
                  _discountValue = displayValue.toStringAsFixed(2);

                  if (_isPercentageSelected) {
                    _discountValue = "$_discountValue%";
                  }
                });
              },
              onDeletePressed: () {
                setState(() {
                  String cleanValue = _discountValue
                      .replaceAll('%', '')
                      .replaceAll(TextConstants.currencySymbol, '')
                      .trim();

                  int rawValue =
                      ((double.tryParse(cleanValue) ?? 0.0) * 100).round();
                  rawValue = rawValue ~/ 10;

                  double displayValue = rawValue / 100.0;
                  _discountValue = displayValue.toStringAsFixed(2);

                  if (_isPercentageSelected) {
                    _discountValue = "$_discountValue%";
                  }
                });
              },
              onClearPressed: () {
                setState(() {
                  _discountValue = "0.00";
                  if (_isPercentageSelected) {
                    _discountValue = "0.00%";
                  }
                });
              },
              actionButtonType: ActionButtonType.add,
              onAddPressed: _handleAddDiscount,
              isLoading: _isDiscountLoading,
              isDarkTheme: themeHelper.themeMode == ThemeMode.dark,
              numPadType: NumPadType.payment,
              showAddInsteadOfPay: true,
            ),
          ),
        ],
      ),
    );
  }

  // COUPONS TAB
  // Widget _buildCouponsTab() {
  //   final themeHelper = Provider.of<ThemeNotifier>(context);
  //   return Padding(
  //     padding: const EdgeInsets.only(top: 20),
  //     child: Column(
  //       children: [
  //         // Title
  //         Text(
  //           TextConstants.enterCouponCode,
  //           style: TextStyle(
  //             fontSize: 20,
  //             fontWeight: FontWeight.bold,
  //             color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier
  //                 .textDark : Color(0xFF1E2745),
  //           ),
  //         ),
  //
  //         const SizedBox(height: 20),
  //
  //         // Coupon Code Display
  //         Container(
  //           width: MediaQuery
  //               .of(context)
  //               .size
  //               .width / 2.75,
  //           height: MediaQuery
  //               .of(context)
  //               .size
  //               .height / 12,
  //           padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
  //           decoration: BoxDecoration(
  //             color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier
  //                 .paymentEntryContainerColor : Colors.white,
  //             borderRadius: BorderRadius.circular(10),
  //             border: Border.all(
  //                 color: themeHelper.themeMode == ThemeMode.dark ? ThemeNotifier
  //                     .secondaryBackground : Colors.grey.shade300),
  //           ),
  //           alignment: Alignment.center,
  //           child: Text(
  //             _couponCode.isEmpty ? "Ex: 123456789" : _couponCode,
  //             // Build #1.0.53 : updated code
  //             style: TextStyle(
  //               fontSize: 24,
  //               fontWeight: FontWeight.bold,
  //               color: _couponCode.isEmpty ? Colors.grey : themeHelper
  //                   .themeMode == ThemeMode.dark
  //                   ? ThemeNotifier.textDark
  //                   : const Color(0xFF1E2745),
  //             ),
  //           ),
  //         ),
  //
  //         const SizedBox(height: 20),
  //
  //         // Custom Numpad
  //         SizedBox(
  //           width: MediaQuery
  //               .of(context)
  //               .size
  //               .width / 2.75,
  //           height: MediaQuery
  //               .of(context)
  //               .size
  //               .height / 2.25,
  //           child: CustomNumPad(
  //             onDigitPressed: (digit) {
  //               setState(() {
  //                 _couponCode += digit;
  //               });
  //             },
  //             onClearPressed: () {
  //               setState(() {
  //                 _couponCode = "";
  //               });
  //             },
  //             onDeletePressed: () { // Build #1.0.53 : updated code
  //               setState(() {
  //                 _couponCode = _couponCode.isNotEmpty ? _couponCode.substring(
  //                     0, _couponCode.length - 1) : "";
  //               });
  //             },
  //             actionButtonType: ActionButtonType.add,
  //             onAddPressed: _handleAddCoupon,
  //             isLoading: _isCouponLoading,
  //             isDarkTheme: true,
  //             numPadType: NumPadType.payment,
  //             showAddInsteadOfPay: true,
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  Widget _buildCashbackTab() {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        children: [
          Text(
            TextConstants.addCashbackAmount,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.textDark
                  : const Color(0xFF1E2745),
            ),
          ),
          const SizedBox(height: 10),
          // ⭐ MAX Cashback Info (from backend)
          if (_maxCashbackLimit > 0)
            Column(
              children: [
                Text(
                  "Max Allowed Cashback: ${TextConstants.currencySymbol}${_maxCashbackLimit.toStringAsFixed(2)}",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
              ],
            ),

          // 💰 Payout Display
          Container(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 12,
            margin: const EdgeInsets.only(top: 10),
            child: TextField(
              readOnly: true,
              controller: TextEditingController(
                // ✅ Add the symbol only here
                text:
                    "${TextConstants.currencySymbol}${_cashbackAmount.isEmpty ? "0.00" : _cashbackAmount}",
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight:
                    _isAmountEntered ? FontWeight.bold : FontWeight.normal,
                color: _cashbackAmount.isEmpty
                    ? Colors.grey.shade400
                    : themeHelper.themeMode == ThemeMode.dark
                        ? ThemeNotifier.textDark
                        : const Color(0xFF1E2745),
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: themeHelper.themeMode == ThemeMode.dark
                    ? ThemeNotifier.paymentEntryContainerColor
                    : Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 🔢 Custom Numpad
          SizedBox(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 2.25,
            child: CustomNumPad(
              onDigitPressed: (digit) {
                setState(() {
                  // Clean numeric part only
                  String cleanValue =
                      _cashbackAmount.replaceAll(',', '').trim();
                  int rawAmount =
                      ((double.tryParse(cleanValue) ?? 0.0) * 100).round();

                  if (digit == '00') {
                    rawAmount = (rawAmount * 100) % 100000000;
                  } else {
                    int d = int.tryParse(digit) ?? 0;
                    rawAmount = (rawAmount * 10 + d) % 100000000;
                  }

                  double displayValue = rawAmount / 100.0;
                  _cashbackAmount =
                      displayValue.toStringAsFixed(2); // ✅ no symbol
                  _isAmountEntered = rawAmount != 0;
                });
              },
              onDeletePressed: () {
                setState(() {
                  String cleanValue =
                      _cashbackAmount.replaceAll(',', '').trim();
                  int rawAmount =
                      ((double.tryParse(cleanValue) ?? 0.0) * 100).round();
                  rawAmount = rawAmount ~/ 10;

                  double displayValue = rawAmount / 100.0;
                  _cashbackAmount =
                      displayValue.toStringAsFixed(2); // ✅ no symbol
                  _isAmountEntered = rawAmount != 0;
                });
              },
              onClearPressed: () {
                setState(() {
                  _cashbackAmount = "0.00"; // ✅ no symbol
                  _isAmountEntered = false;
                });
              },
              actionButtonType: ActionButtonType.add,
              onAddPressed: _handleCashbackpayout,
              isLoading: _isCashbackLoading,
              numPadType: NumPadType.payment,
              showAddInsteadOfPay: true,
              isDarkTheme: themeHelper.themeMode == ThemeMode.dark,
            ),
          ),
        ],
      ),
    );
  }

// CUSTOM ITEM TAB - WITH DROPDOWN (Enhanced UI)
// ============================================================
// REPLACE ONLY the _buildCustomItemTab method in your file.
// All logic, functions, variables remain UNCHANGED.
// Only UI layout is modified to match the discount tab style.
// ============================================================

  Widget _buildCustomItemTab(BuildContext context) {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          // ── Title ──────────────────────────────────────────────
          Text(
            TextConstants.customItem,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.textDark
                  : const Color(0xFF1E2745),
            ),
          ),

          const SizedBox(height: 20),

          // ── Row: Name Dropdown + Category Dropdown ─────────────
          SizedBox(
            width: MediaQuery.of(context).size.width / 2.75,
            child: Row(
              children: [
                // Name Dropdown
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        TextConstants.nameText,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.textDark
                              : const Color(0xFF1E2745),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: MediaQuery.of(context).size.height / 14,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.paymentEntryContainerColor
                              : Colors.white,
                          border: Border.all(
                            color: const Color(0xFF1E2745),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(
                          value: _selectedCustomItemName,
                          isExpanded: true,
                          underline: const SizedBox(),
                          icon: const Icon(Icons.arrow_drop_down, size: 20),
                          style: TextStyle(
                            fontSize: 14,
                            color: themeHelper.themeMode == ThemeMode.dark
                                ? ThemeNotifier.textDark
                                : const Color(0xFF1E2745),
                          ),
                          dropdownColor: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.primaryBackground
                              : Colors.white,
                          items: _customItemsList.map((item) {
                            final name =
                                item['name']?.toString() ?? "Custom Item";
                            return DropdownMenuItem<String>(
                              value: name,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (newValue) {
                            if (newValue != null) {
                              setState(() {
                                _selectedCustomItemName = newValue;
                                _customItemNameController.text = newValue;
                                _selectedCategoryName = "Select Category";
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 10),

                // === FIXED & CLEAN CATEGORY DROPDOWN ===
                // === FIXED & CLEAN CATEGORY DROPDOWN ===
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Category",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.textDark
                              : const Color(0xFF1E2745),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: MediaQuery.of(context).size.height / 14,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.paymentEntryContainerColor
                              : Colors.white,
                          border: Border.all(
                            color: const Color(0xFF1E2745),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(

                          value: (_categoriesList.isEmpty ||
                              _selectedCategoryName == "Select Category" ||
                              !_categoriesList.any((cat) =>
                              cat['name']?.toString().trim() == _selectedCategoryName.trim()))
                              ? "Select Category"
                              : _selectedCategoryName,

                          isExpanded: true,
                          underline: const SizedBox(),
                          icon: const Icon(Icons.arrow_drop_down, size: 20),
                          style: TextStyle(
                            fontSize: 14,
                            color: themeHelper.themeMode == ThemeMode.dark
                                ? ThemeNotifier.textDark
                                : const Color(0xFF1E2745),
                          ),
                          dropdownColor: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.primaryBackground
                              : Colors.white,

                          items: [
                            // Placeholder
                            const DropdownMenuItem<String>(
                              value: "Select Category",
                              child: Text(
                                "Select Category",
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                            ..._categoriesList.map((cat) {
                              final name = cat['name']?.toString() ?? "";
                              final tax = cat['pos_tax_percent']?.toString() ?? "0";
                              return DropdownMenuItem<String>(
                                value: name,
                                child: Text(
                                  "$name ($tax%)",
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15),
                                ),
                              );
                            }).toList(),
                          ],
                            onChanged: (newValue) {
                              if (newValue == null || newValue == "Select Category") return;

                              setState(() {
                                _selectedCategoryName = newValue;
                              });

                              _restoreScannerFocus(); // IMPORTANT
                            }                        ),
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),


          const SizedBox(height: 20),

          // ── Item Price Display (centered, styled like discount field) ──
          Container(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 12,
            margin: const EdgeInsets.only(top: 10),
            child: TextField(
              readOnly: true,
              textAlign: TextAlign.center,
              controller: _customItemPriceController,
              style: TextStyle(
                fontSize: 24,
                fontWeight:
                    _isEnteringItemPrice ? FontWeight.bold : FontWeight.normal,
                color: !_isEnteringItemPrice
                    ? Colors.grey.shade400
                    : (themeHelper.themeMode == ThemeMode.dark
                        ? ThemeNotifier.textDark
                        : const Color(0xFF1E2745)),
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: themeHelper.themeMode == ThemeMode.dark
                    ? ThemeNotifier.paymentEntryContainerColor
                    : Colors.white,
                hintText: "${TextConstants.currencySymbol} 0.00",
                hintStyle: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.normal,
                  color: Colors.grey.shade400,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Numpad ─────────────────────────────────────────────
          _buildCustomNumpad(context),
        ],
      ),
    );
  }

  Widget _buildCustomNumpad(BuildContext context) {
    return Center(
      child: SizedBox(
        width: MediaQuery.of(context).size.width / 2.75,
        height: MediaQuery.of(context).size.height / 2.75,
        child: CustomNumPad(
          onDigitPressed: (digit) {
            setState(() {
              // Extract numeric part from current value (ignore ₹ or commas)
              String cleanValue =
                  _customItemPrice.replaceAll(RegExp(r'[^\d.]'), '');

              // Convert current value (e.g. "12.34") to integer cents → 1234
              int rawAmount =
                  ((double.tryParse(cleanValue) ?? 0.0) * 100).round();

              // Append digit(s)
              if (digit == '00') {
                rawAmount =
                    (rawAmount * 100) % 100000000; // shift left two digits
              } else {
                int d = int.tryParse(digit) ?? 0;
                rawAmount =
                    (rawAmount * 10 + d) % 100000000; // shift left one digit
              }

              // Convert back to display value
              double displayValue = rawAmount / 100.0;

              // Update both internal value and controller text
              _customItemPrice = displayValue.toStringAsFixed(2);
              _customItemPriceController.text =
                  "${TextConstants.currencySymbol}${_customItemPrice}";

              // Highlight only when price > 0
              _isEnteringItemPrice = rawAmount > 0;
            });
          },
          onClearPressed: () {
            setState(() {
              // _customItemPrice = "0.00";
              // _customItemPriceController.text =
              // "${TextConstants.currencySymbol}0.00";
              // _isEnteringItemPrice = false;
              _customItemPrice = "0.00";
              _customItemPriceController.text =
                  "${TextConstants.currencySymbol}0.00";
              _isEnteringItemPrice = false;

              // 🔥 NEW: Clear Category + Reset to initial state
              _selectedCategoryName = "Select Category";
            });
          },
          onDeletePressed: () {
            setState(() {
              // Extract numeric value (ignore ₹ or commas)
              String cleanValue =
                  _customItemPrice.replaceAll(RegExp(r'[^\d.]'), '');

              // Convert to integer cents
              int rawAmount =
                  ((double.tryParse(cleanValue) ?? 0.0) * 100).round();

              // Remove one digit from the end
              rawAmount = rawAmount ~/ 10;

              // Convert back to display value
              double displayValue = rawAmount / 100.0;

              // Update UI + controller
              _customItemPrice = displayValue.toStringAsFixed(2);
              _customItemPriceController.text =
                  "${TextConstants.currencySymbol}${_customItemPrice}";

              _isEnteringItemPrice = rawAmount > 0;
            });
          },
          actionButtonType: ActionButtonType.add,
          onAddPressed: () {
            if (kDebugMode) {
              print("✅ onAddPressed triggered — raw price: $_customItemPrice");
            }

            setState(() {
              _isEnteringItemPrice = false;
              // _selectedCategoryName = "Select Category";
            });

            // Remove symbols, spaces, etc.
            final cleanedPrice =
                _customItemPrice.replaceAll(RegExp(r'[^0-9.]'), '');
            double? price = double.tryParse(cleanedPrice);

            if (price == null || price <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Enter valid price'),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }

            // Update the variable with cleaned numeric string
            _customItemPrice = price.toString();

            _handleAddCustomItem();
          },
          isLoading: _isCustomItemLoading,
          isDarkTheme: true,
          numPadType: NumPadType.payment,
          showAddInsteadOfPay: true,
        ),
      ),
    );
  }

  Widget _buildLabeledTextField({
    required String title,
    required String hintText,
    required TextEditingController controller,
    bool readOnly = false,
    bool isHighlighted = false,
    FocusNode? focusNode,
  }) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    // Conditionally set the border color and width based on the highlight status
    final borderColor = isHighlighted
        ? Colors.deepPurpleAccent
        : (themeHelper.themeMode == ThemeMode.dark
            ? ThemeNotifier.borderColor
            : Colors.grey.shade300);
    final borderWidth = isHighlighted ? 2.0 : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      // mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        SizedBox(
          height: 5,
        ),
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: themeHelper.themeMode == ThemeMode.dark
                ? ThemeNotifier.textDark
                : Color(0xFF1E2745),
          ),
        ),
        const SizedBox(height: 5),
        Container(
          height: MediaQuery.of(context).size.height / 14,
          width: MediaQuery.of(context).size.width * 0.2,
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 10),
          decoration: BoxDecoration(
            color: themeHelper.themeMode == ThemeMode.dark
                ? ThemeNotifier.paymentEntryContainerColor
                : null,
            border: Border.all(color: borderColor, width: borderWidth),
            borderRadius: BorderRadius.circular(10),
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            readOnly: readOnly,
            textAlign: TextAlign.start,
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: hintText,
              hintStyle: TextStyle(
                  color: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.textDark
                      : Colors.grey),
            ),
          ),
        ),
      ],
    );
  }

  // Widget _buildSkuField() {
  //   final themeHelper = Provider.of<ThemeNotifier>(context);
  //   return Column(
  //     crossAxisAlignment: CrossAxisAlignment.start,
  //     children: [
  //       SizedBox(
  //         height: 5,
  //       ),
  //       Text(
  //         TextConstants.sku,
  //         style: TextStyle(
  //           fontWeight: FontWeight.w600,
  //           fontSize: 14,
  //           color: themeHelper.themeMode == ThemeMode.dark
  //               ? ThemeNotifier.textDark
  //               : Color(0xFF1E2745),
  //         ),
  //       ),
  //       const SizedBox(height: 5),
  //       Container(
  //         height: MediaQuery.of(context).size.height / 14,
  //         width: MediaQuery.of(context).size.width * 0.2,
  //         decoration: BoxDecoration(
  //           border: Border.all(
  //               color: themeHelper.themeMode == ThemeMode.dark
  //                   ? ThemeNotifier.borderColor
  //                   : Colors.grey.shade300),
  //           color: themeHelper.themeMode == ThemeMode.dark
  //               ? ThemeNotifier.paymentEntryContainerColor
  //               : Color(0xFFECE9E9),
  //           // Custom background color,
  //           borderRadius: BorderRadius.circular(10),
  //         ),
  //         child: Row(
  //           children: [
  //             Expanded(
  //               child: TextField(
  //                 controller: _skuController,
  //                 readOnly: true,
  //                 textAlign: TextAlign.start,
  //                 decoration: InputDecoration(
  //                   border: InputBorder.none,
  //                   contentPadding:
  //                   EdgeInsets.symmetric(horizontal: 10, vertical: 9),
  //                   hintText: 'generateTheSku',
  //                   hintStyle: TextStyle(
  //                       color: themeHelper.themeMode == ThemeMode.dark
  //                           ? ThemeNotifier.textDark
  //                           : Colors.grey),
  //                 ),
  //               ),
  //             ),
  //             Padding(
  //               padding: const EdgeInsets.all(6.0),
  //               child: ElevatedButton(
  //                 onPressed: (_isItemNameEmpty() || _isSkuGenerated) ? null : _generateSku,
  //                 style: ElevatedButton.styleFrom(
  //                   backgroundColor: _isGenerateSkuEnabled()
  //                       ? Colors.redAccent
  //                       : Colors.grey,
  //                   foregroundColor: Colors.white,
  //                   padding: const EdgeInsets.symmetric(horizontal: 12),
  //                   shape: RoundedRectangleBorder(
  //                     borderRadius: BorderRadius.circular(8),
  //                   ),
  //                   //minimumSize: const Size(60, 36),
  //                 ),
  //                 child: const Text(
  //                   TextConstants.generate,
  //                   style: TextStyle(
  //                     fontSize: 12,
  //                     fontWeight: FontWeight.bold,
  //                   ),
  //                 ),
  //               ),
  //             )
  //           ],
  //         ),
  //       ),
  //     ],
  //   );
  // }

  Widget _buildTaxDropdown() {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 5),
        Text(
          TextConstants.taxText,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: themeHelper.themeMode == ThemeMode.dark
                ? ThemeNotifier.textDark
                : const Color(0xFF1E2745),
          ),
        ),
        const SizedBox(height: 5),
        Container(
          height: MediaQuery.of(context).size.height / 14,
          width: MediaQuery.of(context).size.width * 0.2,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.borderColor
                  : Colors.grey.shade300,
            ),
            borderRadius: BorderRadius.circular(10),
            color: themeHelper.themeMode == ThemeMode.dark
                ? ThemeNotifier.paymentEntryContainerColor
                : null,
          ),
          child: _isTaxLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : DropdownButtonFormField<TaxModel>(
                  value: _selectedTax,
                  isExpanded: true,
                  dropdownColor: themeHelper.themeMode == ThemeMode.dark
                      ? ThemeNotifier.primaryBackground
                      : null,
                  icon: const Icon(Icons.keyboard_arrow_down),
                  items: _taxList.map((tax) {
                    return DropdownMenuItem<TaxModel>(
                      value: tax,
                      child: Text(
                        tax.name, // ✅ DISPLAY NAME FROM API
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: themeHelper.themeMode == ThemeMode.dark
                              ? ThemeNotifier.textDark
                              : const Color(0xFF1E2745),
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: _customItemNameController.text.trim().isNotEmpty
                      ? (value) {
                          if (kDebugMode) {
                            print(
                                "✅ Selected Tax: ${value?.name} | Rate: ${value?.rate}");
                          }
                          setState(() {
                            _selectedTax = value;
                          });
                        }
                      : null,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  hint: Text(
                    TextConstants.chooseTaxSlab,
                    style: TextStyle(
                      color: themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.textDark
                          : Colors.grey,
                      fontSize: 14,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPayoutsTab() {
    final themeHelper = Provider.of<ThemeNotifier>(context);

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        children: [
          Text(
            TextConstants.addPaymentAmount,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: themeHelper.themeMode == ThemeMode.dark
                  ? ThemeNotifier.textDark
                  : const Color(0xFF1E2745),
            ),
          ),
          const SizedBox(height: 20),

          // 💰 Payout Display
          Container(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 12,
            margin: const EdgeInsets.only(top: 10),
            child: TextField(
              readOnly: true,
              controller: TextEditingController(
                // ✅ Add the symbol only here
                text:
                    "${TextConstants.currencySymbol}${_payoutAmount.isEmpty ? "0.00" : _payoutAmount}",
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight:
                    _isAmountEntered ? FontWeight.bold : FontWeight.normal,
                color: _payoutAmount.isEmpty
                    ? Colors.grey.shade400
                    : themeHelper.themeMode == ThemeMode.dark
                        ? ThemeNotifier.textDark
                        : const Color(0xFF1E2745),
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: themeHelper.themeMode == ThemeMode.dark
                    ? ThemeNotifier.paymentEntryContainerColor
                    : Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: Color(0xFF1E2745),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 🔢 Custom Numpad
          SizedBox(
            width: MediaQuery.of(context).size.width / 2.75,
            height: MediaQuery.of(context).size.height / 2.25,
            child: CustomNumPad(
              onDigitPressed: (digit) {
                setState(() {
                  // Clean numeric part only
                  String cleanValue = _payoutAmount.replaceAll(',', '').trim();
                  int rawAmount =
                      ((double.tryParse(cleanValue) ?? 0.0) * 100).round();

                  if (digit == '00') {
                    rawAmount = (rawAmount * 100) % 100000000;
                  } else {
                    int d = int.tryParse(digit) ?? 0;
                    rawAmount = (rawAmount * 10 + d) % 100000000;
                  }

                  double displayValue = rawAmount / 100.0;
                  _payoutAmount =
                      displayValue.toStringAsFixed(2); // ✅ no symbol
                  _isAmountEntered = rawAmount != 0;
                });
              },
              onDeletePressed: () {
                setState(() {
                  String cleanValue = _payoutAmount.replaceAll(',', '').trim();
                  int rawAmount =
                      ((double.tryParse(cleanValue) ?? 0.0) * 100).round();
                  rawAmount = rawAmount ~/ 10;

                  double displayValue = rawAmount / 100.0;
                  _payoutAmount =
                      displayValue.toStringAsFixed(2); // ✅ no symbol
                  _isAmountEntered = rawAmount != 0;
                });
              },
              onClearPressed: () {
                setState(() {
                  _payoutAmount = "0.00"; // ✅ no symbol
                  _isAmountEntered = false;
                });
              },
              actionButtonType: ActionButtonType.add,
              onAddPressed: _handleAddPayout,
              isLoading: _isPayoutLoading,
              numPadType: NumPadType.payment,
              showAddInsteadOfPay: true,
              isDarkTheme: themeHelper.themeMode == ThemeMode.dark,
            ),
          ),
        ],
      ),
    );
  }

  // Generate SKU function
  void _generateSku() {
    if (_skuController.text.trim().isNotEmpty) return;
    // Simple SKU generation logic - prefix + timestamp
    String timestamp =
        DateTime.now().millisecondsSinceEpoch.toString().substring(0, 12);
    // String prefix = _customItemName.isNotEmpty
    //     ? _customItemName.substring(0, _customItemName.length > 3 ? 3 : _customItemName.length).toUpperCase()
    //     : "C";

    String prefix = 'C';
    setState(() {
      _sku = "$prefix-$timestamp";
      _skuController.text = _sku;
      _isSkuGenerated = true;
    });

    // Show confirmation snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(TextConstants.skuGeneratedSuccessfully),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 1),
      ),
    );
  }

  // Build the percentage/amount toggle
  Widget _buildDiscountToggle() {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    return Container(
      width: MediaQuery.of(context).size.width / 2.75,
      height: MediaQuery.of(context).size.height / 14,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: themeHelper.themeMode == ThemeMode.dark
                ? ThemeNotifier.secondaryBackground
                : Colors.grey.shade300),
      ),
      child: Row(
        children: [
          // Percentage option
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  if (!_isPercentageSelected) {
                    _isPercentageSelected = true;
                    // Convert to percentage format
                    _discountValue =
                        "${_discountValue.replaceAll(TextConstants.currencySymbol, '')}%"; // Build #1.0.181: 1. Replaced Hard coded ‘\$’ with TextConstants.currencySymbol
                  }
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _isPercentageSelected
                      ? Colors.red.shade400
                      : themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.tabsBackground
                          : Colors.white,
                  borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(9),
                      bottomLeft: Radius.circular(9),
                      topRight: Radius.circular(9),
                      bottomRight: Radius.circular(9)),
                ),
                alignment: Alignment.center,
                child: Text(
                  "%",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _isPercentageSelected
                        ? Colors.white
                        : themeHelper.themeMode == ThemeMode.dark
                            ? ThemeNotifier.textDark
                            : Colors.black,
                  ),
                ),
              ),
            ),
          ),

          // Dollar option
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  if (_isPercentageSelected) {
                    _isPercentageSelected = false;
                    // Convert to dollar format
                    _discountValue = _discountValue.replaceAll('%', '');
                  }
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: !_isPercentageSelected
                      ? Colors.redAccent
                      : themeHelper.themeMode == ThemeMode.dark
                          ? ThemeNotifier.tabsBackground
                          : Colors.white,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(9),
                    bottomRight: Radius.circular(9),
                    topLeft: Radius.circular(9),
                    bottomLeft: Radius.circular(9),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  TextConstants.currencySymbol,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: !_isPercentageSelected
                        ? Colors.white
                        : themeHelper.themeMode == ThemeMode.dark
                            ? ThemeNotifier.textDark
                            : Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static final Map<int, Map<String, dynamic>> _productMetaCache = {};
  static bool _productMetaInitialized = false;

  String _resolveDynamicProductName(Map<String, dynamic> map) {
    final dynamic rawName = map["fast_key_item_name"] ?? map["name"];
    if (rawName is Map && rawName["rendered"] != null) {
      return rawName["rendered"].toString();
    }
    return (rawName ?? "").toString();
  }

  String _resolveDynamicProductSku(Map<String, dynamic> map) {
    final dynamic rawSku =
        map["fast_key_item_sku"] ?? map["sku"] ?? map["item_sku"];
    return (rawSku ?? "").toString();
  }

  String _resolveDynamicProductImage(Map<String, dynamic> map) {
    final dynamic rawImage =
        map["fast_key_item_image"] ?? map["image"] ?? map["images"];
    if (rawImage is String) return rawImage;
    if (rawImage is Map && rawImage["src"] != null) {
      return rawImage["src"].toString();
    }
    if (rawImage is List && rawImage.isNotEmpty) {
      final first = rawImage.first;
      if (first is String) return first;
      if (first is Map && first["src"] != null) return first["src"].toString();
    }
    return "";
  }

  int? _resolveDynamicProductId(Map<String, dynamic> map) {
    final dynamic rawId =
        map["fast_key_product_id"] ?? map["product_id"] ?? map["id"];
    if (rawId is int) return rawId;
    return int.tryParse(rawId?.toString() ?? "");
  }

  void _cacheDynamicProduct(Map<String, dynamic> map) {
    final normalized = _normalizeDynamicProductMap(map);
    final int? pid = _resolveDynamicProductId(normalized);
    if (pid == null) return;
    _productMetaCache[pid] = normalized;
    _productMetaInitialized = true;
  }

  Map<String, dynamic> _normalizeDynamicProductMap(Map<String, dynamic> map) {
    final normalized = Map<String, dynamic>.from(map);
    final pid = _resolveDynamicProductId(normalized);
    final name = _resolveDynamicProductName(normalized);
    final sku = _resolveDynamicProductSku(normalized);
    final image = _resolveDynamicProductImage(normalized);

    if (pid != null) {
      normalized["fast_key_product_id"] = pid;
      normalized["product_id"] ??= pid;
      normalized["id"] ??= pid;
    }
    if (name.isNotEmpty) {
      normalized["fast_key_item_name"] = name;
      normalized["name"] ??= name;
    }
    if (sku.isNotEmpty) {
      normalized["fast_key_item_sku"] = sku;
      normalized["sku"] ??= sku;
    }
    if (image.isNotEmpty) {
      normalized["fast_key_item_image"] = image;
      normalized["image"] ??= image;
    }
    return normalized;
  }

  bool _dynamicProductMatches(Map<String, dynamic> map, List<String> tokens) {
    final name = _resolveDynamicProductName(map).toLowerCase();
    final sku = _resolveDynamicProductSku(map).toLowerCase();
    for (final token in tokens) {
      final t = token.toLowerCase();
      if (name.contains(t) || sku.contains(t)) return true;
    }
    return false;
  }

  Iterable<Map<String, dynamic>> _expandDynamicProductCandidates(
      dynamic raw) sync* {
    if (raw == null) return;
    if (raw is List) {
      for (final item in raw) {
        yield* _expandDynamicProductCandidates(item);
      }
      return;
    }
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      if (map["products"] is List) {
        yield* _expandDynamicProductCandidates(map["products"]);
        return;
      }
      if (map["product"] is Map || map["product"] is List) {
        yield* _expandDynamicProductCandidates(map["product"]);
        return;
      }
      if (map["data"] is String) {
        try {
          final decoded = jsonDecode(map["data"]);
          yield* _expandDynamicProductCandidates(decoded);
          return;
        } catch (_) {}
      }
      if (map["data"] is List || map["data"] is Map) {
        yield* _expandDynamicProductCandidates(map["data"]);
        return;
      }
      yield map;
    }
  }

  Future<Map<String, dynamic>?> _findDynamicProductByTokens(
      List<String> tokens) async {
    final normalizedTokens = tokens
        .map((e) => e.toLowerCase().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (normalizedTokens.isEmpty) return null;

    if (_productMetaInitialized && _productMetaCache.isNotEmpty) {
      for (final p in _productMetaCache.values) {
        if (_dynamicProductMatches(p, normalizedTokens)) return p;
      }
    }

    try {
      final isar = await IsarService.instance;
      final entries = await isar.isarCacheEntrys.where().findAll();

      for (final entry in entries) {
        if (!entry.key.startsWith("products_") &&
            !entry.key.startsWith("indigo_products_")) {
          continue;
        }

        dynamic decoded;
        try {
          decoded = jsonDecode(entry.json);
        } catch (_) {
          continue;
        }

        for (final map in _expandDynamicProductCandidates(decoded)) {
          if (!_dynamicProductMatches(map, normalizedTokens)) continue;
          final normalized = _normalizeDynamicProductMap(map);
          _cacheDynamicProduct(normalized);
          return normalized;
        }
      }
    } catch (e) {
      debugPrint("⚠️ Dynamic Isar lookup failed for '$normalizedTokens' → $e");
    }

    try {
      final allList =
          await StorageProvider.productCache.get("all_products_list");
      for (final map in _expandDynamicProductCandidates(allList)) {
        if (!_dynamicProductMatches(map, normalizedTokens)) continue;
        final normalized = _normalizeDynamicProductMap(map);
        _cacheDynamicProduct(normalized);
        return normalized;
      }
    } catch (e) {
      debugPrint(
          "⚠️ Dynamic productCache lookup failed for '$normalizedTokens' → $e");
    }

    return null;
  }

  Map<String, dynamic> _buildFallbackDynamicProduct({
    required int id,
    required String name,
    required String sku,
  }) {
    return <String, dynamic>{
      "fast_key_product_id": id,
      "product_id": id,
      "id": id,
      "fast_key_item_name": name,
      "name": name,
      "fast_key_item_sku": sku,
      "sku": sku,
      "fast_key_item_image": "",
      "image": "",
    };
  }

  Future<Map<String, dynamic>?> _getCashbackProductFromIsar() async {
    final resolved = await _findDynamicProductByTokens([
      "cashback",
      "cash back",
      "cash-back",
      "cash_back",
      "cb",
    ]);
    if (resolved != null) return resolved;

    final fallback = _buildFallbackDynamicProduct(
      id: 3310111,
      name: "Cashback",
      sku: "CASHBACK-DYNAMIC",
    );
    _cacheDynamicProduct(fallback);
    if (kDebugMode) {
      print("⚠️ Cashback product missing in cache → using fallback map");
    }
    return fallback;
  }

  Future<Map<String, dynamic>?> _getDiscountProductFromIsar() async {
    final resolved = await _findDynamicProductByTokens([
      "discount",
      "merchant discount",
      "merchant-discount",
      "merchant_discount",
    ]);
    if (resolved != null) return resolved;

    final fallback = _buildFallbackDynamicProduct(
      id: 990002,
      name: "Merchant Discount",
      sku: "MERCHANT-DISCOUNT-DYNAMIC",
    );
    _cacheDynamicProduct(fallback);
    if (kDebugMode) {
      print("Discount product missing in cache → using fallback map");
    }
    return fallback;
  }

  // Build the discount value display

  // Handle adding the discount
  //Build #1.0.78: Explanation!
  // Moved merchantDiscount update to OrderBloc.addPayout (already updated in OrderBloc to handle this).
  // Added dbOrderId parameter to addPayout call.
  // Kept local update for non-API orders (serverOrderId == null).
  // Added alert dialog with retry option for API failures.
  // Ensured _isDiscountLoading is shown during API calls and cleared afterward.
  // Preserved success toast and UI refresh logic.
  // Future<void> _handleAddDiscount() async {
  //   print("🟦 [DISCOUNT] START ---- _handleAddDiscount() ----");
  //
  //   if (_discountValue.isEmpty ||
  //       _discountValue == "0" ||
  //       double.tryParse(_discountValue.replaceAll('%', '')) == null) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(
  //         content: Text("Invalid discount amount"),
  //         backgroundColor: Colors.red,
  //         duration: Duration(seconds: 2),
  //       ),
  //     );
  //     return;
  //   }
  //
  //   setState(() => _isDiscountLoading = true);
  //
  //   try {
  //     final offlineBox = StorageProvider.offlineOrders;
  //     final orderHelper = OrderHelper();
  //
  //     int? orderId = orderHelper.activeOrderId;
  //
  //     if (orderId == null) {
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("No active order found"),
  //           backgroundColor: Colors.red,
  //           duration: Duration(seconds: 2),
  //         ),
  //       );
  //       setState(() => _isDiscountLoading = false);
  //       return;
  //     }
  //
  //     final key = orderId.toString();
  //     final existingOrder = Map<String, dynamic>.from(offlineBox.get(key));
  //
  //     // Load existing discount list
  //     final discounts = (existingOrder["discounts"] as List? ?? [])
  //         .map((e) => Map<String, dynamic>.from(e))
  //         .toList();
  //
  //     if (discounts.isNotEmpty) {
  //       setState(() => _isDiscountLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("A discount already exists for this order."),
  //           backgroundColor: Colors.orange,
  //         ),
  //       );
  //       return;
  //     }
  //
  //     // ------------------------------
  //     // 🔎 UNIVERSAL SEARCH FOR DISCOUNT PRODUCT
  //     // Same logic as cashback
  //     // ------------------------------
  //
  //     // 🔎 DISCOUNT PRODUCT FROM ISAR (FAST)
  //     final discountProduct = await _getDiscountProductFromIsar();
  //
  //     if (discountProduct == null) {
  //       setState(() => _isDiscountLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("Discount product not found!"),
  //           backgroundColor: Colors.red,
  //         ),
  //       );
  //       return;
  //     }
  //
  //     print("🟢 FOUND DISCOUNT PRODUCT → $discountProduct");
  //
  //     // Map<String, dynamic>? discountProduct;
  //     //
  //     // for (final k in productBox.keys) {
  //     //   final data = productBox.get(k);
  //     //   if (data == null) continue;
  //     //
  //     //   // Case A: Direct map
  //     //   if (data is Map) {
  //     //     final n = (data["fast_key_item_name"] ?? data["name"] ?? "")
  //     //         .toString()
  //     //         .toLowerCase();
  //     //
  //     //     if (n.contains("discount")) {
  //     //       discountProduct = Map<String, dynamic>.from(data);
  //     //       break;
  //     //     }
  //     //   }
  //     //
  //     //   // Case B: products list
  //     //   if (data is Map && data.containsKey("products")) {
  //     //     for (final item in data["products"]) {
  //     //       final n = (item["fast_key_item_name"] ?? item["name"] ?? "")
  //     //           .toString()
  //     //           .toLowerCase();
  //     //
  //     //       if (n.contains("discount")) {
  //     //         discountProduct = Map<String, dynamic>.from(item);
  //     //         break;
  //     //       }
  //     //     }
  //     //     if (discountProduct != null) break;
  //     //   }
  //     //
  //     //   // Case C: data: JSON array
  //     //   if (data is Map && data.containsKey("data")) {
  //     //     final list = json.decode(data["data"]);
  //     //     for (final item in list) {
  //     //       final n = (item["fast_key_item_name"] ?? item["name"] ?? "")
  //     //           .toString()
  //     //           .toLowerCase();
  //     //
  //     //       if (n.contains("discount")) {
  //     //         discountProduct = Map<String, dynamic>.from(item);
  //     //         break;
  //     //       }
  //     //     }
  //     //     if (discountProduct != null) break;
  //     //   }
  //     // }
  //     //
  //     // if (discountProduct == null) {
  //     //   print("🟥 Discount Product Not Found in Cache!");
  //     //   setState(() => _isDiscountLoading = false);
  //     //
  //     //   ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //     //     const SnackBar(
  //     //       content: Text("Discount product not found!"),
  //     //       backgroundColor: Colors.red,
  //     //     ),
  //     //   );
  //     //   return;
  //     // }
  //
  //     print("🟢 FOUND DISCOUNT PRODUCT → $discountProduct");
  //
  //     // ------------------------------
  //     // Load products
  //     // ------------------------------
  //     final products = (existingOrder["products"] as List? ?? [])
  //         .map((e) => Map<String, dynamic>.from(e))
  //         .toList();
  //
  //     // / ⛔ ADD CHECK HERE
  //     if (products.isEmpty) {
  //       setState(() => _isDiscountLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("Cannot apply discount on an empty order"),
  //           backgroundColor: Colors.orange,
  //         ),
  //       );
  //       return;
  //     }
  //
  //
  //     // Calculate gross total
  //     double grossTotal = 0.0;
  //     for (var p in products) {
  //       grossTotal +=
  //           (double.tryParse(p["price"].toString()) ?? 0.0) *
  //               (double.tryParse(p["quantity"].toString()) ?? 1.0);
  //     }
  //
  //     // Parse discount amount
  //     String parsedValue =
  //     _discountValue.replaceAll('%', '').replaceAll("₹", "").trim();
  //
  //     double discountAmount = double.parse(parsedValue);
  //     bool isPercentage = _isPercentageSelected;
  //
  //     if (isPercentage) {
  //       discountAmount = (discountAmount / 100) * grossTotal;
  //     }
  //
  //     if (discountAmount > grossTotal) {
  //       setState(() => _isDiscountLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("Discount cannot exceed total amount"),
  //           backgroundColor: Colors.red,
  //         ),
  //       );
  //       return;
  //     }
  //
  //     // ------------------------------
  //     // 🧾 CREATE DISCOUNT ENTRY
  //     // ------------------------------
  //     final discountEntry = {
  //       "order_id": orderId,
  //       "discount_product_id":
  //       discountProduct["product_id"] ??
  //           discountProduct["id"] ??
  //           discountProduct["fast_key_product_id"],
  //       // ⭐ SAME AS CASHBACK
  //       "name": discountProduct["fast_key_item_name"] ?? "Discount",
  //       "product_image": discountProduct["fast_key_item_image"] ?? "",
  //
  //       "discount_amount": -discountAmount,     // Negative for Woo
  //       "display_amount": discountAmount,       // Shown positive in UI
  //
  //       "discount_type": isPercentage ? "percentage" : "fixed",
  //       "original_input": _discountValue,
  //
  //       // Required for summary panel
  //       AppDBConst.itemName: "Discount",
  //       AppDBConst.itemType: "discount",
  //       AppDBConst.itemPrice: discountAmount.abs(),
  //       AppDBConst.itemSumPrice: discountAmount.abs(),
  //       AppDBConst.itemCount: 1,
  //
  //       "timestamp": DateTime.now().toIso8601String(),
  //     };
  //
  //     discounts.add(discountEntry);
  //
  //     // Recalculate totals
  //     double finalTotal = grossTotal - discountAmount;
  //
  //     final updatedOrder = {
  //       ...existingOrder,
  //       "products": products,
  //       "discounts": discounts,
  //       "gross_total": grossTotal,
  //       "net_total": grossTotal - discountAmount,
  //       "net_payable": finalTotal,
  //
  //       // ⭐ REQUIRED FIELDS FOR SUMMARY PANEL ⭐
  //       "merchantDiscount": discountAmount,              // <--- You MISSED THIS
  //       "merchantDiscountIsPercentage": isPercentage,    // <--- You MISSED THIS
  //       "merchantDiscountIds": [
  //         discountProduct["product_id"] ??
  //             discountProduct["id"] ??
  //             discountProduct["fast_key_product_id"]
  //       ],
  //     };
  //
  //
  //
  //     await offlineBox.put(key, updatedOrder);
  //
  //     // ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //     //   SnackBar(
  //     //     content:
  //     //     Text("Discount of ₹${discountAmount.toStringAsFixed(2)} applied"),
  //     //     backgroundColor: Colors.green,
  //     //   ),
  //     // );
  //
  //     setState(() {
  //       _discountValue = isPercentage ? "0%" : "0";
  //       _isDiscountLoading = false;
  //     });
  //
  //     await _loadOrderData();
  //     widget.refreshOrderList?.call();
  //
  //     print("✅ [DISCOUNT] DONE ---- _handleAddDiscount() ----");
  //
  //   } catch (e, s) {
  //     print("🟥 [DISCOUNT] ERROR: $e\n$s");
  //     setState(() => _isDiscountLoading = false);
  //
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       SnackBar(
  //         content: Text("Error applying discount: $e"),
  //         backgroundColor: Colors.red,
  //       ),
  //     );
  //   }
  // }

  Future<void> _handleAddDiscount() async {
    print("🟦 [DISCOUNT] START ---- _handleAddDiscount() ----");

    // ────────────────────────────────────────
    // 1. Basic input validation
    // ────────────────────────────────────────
    if (_discountValue.isEmpty ||
        _discountValue == "0" ||
        _discountValue == "0%" ||
        double.tryParse(_discountValue
                .replaceAll('%', '')
                .replaceAll("₹", "")
                .trim()) ==
            null) {
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        const SnackBar(
          content: Text("Please enter a valid discount amount"),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _isDiscountLoading = true);

    try {
      final offlineBox = StorageProvider.offlineOrders;
      final orderHelper = OrderHelper();

      final orderId = orderHelper.activeOrderId;
      if (orderId == null) {
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("No active order found"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isDiscountLoading = false);
        return;
      }

      final key = orderId.toString();
      final rawOrder = await offlineBox.get(key);
      if (rawOrder == null) {
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("Order data not found"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isDiscountLoading = false);
        return;
      }

      final existingOrder = Map<String, dynamic>.from(rawOrder);

      // ────────────────────────────────────────
      // 2. Prevent multiple discounts (your current rule)
      // ────────────────────────────────────────
      final discounts = (existingOrder["discounts"] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      if (discounts.isNotEmpty) {
        setState(() => _isDiscountLoading = false);
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("A discount is already applied to this order."),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // ────────────────────────────────────────
      // 3. Find discount product
      // ────────────────────────────────────────
      final discountProduct = await _getDiscountProductFromIsar();

      if (discountProduct == null) {
        setState(() => _isDiscountLoading = false);
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("Discount product not found in catalog"),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      print(
          "🟢 Discount product found → ${discountProduct['name'] ?? 'Discount'}");

      // ────────────────────────────────────────
      // 4. Calculate current gross total (before discount)
      // Support both "products" (Categories/Fast Keys) and "order_items" (Order Summary)
      // ────────────────────────────────────────
      var products = (existingOrder["products"] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      // Fallback: order may have order_items from Order Summary screen
      if (products.isEmpty) {
        final orderItems = (existingOrder["order_items"] as List? ?? []);
        for (final oi in orderItems) {
          final map = Map<String, dynamic>.from(oi is Map ? oi : {});
          final itemType =
              (map['item_type'] ?? map['type'] ?? '').toString().toLowerCase();
          if (itemType.contains('discount')) continue;
          products.add({
            ...map,
            'name': map['item_name'] ?? map['name'] ?? '',
            'price': (map['item_price'] ?? map['price'] ?? 0).toDouble(),
            'quantity': (map['items_count'] ?? map['quantity'] ?? 1).toInt(),
            'product_id': map['product_id'],
            'sku': map['sku'] ?? map['item_sku'],
            'type': map['item_type'] ?? map['type'] ?? 'product',
          });
        }
      }

      if (products.isEmpty) {
        setState(() => _isDiscountLoading = false);
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("Cannot apply discount on an empty order"),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      double grossTotal = 0.0;
      for (var p in products) {
        final price = double.tryParse(p["price"]?.toString() ?? '0') ?? 0.0;
        final qty = int.tryParse(p["quantity"]?.toString() ?? '1') ?? 1;
        grossTotal += price * qty;
      }

      print(
          "Current gross total before discount: ₹${grossTotal.toStringAsFixed(2)}");

      // ────────────────────────────────────────
      // 5. Parse discount value
      // ────────────────────────────────────────
      String parsedValue = _discountValue
          .replaceAll('%', '')
          .replaceAll(TextConstants.currencySymbol, '')
          .replaceAll("₹", "")
          .trim();

      double inputValue = double.parse(parsedValue);
      bool isPercentage = _isPercentageSelected;

      // Extract existing order tax and order discount
      double couponVal =
          (existingOrder['orderDiscount'] as num?)?.toDouble() ?? 0.0;

      double discountAmount = isPercentage
          ? (inputValue / 100) * (grossTotal - couponVal)
          : inputValue;

      if (discountAmount > (grossTotal - couponVal)) {
        setState(() => _isDiscountLoading = false);
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("Discount cannot exceed the current order total"),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // ────────────────────────────────────────
      // 6. Create discount line item (for order panel / receipt)
      // ────────────────────────────────────────
      final discountEntry = {
        "order_id": orderId,
        "discount_product_id": discountProduct["product_id"] ??
            discountProduct["id"] ??
            discountProduct["fast_key_product_id"],
        "name": discountProduct["fast_key_item_name"] ?? "Merchant Discount",
        "product_image": discountProduct["fast_key_item_image"] ?? "",
        "discount_amount": -discountAmount, // negative for accounting
        "display_amount": discountAmount, // positive for display
        "discount_type": isPercentage ? "percentage" : "fixed",
        "discount_percentage": isPercentage ? inputValue : 0.0,
        "original_input": _discountValue,
        AppDBConst.itemName: "Merchant Discount",
        AppDBConst.itemType: "discount",
        AppDBConst.itemPrice: discountAmount.abs(),
        AppDBConst.itemSumPrice: discountAmount.abs(),
        AppDBConst.itemCount: 1,
        "timestamp": DateTime.now().toIso8601String(),
      };

      discounts.add(discountEntry);

      // ────────────────────────────────────────
      // 7. Save updated order with better fields for future recalculation
      // ────────────────────────────────────────
      final updatedOrder = {
        ...existingOrder,
        "products": products,
        "discounts": discounts,
        "gross_total": grossTotal,
        "net_total": grossTotal - discountAmount,
        "net_payable": grossTotal - discountAmount,

        // ──────── Fields for dynamic recalculation ────────
        "merchantDiscount": discountAmount, // current calculated value
        "merchantDiscountType": isPercentage ? "percentage" : "fixed",
        "merchantDiscountPercentage": isPercentage ? inputValue : 0.0,
        "merchantDiscountFixed": isPercentage ? 0.0 : discountAmount,
        "merchantDiscountBaseGross":
            grossTotal, // snapshot of total when applied
        "merchantDiscountIds": [
          discountProduct["product_id"] ??
              discountProduct["id"] ??
              discountProduct["fast_key_product_id"]
        ],
      };

      await offlineBox.put(key, updatedOrder);

      print("💾 Discount saved successfully");
      print("   • Type:        ${updatedOrder['merchantDiscountType']}");
      print("   • Percentage:  ${updatedOrder['merchantDiscountPercentage']}%");
      print("   • Fixed:       ₹${updatedOrder['merchantDiscountFixed']}");
      print(
          "   • Current amt: ₹${updatedOrder['merchantDiscount']?.toStringAsFixed(2)}");

      // ────────────────────────────────────────
      // 8. UI feedback & cleanup
      // ────────────────────────────────────────
      setState(() {
        _discountValue = isPercentage ? "0%" : "0.00";
        _isDiscountLoading = false;
      });

      await _orderHelper.loadData();
      await _loadOrderData();
      OrderHelper.notifyOrderPanelToRefresh();
      widget.refreshOrderList?.call();

      print(" [DISCOUNT] DONE ---- _handleAddDiscount() ----");
    } catch (e, stack) {
      print("🟥 [DISCOUNT] ERROR: $e");
      print("Stack trace: $stack");
      setState(() => _isDiscountLoading = false);

      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        SnackBar(
          content: Text("Error applying discount: $e"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
// Handle adding the coupon
//   void _handleAddCoupon() async {
//     if (_couponCode.isEmpty || _couponCode == "0") {
//       if (kDebugMode) print("### _couponCode is empty");
//       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
//         const SnackBar(
//           content: Text(TextConstants.invalidCouponError),
//           // Build #1.0.181: Added through TextConstants
//           backgroundColor: Colors.red,
//           duration: Duration(seconds: 2),
//         ),
//       );
//       return;
//     }
//
//     final orderId = OrderHelper()
//         .activeOrderId; //Build #1.0.134: get activeOrderId
//     if (orderId == null) {
//       if (kDebugMode) print("No active order selected");
//       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
//         const SnackBar(
//           content: Text(TextConstants.noActiveOrderError),
//           // Build #1.0.181: Added through TextConstants
//           backgroundColor: Colors.red,
//           duration: Duration(seconds: 2),
//         ),
//       );
//       return;
//     }
//
//     setState(() {
//       _isCouponLoading = true;
//     });
//
//     try {
//       final db = await DBHelper.instance.database;
//
//       final orderData = await db
//           .query( // Build #1.0.128: updated missed condition
//         AppDBConst.orderTable,
//         where: '${AppDBConst.orderServerId} = ?',
//         whereArgs: [orderId],
//       );
//
//       if (orderData.isEmpty) {
//         if (kDebugMode) print("Order $orderId not found in database");
//         setState(() => _isCouponLoading = false);
//         ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
//           const SnackBar(
//             content: Text(TextConstants.orderNotFoundError),
//             // Build #1.0.181: Added through TextConstants
//             backgroundColor: Colors.red,
//             duration: Duration(seconds: 2),
//           ),
//         );
//         return;
//       }
//
//       // Check for existing coupon with the same couponCode
//       final existingCoupons = await db.query(
//         AppDBConst.purchasedItemsTable,
//         where: '${AppDBConst.orderIdForeignKey} = ? AND ${AppDBConst
//             .itemName} = ? AND ${AppDBConst.itemType} = ?',
//         whereArgs: [orderId, _couponCode, ItemType.coupon.value],
//       );
//
//       if (existingCoupons.isNotEmpty) {
//         if (kDebugMode) print(
//             "Coupon with code $_couponCode already exists for order $orderId");
//         ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
//           const SnackBar(
//             content: Text(TextConstants.couponAlreadyApplied),
//             // Build #1.0.181: Added through TextConstants
//             backgroundColor: Colors.orange,
//             duration: Duration(seconds: 2),
//           ),
//         );
//         setState(() {
//           _isCouponLoading = false;
//         });
//         return;
//       }
//
//       StreamSubscription? subscription;
//       if (kDebugMode) print("### Subscribing to applyCouponStream");
//       subscription = orderBloc.applyCouponStream.listen((response) async {
//         if (!mounted) {
//           subscription?.cancel();
//           return;
//         }
//         if (response.status == Status.COMPLETED) {
//           // Insert coupons into DB, ensuring no duplicates
//           for (var coupon in response.data?.couponLines ?? []) {
//             if (coupon.code == null || coupon.id == null) {
//               if (kDebugMode) print("Invalid coupon data: code or id is null");
//               continue;
//             }
//
//             // Double-check for itemServerId to be extra safe
//             final duplicateCheck = await db.query(
//               AppDBConst.purchasedItemsTable,
//               where: '${AppDBConst.orderIdForeignKey} = ? AND ${AppDBConst
//                   .itemServerId} = ?',
//               whereArgs: [orderId, coupon.id],
//             );
//
//             if (duplicateCheck.isEmpty) {
//               await db.insert(AppDBConst.purchasedItemsTable, {
//                 AppDBConst.orderIdForeignKey: orderId!,
//                 AppDBConst.itemServerId: coupon.id,
//                 AppDBConst.itemName: coupon.code!,
//                 AppDBConst.itemSKU: '',
//                 AppDBConst.itemPrice: coupon.nominalAmount?.toDouble() ?? 0.0,
//                 AppDBConst.itemCount: 1,
//                 AppDBConst.itemSumPrice: coupon.nominalAmount?.toDouble() ??
//                     0.0,
//                 AppDBConst.itemImage: 'assets/svg/coupon.svg',
//                 AppDBConst.itemType: ItemType.coupon.value,
//               });
//             }
//           }
//           if (Misc.showDebugSnackBar) {
//             ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
//               SnackBar(
//                 content: Text("Coupon '${_couponCode}' applied successfully"),
//                 backgroundColor: Colors.green,
//                 duration: const Duration(seconds: 2),
//               ),
//             );
//           }
//
//           setState(() { // Build #1.0.248: Fixed [SCRUM-400] -> Inappropriate Toast Message Displaying After Custom Item & Coupon Addition
//             _couponCode = "";
//             _isCouponLoading = false;
//           });
//
//           // Refresh UI
//           await _orderHelper.loadData();
//           await _loadOrderData();
//           widget.refreshOrderList?.call();
//           subscription?.cancel();
//         } else if (response.status == Status.ERROR) {
//           if (kDebugMode) print("Failed to apply coupon: ${response.message}");
//           ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
//             SnackBar(
//               content: Text(response.message ?? "Failed to apply coupon"),
//               backgroundColor: Colors.red,
//               duration: const Duration(seconds: 2),
//             ),
//           );
//           setState(() {
//             _isCouponLoading = false;
//           });
//           subscription?.cancel();
//         }
//       }, onError: (error) {
//         if (kDebugMode) print("### applyCouponStream error: $error");
//         setState(() {
//           _isCouponLoading = false;
//         });
//         subscription?.cancel();
//       });
//
//       if (kDebugMode) print("### Calling orderBloc.applyCouponToOrder");
//       await orderBloc.applyCouponToOrder(
//           orderId: orderId!, couponCode: _couponCode);
//     } catch (e) {
//       if (kDebugMode) print("Error applying coupon: $e");
//       setState(() {
//         _isCouponLoading = false;
//       });
//     }
//   }

  void _handleCashbackpayout() async {
    print("🟩 [CASHBACK] START ---- _handleCashbackpayout() ----");

    if (_cashbackAmount.isEmpty ||
        _cashbackAmount == "0.00" ||
        double.tryParse(_cashbackAmount) == null) {
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        const SnackBar(
          content: Text("Invalid cashback amount"),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _isCashbackLoading = true);

    try {
      final offlineBox = StorageProvider.offlineOrders;
      final cashbackAmount = double.parse(_cashbackAmount);
      // 🔥 MAX CASHBACK VALIDATION
      if (_maxCashbackLimit > 0 && cashbackAmount > _maxCashbackLimit) {
        setState(() => _isCashbackLoading = false);

        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          SnackBar(
            content: Text(
              "Cashback cannot exceed ${TextConstants.currencySymbol}${_maxCashbackLimit.toStringAsFixed(2)}",
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        return; // ❗ STOP here → Do NOT add cashback
      }

      final orderHelper = OrderHelper();
      int? orderId = await orderHelper.ensureOrderExists();
      if (orderId == null) {
        setState(() => _isCashbackLoading = false);
        final msg = OrderHelper.lastEnsureOrderError ??
            "Could not create or find an order. Please try again.";
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final key = orderId.toString();
      final rawKey = await offlineBox.get(key);
      final existingOrder =
          Map<String, dynamic>.from(rawKey is Map ? rawKey : {});

      // -------------------------------------------------------
// 🚫 STOP Cashback if order panel has EBT eligible product
// -------------------------------------------------------
      final List<Map<String, dynamic>> existingProducts =
          (existingOrder["products"] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
      // 🚫 STOP Cashback if no products in cart
      if (existingProducts.isEmpty) {
        setState(() => _isCashbackLoading = false);

        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("Add products to cart before applying cashback."),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );

        return;
      }

      bool hasEbtProduct = existingProducts.any((p) {
        return p["is_ebt_eligible"] == true;
      });

      if (hasEbtProduct) {
        // EBT products are allowed to receive cashback in this flow.
        // Previously we blocked this with an early return.
        print("✅ EBT product detected, but cashback is still allowed.");
      }

      final List<Map<String, dynamic>> cashbacks =
          (existingOrder["cashbacks"] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e))
              .toList();

      // ❌ Only 1 cashback allowed
      if (cashbacks.isNotEmpty) {
        setState(() => _isCashbackLoading = false);
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("Cashback already applied."),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      final cashbackProduct = await _getCashbackProductFromIsar();

      if (cashbackProduct == null) {
        throw "Dynamic cashback product not found in Isar cache!";
      }

      print("🟢 FOUND CASHBACK PRODUCT → $cashbackProduct");

      // -------------------------------------------------------
      // 🟢 UNIVERSAL PRODUCT SEARCH FOR "Cashback"
      // -------------------------------------------------------
      // Map<String, dynamic>? cashbackProduct;
      //
      // for (final k in productBox.keys) {
      //   final data = productBox.get(k);
      //
      //   if (data == null) continue;
      //
      //   // Case A: Direct product map (YOUR MAIN storage)
      //   if (data is Map) {
      //     final name = (data["fast_key_item_name"] ??
      //         data["name"] ??
      //         "").toString().toLowerCase();
      //
      //     if (name.contains("cashback")) {
      //       cashbackProduct = Map<String, dynamic>.from(data);
      //       break;
      //     }
      //   }
      //
      //   // Case B: { "products": [ ... ] } format
      //   if (data is Map && data.containsKey("products")) {
      //     final list = data["products"];
      //     if (list is List) {
      //       for (final item in list) {
      //         final name = (item["fast_key_item_name"] ??
      //             item["name"] ??
      //             "").toString().toLowerCase();
      //
      //         if (name.contains("cashback")) {
      //           cashbackProduct = Map<String, dynamic>.from(item);
      //           break;
      //         }
      //       }
      //     }
      //   }
      //
      //   // Case C: { "data": [...] } format
      //   if (data is Map && data.containsKey("data")) {
      //     final list = json.decode(data["data"]);
      //     if (list is List) {
      //       for (final item in list) {
      //         final name = (item["fast_key_item_name"] ??
      //             item["name"] ??
      //             "").toString().toLowerCase();
      //
      //         if (name.contains("cashback")) {
      //           cashbackProduct = Map<String, dynamic>.from(item);
      //           break;
      //         }
      //       }
      //     }
      //   }
      //
      //   if (cashbackProduct != null) break;
      // }
      //
      // if (cashbackProduct == null) {
      //   throw "Dynamic cashback product not found in productCache!";
      // }
      //
      // print("🟢 FOUND CASHBACK PRODUCT → $cashbackProduct");

      // -------------------------------------------------------
      // 🧾 PREPARE CASHBACK ENTRY
      // -------------------------------------------------------
      final cashbackEntry = {
        "order_id": orderId,
        "cashback_product_id": cashbackProduct["fast_key_product_id"],
        "product_name": cashbackProduct["fast_key_item_name"],
        "product_image":
            "https://merchantretail.alektasolutions.com/wp-content/uploads/2025/11/cashback-line-item.jpg",

        // ---- your amount ----
        "amount": cashbackAmount,

        // ---- REQUIRED FOR ORDER PANEL ----
        AppDBConst.itemPrice: cashbackAmount.abs(), // ⭐ MUST
        AppDBConst.itemSumPrice: cashbackAmount.abs(), // ⭐ MUST
        AppDBConst.itemCount: 1, // ⭐ MUST
        AppDBConst.itemName: "Cashback", // optional but clean
        AppDBConst.itemType: "cashback",

        "timestamp": DateTime.now().toIso8601String(),
      };

      cashbacks.add(cashbackEntry);

      print("🟦 Cashback Entry Added → $cashbackEntry");

      // -------------------------------------------------------
      // 🔄 Recalculate total
      // -------------------------------------------------------
      final List<Map<String, dynamic>> products =
          (existingOrder["products"] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e))
              .toList();

      double productsTotal = 0.0;
      for (var p in products) {
        productsTotal += (double.tryParse(p["price"].toString()) ?? 0.0) *
            (double.tryParse(p["quantity"].toString()) ?? 1.0);
      }

      // Cashback reduces total
      // 1️⃣ Calculate cashback fee from config
      final double fee = await CashbackHelper.getCashbackFee(cashbackAmount);

      print("💰 CashbackAmount = $cashbackAmount → Fee = $fee");

      final updatedOrder = {
        ...existingOrder,
        "products": products,
        "cashbacks": cashbacks,

        // 2️⃣ Cashback reduces total, fee increases total
        "gross_total": productsTotal + cashbackAmount,

        // 3️⃣ Store cashback fee (NOT cashbackAmount)
        "cashbackFee": fee,
        AppDBConst.orderCashbackFee: fee,
      };

      await offlineBox.put(key, updatedOrder);
      print("🟩 SAVED ORDER → $updatedOrder");

      final extrasBox = StorageProvider.orderExtras;

// 🔒 NEVER overwrite an existing cashback
      final existingExtras = await extrasBox.get(orderId.toString());

      final double finalCashbackFee =
          existingExtras != null && existingExtras['cashback_fee'] != null
              ? (existingExtras['cashback_fee'] as num).toDouble()
              : fee;

      await extrasBox.put(orderId.toString(), {
        "local_order_id": orderId,
        "cashback_fee": finalCashbackFee,
        "cashback_amount": cashbackAmount, // optional, useful for audit
        "source": "cashback_payout",
        "saved_at": DateTime.now().toIso8601String(),
      });

      if (kDebugMode) {
        print("""
💾 [orderExtras] Cashback SAVED DIRECTLY
  Local Order ID : $orderId
  Cashback Amt  : $cashbackAmount
  Cashback Fee  : $finalCashbackFee
""");
      }

      // -------------------------------------------------------
      // ✔ UI feedback
      // -------------------------------------------------------
      // ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
      //   SnackBar(
      //     content: Text("Cashback ₹${cashbackAmount.toStringAsFixed(2)} applied"),
      //     backgroundColor: Colors.green,
      //   ),
      // );

      setState(() {
        _cashbackAmount = "";
        _isCashbackLoading = false;
      });

      await _orderHelper.loadData();
      await _loadOrderData();
      OrderHelper.notifyOrderPanelToRefresh();
      widget.refreshOrderList?.call();
    } catch (e, s) {
      print("🟥 [CASHBACK ERROR] $e\n$s");
      setState(() => _isCashbackLoading = false);
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        SnackBar(
            content: Text("Error adding cashback: $e"),
            backgroundColor: Colors.red),
      );
    }
  }

  // Future<void> _handleAddCustomItem() async {
  //   if (kDebugMode) print("🟢 [CUSTOM ITEM] START");
  //
  //   final orderHelper = OrderHelper();
  //   final int? ensuredOrderId = await orderHelper.ensureOrderExists();
  //
  //   if (ensuredOrderId == null) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Failed to create order"), backgroundColor: Colors.red),
  //     );
  //     return;
  //   }
  //
  //   // Validation for price
  //   final cleanedPrice = _customItemPrice.replaceAll(RegExp(r'[^0-9.]'), '');
  //   final double? price = double.tryParse(cleanedPrice);
  //
  //   if (price == null || price <= 0) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Please enter valid price"), backgroundColor: Colors.red),
  //     );
  //     return;
  //   }
  //
  //   setState(() => _isCustomItemLoading = true);
  //
  //   try {
  //     final box = StorageProvider.offlineOrders;
  //     final key = ensuredOrderId.toString();
  //     final rawOrder = await box.get(key) ?? {};
  //     final orderData = Map<String, dynamic>.from(rawOrder);
  //
  //     // Get existing products
  //     List<dynamic> products = (orderData["products"] ?? [])
  //         .map((e) => Map<String, dynamic>.from(e))
  //         .toList();
  //
  //     // 🔥 CHECK IF CUSTOM ITEM ALREADY EXISTS
  //     final hasCustomItem = products.any((item) =>
  //     (item["name"] ?? "").toString().trim().toLowerCase() == "custom item");
  //
  //     if (hasCustomItem) {
  //       setState(() => _isCustomItemLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("Order already have custom item so if you want to add one more create new order"),
  //           backgroundColor: Colors.orange,
  //           duration: Duration(seconds: 4),
  //         ),
  //       );
  //       return;
  //     }
  //
  //     // === ADD NEW CUSTOM ITEM ===
  //     final normalizedSku = _skuController.text.trim().isNotEmpty
  //         ? normalizeSku(_skuController.text)
  //         : "C-${DateTime.now().millisecondsSinceEpoch}";
  //
  //     final template = _customItemTemplate ?? {
  //       "id": 60303,
  //       "name": "Custom Item",
  //       "categories": [{"name": "Custom Product", "slug": "custom-product", "id": 520}],
  //       "tags": [{"name": "variable product", "slug": "variable-product", "id": 423}],
  //       "tax": {"tax_status": "taxable", "tax_class": "grocery"}
  //     };
  //
  //     final customItem = {
  //       "server_item_id": null,
  //       "product_id": template["id"] ?? 60303,
  //       "variation_id": 0,
  //       "type": "simple",
  //       "name": "Custom Item",
  //       "price": price,
  //       "sku": normalizedSku,
  //
  //       "categories": template["categories"],
  //       "tags": template["tags"],
  //
  //       "tax_status": template["tax"]?["tax_status"] ?? "taxable",
  //       "tax_class": template["tax"]?["tax_class"] ?? "grocery",
  //       "tax_rate": _selectedTax?.rate ?? 0.0,
  //
  //       "quantity": 1,
  //       "item_image": "assets/custom.png",
  //       "product_image": "assets/custom.png",
  //       AppDBConst.itemType: "custom",
  //       AppDBConst.itemName: "Custom Item",
  //       AppDBConst.itemPrice: price,
  //       AppDBConst.itemSumPrice: price,
  //       AppDBConst.itemCount: 1,
  //     };
  //
  //     products.add(customItem);
  //
  //     // Recalculate totals
  //     double grossTotal = 0.0;
  //     for (var p in products) {
  //       final itemPrice = (p["price"] ?? 0.0) as num;
  //       final qty = (p["quantity"] ?? 1) as num;
  //       grossTotal += itemPrice * qty;
  //     }
  //
  //     orderData["products"] = products;
  //     orderData["gross_total"] = grossTotal;
  //     orderData["net_total"] = grossTotal;
  //     orderData["net_payable"] = grossTotal;
  //
  //     // Save order
  //     await box.put(key, orderData);
  //
  //     // Cache for search
  //     await StorageProvider.productCache.put("sku_$normalizedSku", {"products": [customItem]});
  //
  //     // Reset UI
  //     setState(() {
  //       _isCustomItemLoading = false;
  //       _customItemPrice = "0.00";
  //       _customItemPriceController.clear();
  //       _skuController.clear();
  //       _isEnteringItemPrice = false;
  //     });
  //
  //     await _orderHelper.loadData();
  //     await _loadOrderData();
  //     OrderHelper.notifyOrderPanelToRefresh();
  //     widget.refreshOrderList?.call();
  //
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Custom Item added successfully!"), backgroundColor: Colors.green),
  //     );
  //   } catch (e, st) {
  //     print(" Custom Item Error: $e\n$st");
  //     setState(() => _isCustomItemLoading = false);
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       SnackBar(content: Text("Error adding custom item: $e"), backgroundColor: Colors.red),
  //     );
  //   }
  // }

  // Future<void> _handleAddCustomItem() async {
  //   if (kDebugMode) print("🟢 [CUSTOM ITEM] START");
  //
  //   final orderHelper = OrderHelper();
  //   final int? ensuredOrderId = await orderHelper.ensureOrderExists();
  //
  //   if (ensuredOrderId == null) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Failed to create order"), backgroundColor: Colors.red),
  //     );
  //     return;
  //   }
  //
  //   // Price Validation
  //   final cleanedPrice = _customItemPrice.replaceAll(RegExp(r'[^0-9.]'), '');
  //   final double? price = double.tryParse(cleanedPrice);
  //
  //   if (price == null || price <= 0) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Please enter valid price"), backgroundColor: Colors.red),
  //     );
  //     return;
  //   }
  //
  //   setState(() => _isCustomItemLoading = true);
  //
  //   try {
  //     final box = StorageProvider.offlineOrders;
  //     final key = ensuredOrderId.toString();
  //     final rawOrder = await box.get(key) ?? {};
  //     final orderData = Map<String, dynamic>.from(rawOrder);
  //
  //     List<dynamic> products = (orderData["products"] ?? [])
  //         .map((e) => Map<String, dynamic>.from(e))
  //         .toList();
  //
  //     // Find the selected item from dropdown
  //     final selectedItem = _customItemsList.firstWhere(
  //           (item) => (item['name']?.toString() ?? "") == _selectedCustomItemName,
  //       orElse: () => _customItemsList.isNotEmpty ? _customItemsList.first : {},
  //     );
  //
  //     final String itemName = selectedItem['name']?.toString() ?? "Custom Item";
  //     final int productId = selectedItem['id'] ?? 60303;
  //
  //     // 🔥 CHECK IF SAME ID ALREADY EXISTS
  //     final bool alreadyExists = products.any((item) {
  //       return (item['product_id'] ?? 0) == productId;
  //     });
  //
  //     if (alreadyExists) {
  //       setState(() => _isCustomItemLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("This item already added. Create new order to add again."),
  //           backgroundColor: Colors.orange,
  //           duration: Duration(seconds: 4),
  //         ),
  //       );
  //       return;
  //     }
  //
  //     // ==================== DYNAMIC DATA FROM NEW API STRUCTURE ====================
  //     final categories = selectedItem['categories'] is List ? selectedItem['categories'] : [];
  //     final tags = selectedItem['tags'] is List ? selectedItem['tags'] : [];
  //
  //     // NEW TAX STRUCTURE (Flat fields)
  //     final bool isTaxable = selectedItem['taxable'] == true;
  //     final String taxClass = selectedItem['tax_class']?.toString() ?? "grocery";
  //     final double taxPercent = double.tryParse(
  //         selectedItem['tax_percent']?.toString() ?? '0'
  //     ) ?? 0.0;
  //
  //     final normalizedSku = _skuController.text.trim().isNotEmpty
  //         ? normalizeSku(_skuController.text)
  //         : "C-${DateTime.now().millisecondsSinceEpoch}";
  //
  //     final customItem = {
  //       "server_item_id": null,
  //       "product_id": productId,
  //       "variation_id": 0,
  //       "type": selectedItem['type']?.toString() ?? "simple",
  //       "name": itemName,
  //       "price": price,
  //       "sku": normalizedSku,
  //
  //       "categories": categories,
  //       "tags": tags,
  //
  //       // Updated Tax Fields for new API response
  //       "tax_status": isTaxable ? "taxable" : "none",
  //       "tax_class": taxClass,
  //       "tax_rate": _selectedTax?.rate ?? taxPercent,   // Use tax_percent from API
  //
  //       "quantity": 1,
  //       "item_image": "assets/custom.png",
  //       "product_image": "assets/custom.png",
  //       AppDBConst.itemType: "custom",
  //       AppDBConst.itemName: itemName,
  //       AppDBConst.itemPrice: price,
  //       AppDBConst.itemSumPrice: price,
  //       AppDBConst.itemCount: 1,
  //     };
  //
  //     products.add(customItem);
  //
  //     // Recalculate Totals
  //     double grossTotal = 0.0;
  //     for (var p in products) {
  //       final itemPrice = (p["price"] ?? 0.0) as num;
  //       final qty = (p["quantity"] ?? 1) as num;
  //       grossTotal += itemPrice * qty;
  //     }
  //
  //     orderData["products"] = products;
  //     orderData["gross_total"] = grossTotal;
  //     orderData["net_total"] = grossTotal;
  //     orderData["net_payable"] = grossTotal;
  //
  //     await box.put(key, orderData);
  //
  //     // Cache for future scans
  //     await StorageProvider.productCache.put("sku_$normalizedSku", {"products": [customItem]});
  //
  //     // Reset UI
  //     setState(() {
  //       _isCustomItemLoading = false;
  //       _customItemPrice = "0.00";
  //       _customItemPriceController.clear();
  //       _skuController.clear();
  //       _isEnteringItemPrice = false;
  //     });
  //
  //     await _orderHelper.loadData();
  //     await _loadOrderData();
  //     OrderHelper.notifyOrderPanelToRefresh();
  //     widget.refreshOrderList?.call();
  //
  //     // ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //     //   SnackBar(
  //     //     content: Text("$itemName added successfully!"),
  //     //     backgroundColor: Colors.green,
  //     //   ),
  //     // );
  //   } catch (e) {
  //     print("❌ Custom Item Error: $e");
  //     setState(() => _isCustomItemLoading = false);
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       SnackBar(content: Text("Error adding custom item"), backgroundColor: Colors.red),
  //     );
  //   }
  // }

  // Future<void> _handleAddCustomItem() async {
  //   if (kDebugMode) print("🟢 [CUSTOM ITEM] START");
  //
  //   final orderHelper = OrderHelper();
  //   final int? ensuredOrderId = await orderHelper.ensureOrderExists();
  //
  //   if (ensuredOrderId == null) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Failed to create order"), backgroundColor: Colors.red),
  //     );
  //     return;
  //   }
  //
  //   // Price Validation
  //   final cleanedPrice = _customItemPrice.replaceAll(RegExp(r'[^0-9.]'), '');
  //   final double? price = double.tryParse(cleanedPrice);
  //
  //   if (price == null || price <= 0) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(content: Text("Please enter valid price"), backgroundColor: Colors.red),
  //     );
  //     return;
  //   }
  //
  //   setState(() => _isCustomItemLoading = true);
  //
  //   try {
  //     final box = StorageProvider.offlineOrders;
  //     final key = ensuredOrderId.toString();
  //     final rawOrder = await box.get(key) ?? {};
  //     final orderData = Map<String, dynamic>.from(rawOrder);
  //
  //     List<dynamic> products = (orderData["products"] ?? [])
  //         .map((e) => Map<String, dynamic>.from(e))
  //         .toList();
  //
  //     // Find the selected item from dropdown
  //     final selectedItem = _customItemsList.firstWhere(
  //           (item) => (item['name']?.toString() ?? "") == _selectedCustomItemName,
  //       orElse: () => _customItemsList.isNotEmpty ? _customItemsList.first : {},
  //     );
  //
  //     final String baseItemName = selectedItem['name']?.toString() ?? "Custom Item";
  //     final int productId = selectedItem['id'] ?? 60303;
  //
  //     // ==================== CATEGORY-BASED DUPLICATE CHECK ====================
  //     final String targetCategoryName = _selectedCategoryName;
  //
  //     final bool alreadyExists = products.any((item) {
  //       final itemCategories = item['categories'] as List? ?? [];
  //       return itemCategories.any((cat) {
  //         if (cat is Map<String, dynamic>) {
  //           return (cat['name']?.toString() ?? "") == targetCategoryName;
  //         }
  //         return false;
  //       });
  //     });
  //
  //     if (alreadyExists) {
  //       setState(() => _isCustomItemLoading = false);
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text("This category item already added. Create new order to add again."),
  //           backgroundColor: Colors.orange,
  //           duration: Duration(seconds: 4),
  //         ),
  //       );
  //       return;
  //     }
  //
  //     // ==================== USE ONLY CATEGORY TAX (As per your requirement) ====================
  //     final selectedCategory = _categoriesList.firstWhere(
  //           (cat) => (cat['name']?.toString() ?? "") == _selectedCategoryName,
  //       orElse: () => _categoriesList.isNotEmpty ? _categoriesList.first : {},
  //     );
  //
  //     final String categoryTaxClass = selectedCategory['pos_tax_class']?.toString() ?? "grocery";
  //     final double categoryTaxPercent = double.tryParse(
  //         selectedCategory['pos_tax_percent']?.toString() ?? '0') ?? 0.0;
  //
  //     // ==================== DYNAMIC DATA ====================
  //     final categories = selectedItem['categories'] is List ? selectedItem['categories'] : [];
  //     final tags = selectedItem['tags'] is List ? selectedItem['tags'] : [];
  //
  //     final normalizedSku = _skuController.text.trim().isNotEmpty
  //         ? normalizeSku(_skuController.text)
  //         : "C-${DateTime.now().millisecondsSinceEpoch}";
  //
  //     // Category Prefix in Name
  //     final String displayName = "$_selectedCategoryName - $baseItemName";
  //
  //     final customItem = {
  //       "server_item_id": null,
  //       "product_id": productId,
  //       "variation_id": 0,
  //       "type": selectedItem['type']?.toString() ?? "simple",
  //       "name": displayName,
  //       "price": price,
  //       "sku": normalizedSku,
  //
  //       "categories": categories,
  //       "tags": tags,
  //
  //       // ✅ ONLY CATEGORY TAX IS USED
  //       "tax_status": categoryTaxPercent > 0 ? "taxable" : "none",
  //       "tax_class": categoryTaxClass,
  //       "tax_rate": categoryTaxPercent,
  //       "tax_percent": categoryTaxPercent,        // For backend
  //       "applied_tax": "$_selectedCategoryName Tax",
  //
  //       "quantity": 1,
  //       "item_image": "assets/custom.png",
  //       "product_image": "assets/custom.png",
  //       AppDBConst.itemType: "custom",
  //       AppDBConst.itemName: displayName,
  //       AppDBConst.itemPrice: price,
  //       AppDBConst.itemSumPrice: price,
  //       AppDBConst.itemCount: 1,
  //     };
  //
  //     products.add(customItem);
  //
  //     // Recalculate Totals
  //     double grossTotal = 0.0;
  //     for (var p in products) {
  //       final itemPrice = (p["price"] ?? 0.0) as num;
  //       final qty = (p["quantity"] ?? 1) as num;
  //       grossTotal += itemPrice * qty;
  //     }
  //
  //     orderData["products"] = products;
  //     orderData["gross_total"] = grossTotal;
  //     orderData["net_total"] = grossTotal;
  //     orderData["net_payable"] = grossTotal;
  //
  //     await box.put(key, orderData);
  //
  //     // Cache for future scans
  //     await StorageProvider.productCache.put("sku_$normalizedSku", {"products": [customItem]});
  //
  //     // Reset UI
  //     setState(() {
  //       _isCustomItemLoading = false;
  //       _customItemPrice = "0.00";
  //       _customItemPriceController.clear();
  //       _skuController.clear();
  //       _isEnteringItemPrice = false;
  //     });
  //
  //     await _orderHelper.loadData();
  //     await _loadOrderData();
  //     OrderHelper.notifyOrderPanelToRefresh();
  //     widget.refreshOrderList?.call();
  //
  //     if (kDebugMode) {
  //       print("✅ Custom Item Added → $displayName | Tax: $categoryTaxPercent% (from Category)");
  //     }
  //
  //   } catch (e) {
  //     print("❌ Custom Item Error: $e");
  //     setState(() => _isCustomItemLoading = false);
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       SnackBar(content: Text("Error adding custom item"), backgroundColor: Colors.red),
  //     );
  //   }
  // }

// ============================================================
// REPLACE ONLY _handleAddCustomItem() in your file.
// Root cause: categories[] on the stored item holds the PRODUCT's
// own category IDs (e.g. 144), NOT the selected category ID from
// _categoriesList (e.g. 98 / 103).
// Fix: store selected_category_id as a top-level field and use
// that for the duplicate check instead.
// ============================================================

  // Future<void> _handleAddCustomItem() async {
  //   if (kDebugMode) print("🟢 [CUSTOM ITEM] START");
  //
  //   final orderHelper = OrderHelper();
  //   final int? ensuredOrderId = await orderHelper.ensureOrderExists();
  //
  //   if (ensuredOrderId == null) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(
  //         content: Text("Failed to create order"),
  //         backgroundColor: Colors.red,
  //       ),
  //     );
  //     return;
  //   }
  //
  //   // ── Price Validation ────────────────────────────────────────
  //   final cleanedPrice = _customItemPrice.replaceAll(RegExp(r'[^0-9.]'), '');
  //   final double? price = double.tryParse(cleanedPrice);
  //   if (price == null || price <= 0) {
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //       const SnackBar(
  //         content: Text("Please enter valid price"),
  //         backgroundColor: Colors.red,
  //       ),
  //     );
  //     return;
  //   }
  //
  //   // ── Category Validation ──────────────────────────────────────
  //   if (_selectedCategoryName.trim() == "Select Category" ||
  //       _selectedCategoryName.trim().isEmpty ||
  //       !_categoriesList.any((cat) =>
  //       cat['name']?.toString().trim() == _selectedCategoryName.trim())) {
  //     // ── Reset UI ─────────────────────────────────────────────
  //     setState(() {
  //       _isCustomItemLoading = false;
  //       _customItemPrice = "0.00";
  //       _customItemPriceController.clear();
  //       _skuController.clear();
  //       _isEnteringItemPrice = false;
  //       _selectedCategoryName = "Select Category"; //  Clear category after successful add
  //     });
  //   }
  //
  //   try {
  //     final box = StorageProvider.offlineOrders;
  //     final key = ensuredOrderId.toString();
  //     final rawOrder = await box.get(key) ?? {};
  //     final orderData = Map<String, dynamic>.from(rawOrder);
  //
  //     List<dynamic> products = (orderData["products"] ?? [])
  //         .map((e) => Map<String, dynamic>.from(e))
  //         .toList();
  //
  //     // ── Find selected custom item from dropdown ──────────────
  //     final selectedItem = _customItemsList.firstWhere(
  //           (item) => (item['name']?.toString() ?? "") == _selectedCustomItemName,
  //       orElse: () => _customItemsList.isNotEmpty ? _customItemsList.first : {},
  //     );
  //
  //     final String baseItemName =
  //         selectedItem['name']?.toString() ?? "Custom Item";
  //     final int selectedProductId = selectedItem['id'] ?? 60303;
  //
  //     // ── Find selected category and its tax slug ───────────────
  //     final selectedCategory = _categoriesList.firstWhere(
  //           (cat) =>
  //       (cat['name']?.toString() ?? "").trim() ==
  //           _selectedCategoryName.trim(),
  //       orElse: () => _categoriesList.isNotEmpty
  //           ? _categoriesList.first
  //           : {},
  //     );
  //
  //     final int selectedCategoryId =
  //         int.tryParse(selectedCategory['id']?.toString() ?? '0') ?? 0;
  //
  //     final double categoryTaxPercent = double.tryParse(
  //         selectedCategory['pos_tax_percent']?.toString() ?? '0') ??
  //         0.0;
  //
  //     // === ENSURE SELECTED CATEGORY TAX IS STORED ===
  //     final String posTaxClass =
  //         selectedCategory['pos_tax_class']?.toString() ?? "standard";
  //
  //     final String posTaxPercent =
  //         selectedCategory['pos_tax_percent']?.toString() ?? "0";
  //
  //     // ✅ IMPORTANT: Get the tax slug (e.g., "standard", "reduced")
  //     // Prefer pos_tax_slug from API, otherwise derive from pos_tax_class
  //     String taxSlug =
  //         selectedCategory['pos_tax_slug']?.toString() ?? '';
  //
  //     if (taxSlug.isEmpty) {
  //       final rawClass =
  //           selectedCategory['pos_tax_class']?.toString() ?? '';
  //
  //       taxSlug = rawClass.toLowerCase().replaceAll(' ', '-');
  //     }
  //
  //     // ✅ Determine if taxable (positive percent AND slug exists)
  //     final bool isTaxable =
  //         categoryTaxPercent > 0 && taxSlug.isNotEmpty;
  //
  //     final String taxStatus = isTaxable ? "taxable" : "none";
  //     final String taxClass = isTaxable ? taxSlug : "";
  //
  //     print(
  //       "🔍 ADD ATTEMPT → Product ID: $selectedProductId | Category ID: $selectedCategoryId | Tax Percent: $categoryTaxPercent% | Tax Slug: '$taxSlug' | Tax Status: $taxStatus",
  //     );
  //
  //     // ── Duplicate check using stored `selected_category_id` ──
  //     bool alreadyExists = false;
  //
  //     for (int i = 0; i < products.length; i++) {
  //       final existing = products[i];
  //
  //       final int existingProductId =
  //           int.tryParse(existing['product_id']?.toString() ?? '0') ??
  //               0;
  //
  //       final int existingSelectedCategoryId = int.tryParse(
  //           existing['selected_category_id']?.toString() ?? '0') ??
  //           0;
  //
  //       if (existingProductId == selectedProductId &&
  //           existingSelectedCategoryId == selectedCategoryId) {
  //         alreadyExists = true;
  //
  //         print(
  //           "❌ DUPLICATE DETECTED → Same Product + Same Selected Category",
  //         );
  //
  //         break;
  //       }
  //     }
  //
  //     if (alreadyExists) {
  //       setState(() {
  //         _isCustomItemLoading = false;
  //         _customItemPrice = "0.00";
  //         _customItemPriceController.text =
  //         "${TextConstants.currencySymbol}0.00";
  //         _isEnteringItemPrice = false;
  //         _selectedCategoryName = "Select Category";
  //
  //       });
  //
  //       ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //         const SnackBar(
  //           content: Text(
  //             "This item is already added. Create a new order to add it again.",
  //           ),
  //           backgroundColor: Colors.orange,
  //           duration: Duration(seconds: 1),
  //         ),
  //       );
  //
  //       return;
  //     }
  //
  //     print("✅ No duplicate → Adding new item");
  //
  //     // ── Build item with correct tax fields ─────────────────────
  //     final categories =
  //     selectedItem['categories'] is List
  //         ? selectedItem['categories']
  //         : [];
  //
  //     final tags = selectedItem['tags'] is List
  //         ? selectedItem['tags']
  //         : [];
  //
  //     final normalizedSku = _skuController.text.trim().isNotEmpty
  //         ? normalizeSku(_skuController.text)
  //         : "C-${DateTime.now().millisecondsSinceEpoch}";
  //
  //     final String displayName =
  //         "$_selectedCategoryName - $baseItemName";
  //
  //     final customItem = {
  //       "server_item_id": selectedProductId,
  //       "product_id": selectedProductId,
  //       "variation_id": 0,
  //       "type": selectedItem['type']?.toString() ?? "simple",
  //       "name": displayName,
  //       "price": price,
  //       "sku": normalizedSku,
  //       "categories": categories,
  //       "tags": tags,
  //       "selected_category_id": selectedCategoryId,
  //       "selected_category_name": _selectedCategoryName,
  //       "selected_category_tax_slug": taxSlug,
  //
  //       // 🔥 NEW: Explicitly store original pos_tax_* fields
  //       "pos_tax_class": posTaxClass,
  //       "pos_tax_percent": posTaxPercent,
  //
  //       "tax_status": taxStatus,
  //       "tax_class": taxClass,
  //       "tax_rate": categoryTaxPercent,
  //       "tax_percent": categoryTaxPercent,
  //       "applied_tax": "$_selectedCategoryName Tax",
  //
  //       "quantity": 1,
  //       "item_image": "assets/custom.png",
  //       "product_image": "assets/custom.png",
  //       AppDBConst.itemType: "custom",
  //       AppDBConst.itemName: displayName,
  //       AppDBConst.itemPrice: price,
  //       AppDBConst.itemSumPrice: price,
  //       AppDBConst.itemCount: 1,
  //     };
  //
  //     products.add(customItem);
  //
  //     // ── Recalculate totals ───────────────────────────────────
  //     double grossTotal = 0.0;
  //
  //     for (var p in products) {
  //       final itemPrice = (p["price"] ?? 0.0) as num;
  //       final qty = (p["quantity"] ?? 1) as num;
  //
  //       grossTotal += itemPrice * qty;
  //     }
  //
  //     orderData["products"] = products;
  //     orderData["gross_total"] = grossTotal;
  //     orderData["net_total"] = grossTotal;
  //     orderData["net_payable"] = grossTotal;
  //
  //     await box.put(key, orderData);
  //
  //     await StorageProvider.productCache.put(
  //       "sku_$normalizedSku",
  //       {"products": [customItem]},
  //     );
  //
  //     // ── Reset UI ─────────────────────────────────────────────
  //     setState(() {
  //       _isCustomItemLoading = false;
  //       _customItemPrice = "0.00";
  //       _customItemPriceController.clear();
  //       _skuController.clear();
  //       _isEnteringItemPrice = false;
  //       // _selectedCategoryName = "Select Category";
  //
  //
  //       // // ── Category Validation ─────────────────────────────────
  //       if (_selectedCategoryName.trim() == "Select Category" ||
  //           _selectedCategoryName.trim().isEmpty) {
  //         ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
  //           const SnackBar(
  //             content: Text("Please select a category before adding"),
  //             backgroundColor: Colors.orange,
  //             duration: Duration(seconds: 2),
  //           ),
  //         );
  //         return;
  //       }
  //
  //       setState(() => _isCustomItemLoading = true);
  //     });
  //
  //     await _orderHelper.loadData();
  //     await _loadOrderData();
  //
  //     OrderHelper.notifyOrderPanelToRefresh();
  //
  //     widget.refreshOrderList?.call();
  //
  //     print(
  //       "✅ SUCCESS: Added → $displayName | Tax Status: $taxStatus | Tax Class Slug: $taxClass",
  //     );
  //   } catch (e, stack) {
  //     print("❌ Custom Item Error: $e");
  //     print("Stack: $stack");
  //
  //     setState(() => _isCustomItemLoading = false);
  //
  //     ScaffoldMessenger.of(widget.scaffoldMessengerContext)
  //         .showSnackBar(
  //       SnackBar(
  //         content: Text("Error adding custom item"),
  //         backgroundColor: Colors.red,
  //       ),
  //     );
  //   }
  // }

  Future<void> _handleAddCustomItem() async {
    if (kDebugMode) print("🟢 [CUSTOM ITEM] START");

    // ── VALIDATION FIRST (BEFORE ANY OPERATIONS) ─────────────────
    if (_selectedCategoryName.trim() == "Select Category" ||
        _selectedCategoryName.trim().isEmpty ||
        !_categoriesList.any((cat) =>
            cat['name']?.toString().trim() == _selectedCategoryName.trim())) {
      // Reset price field
      setState(() {
        _customItemPrice = "0.00";
        _customItemPriceController.text = "${TextConstants.currencySymbol}0.00";
        _isEnteringItemPrice = false;
      });

      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        const SnackBar(
          content: Text("Please select a category before adding"),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      return; // ← EXIT EARLY
    }

    final orderHelper = OrderHelper();
    final int? ensuredOrderId = await orderHelper.ensureOrderExists();

    if (ensuredOrderId == null) {
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        const SnackBar(
          content: Text("Failed to create order"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // ── Price Validation ────────────────────────────────────────
    final cleanedPrice = _customItemPrice.replaceAll(RegExp(r'[^0-9.]'), '');
    final double? price = double.tryParse(cleanedPrice);
    if (price == null || price <= 0) {
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        const SnackBar(
          content: Text("Please enter valid price"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isCustomItemLoading = true);

    try {
      final box = StorageProvider.offlineOrders;
      final key = ensuredOrderId.toString();
      final rawOrder = await box.get(key) ?? {};
      final orderData = Map<String, dynamic>.from(rawOrder);

      List<dynamic> products = (orderData["products"] ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      // ── Find selected custom item from dropdown ──────────────
      final selectedItem = _customItemsList.firstWhere(
        (item) => (item['name']?.toString() ?? "") == _selectedCustomItemName,
        orElse: () => _customItemsList.isNotEmpty ? _customItemsList.first : {},
      );

      final String baseItemName =
          selectedItem['name']?.toString() ?? "Custom Item";
      final int selectedProductId = selectedItem['id'] ?? 60303;

      // ── Find selected category and its tax slug ───────────────
      final selectedCategory = _categoriesList.firstWhere(
        (cat) =>
            (cat['name']?.toString() ?? "").trim() ==
            _selectedCategoryName.trim(),
        orElse: () => _categoriesList.isNotEmpty ? _categoriesList.first : {},
      );

      final int selectedCategoryId =
          int.tryParse(selectedCategory['id']?.toString() ?? '0') ?? 0;
      final double categoryTaxPercent = double.tryParse(
              selectedCategory['pos_tax_percent']?.toString() ?? '0') ??
          0.0;

      final String posTaxClass =
          selectedCategory['pos_tax_class']?.toString() ?? "standard";
      final String posTaxPercent =
          selectedCategory['pos_tax_percent']?.toString() ?? "0";

      String taxSlug = selectedCategory['pos_tax_slug']?.toString() ?? '';
      if (taxSlug.isEmpty) {
        final rawClass = selectedCategory['pos_tax_class']?.toString() ?? '';
        taxSlug = rawClass.toLowerCase().replaceAll(' ', '-');
      }

      final bool isTaxable = categoryTaxPercent > 0 && taxSlug.isNotEmpty;
      final String taxStatus = isTaxable ? "taxable" : "none";
      final String taxClass = isTaxable ? taxSlug : "";

      // ── Duplicate check using stored `selected_category_id` ──
      bool alreadyExists = false;
      for (int i = 0; i < products.length; i++) {
        final existing = products[i];
        final int existingProductId =
            int.tryParse(existing['product_id']?.toString() ?? '0') ?? 0;
        final int existingSelectedCategoryId =
            int.tryParse(existing['selected_category_id']?.toString() ?? '0') ??
                0;

        if (existingProductId == selectedProductId &&
            existingSelectedCategoryId == selectedCategoryId) {
          alreadyExists = true;
          print("❌ DUPLICATE DETECTED → Same Product + Same Selected Category");
          break;
        }
      }

      if (alreadyExists) {
        setState(() {
          _isCustomItemLoading = false;
          _customItemPrice = "0.00";
          _customItemPriceController.text =
              "${TextConstants.currencySymbol}0.00";
          _isEnteringItemPrice = false;
          _selectedCategoryName = "Select Category";
        });

        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text(
                "This item is already added. Create a new order to add it again."),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 1),
          ),
        );
        return;
      }

      // ── Build item ─────────────────────────────────────────────
      final categories =
          selectedItem['categories'] is List ? selectedItem['categories'] : [];
      final tags = selectedItem['tags'] is List ? selectedItem['tags'] : [];

      final normalizedSku = _skuController.text.trim().isNotEmpty
          ? normalizeSku(_skuController.text)
          : "C-${DateTime.now().millisecondsSinceEpoch}";

      final String displayName = "$_selectedCategoryName - $baseItemName";

      final customItem = {
        "server_item_id": selectedProductId,
        "product_id": selectedProductId,
        "variation_id": 0,
        "type": selectedItem['type']?.toString() ?? "simple",
        "name": displayName,
        "price": price,
        "sku": normalizedSku,
        "categories": categories,
        "tags": tags,
        "selected_category_id": selectedCategoryId,
        "selected_category_name": _selectedCategoryName,
        "selected_category_tax_slug": taxSlug,
        "pos_tax_class": posTaxClass,
        "pos_tax_percent": posTaxPercent,
        "tax_status": taxStatus,
        "tax_class": taxClass,
        "tax_rate": categoryTaxPercent,
        "tax_percent": categoryTaxPercent,
        "applied_tax": "$_selectedCategoryName Tax",
        "quantity": 1,
        "item_image": "assets/custom.png",
        "product_image": "assets/custom.png",
        AppDBConst.itemType: "custom",
        AppDBConst.itemName: displayName,
        AppDBConst.itemPrice: price,
        AppDBConst.itemSumPrice: price,
        AppDBConst.itemCount: 1,
      };

      products.add(customItem);

      // ── Recalculate totals ───────────────────────────────────
      double grossTotal = 0.0;
      for (var p in products) {
        final itemPrice = (p["price"] ?? 0.0) as num;
        final qty = (p["quantity"] ?? 1) as num;
        grossTotal += itemPrice * qty;
      }

      orderData["products"] = products;
      orderData["gross_total"] = grossTotal;
      orderData["net_total"] = grossTotal;
      orderData["net_payable"] = grossTotal;

      await box.put(key, orderData);
      await StorageProvider.productCache.put("sku_$normalizedSku", {
        "products": [customItem]
      });

      // ── Reset UI ─────────────────────────────────────────────
      setState(() {
        _isCustomItemLoading = false;
        _customItemPrice = "0.00";
        _customItemPriceController.clear();
        _skuController.clear();
        _isEnteringItemPrice = false;
        _selectedCategoryName = "Select Category"; // Reset after successful add
        // Move away from Custom Item tab so scanning doesn't interact with dropdown UI.
        _selectedTabIndex = 0;
        _persistedTabIndex = 0;
      });

      _restoreScannerFocus();

      await _orderHelper.loadData();
      await _loadOrderData();
      OrderHelper.notifyOrderPanelToRefresh();
      widget.refreshOrderList?.call();

      print(
          "✅ SUCCESS: Added → $displayName | Tax Status: $taxStatus | Tax Class Slug: $taxClass");
    } catch (e, stack) {
      print("❌ Custom Item Error: $e");
      print("Stack: $stack");
      setState(() => _isCustomItemLoading = false);
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        SnackBar(
            content: Text("Error adding custom item: $e"),
            backgroundColor: Colors.red),
      );
    }
  }

  ///  Converts any deeply nested Map/List from Hive into JSON-safe Map<String, dynamic>
  dynamic _convertToJsonSafe(dynamic value) {
    if (value == null) return null;

    if (value is Map) {
      // Convert
      return value.map((k, v) => MapEntry(k.toString(), _convertToJsonSafe(v)));
    } else if (value is List) {
      return value.map(_convertToJsonSafe).toList();
    } else {
      return value;
    }
  }

  Future<Map<String, dynamic>?> _getPayoutProductFromIsar() async {
    // FAST PATH
    if (_productMetaInitialized && _productMetaCache.isNotEmpty) {
      for (final p in _productMetaCache.values) {
        final name = (p["fast_key_item_name"] ?? p["name"] ?? "")
            .toString()
            .toLowerCase();

        if (name.contains("payout")) {
          return p;
        }
      }
    }

    try {
      final isar = await IsarService.instance;
      final entries = await isar.isarCacheEntrys.where().findAll();

      for (final entry in entries) {
        if (!entry.key.startsWith("products_")) continue;

        final List<dynamic> products = jsonDecode(entry.json);
        for (final raw in products) {
          if (raw is! Map) continue;

          final map = Map<String, dynamic>.from(raw);
          final name = (map["fast_key_item_name"] ?? map["name"] ?? "")
              .toString()
              .toLowerCase();

          if (name.contains("payout")) {
            final pid = int.tryParse(
                (map["fast_key_product_id"] ?? map["id"])?.toString() ?? "");

            if (pid != null) {
              _productMetaCache[pid] = map;
              _productMetaInitialized = true;
            }
            return map;
          }
        }
      }
    } catch (e) {
      debugPrint("Payout Isar lookup failed → $e");
    }

    return null;
  }

  //Build #1.0.78: Explanation

  void _handleAddPayout() async {
    print("🟦 [PAYOUT] START ---- _handleAddPayout() ----");

    if (_payoutAmount.isEmpty ||
        _payoutAmount == "0.00" ||
        double.tryParse(_payoutAmount) == null) {
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        const SnackBar(
          content: Text("Invalid payout amount"),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _isPayoutLoading = true);

    try {
      final offlineBox = StorageProvider.offlineOrders;
      final productBox = StorageProvider.productCache;
      final payoutAmount = double.parse(_payoutAmount);

      final orderHelper = OrderHelper();

      final int? ensuredOrderId = await orderHelper.ensureOrderExists();

      if (ensuredOrderId == null) {
        setState(() => _isPayoutLoading = false);

        final msg = OrderHelper.lastEnsureOrderError ??
            "Unable to create order. Please try again.";
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (kDebugMode) {
        print("🆔 [PAYOUT] Active Order ID (ensured): $ensuredOrderId");
      }
      final int orderId = ensuredOrderId;
      orderHelper.activeOrderId = orderId;

      final key = orderId.toString();
      final rawExisting = await offlineBox.get(key);
      final existingOrder =
          Map<String, dynamic>.from(rawExisting is Map ? rawExisting : {});

      final payouts = (existingOrder["payouts"] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (payouts.isNotEmpty) {
        setState(() => _isPayoutLoading = false);
        ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
          const SnackBar(
            content: Text("A payout already exists for this order."),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      Map<String, dynamic>? payoutProduct = await _getPayoutProductFromIsar();

// Fallback only if not found in catalog
      payoutProduct ??= {
        "fast_key_product_id": DateTime.now().millisecondsSinceEpoch,
        "fast_key_item_name": "Payout",
        "fast_key_item_price": 0,
        "fast_key_item_image":
            "https://merchantretail.alektasolutions.com/wp-content/uploads/2025/11/payout-2-1.png",
        "type": "simple",
      };

      print("🟢 FOUND PAYOUT PRODUCT → $payoutProduct");
      final payoutEntry = {
        "order_id": orderId,
        "payout_product_id": payoutProduct["fast_key_product_id"],
        "product_name": payoutProduct["fast_key_item_name"],
        "product_image": payoutProduct["fast_key_item_image"],
        "amount": -payoutAmount,
        "type": "payout",
        "timestamp": DateTime.now().toIso8601String(),
      };

      payouts.add(payoutEntry);

      final products = (existingOrder["products"] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      double total = 0.0;
      for (var p in products) {
        total += (p["price"] ?? 0) * (p["quantity"] ?? 1);
      }

      final updatedOrder = {
        ...existingOrder,
        "products": products,
        "payouts": payouts,
        "gross_total": total + (-payoutAmount),
      };

      await offlineBox.put(key, updatedOrder);
      try {
        await CustomerDisplayHelper.updateCustomerDisplay(
          orderId,
          summaryEnabled: false,
        );

        print("📺 Customer display updated after payout");
      } catch (e) {
        print("❌ Customer display update failed: $e");
      }

      // ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
      //   SnackBar(
      //     content: Text("Payout of ₹${payoutAmount.toStringAsFixed(2)} added successfully"),
      //     backgroundColor: Colors.green,
      //   ),
      // );

      setState(() {
        _payoutAmount = "";
        _isPayoutLoading = false;
      });

      await _orderHelper.loadData();
      await _loadOrderData();
      OrderHelper.notifyOrderPanelToRefresh();
      widget.refreshOrderList?.call();

      print("✅ [PAYOUT] DONE ---- _handleAddPayout() ----");
    } catch (e, s) {
      print("🟥 [PAYOUT] ERROR: $e\n$s");
      setState(() => _isPayoutLoading = false);
      ScaffoldMessenger.of(widget.scaffoldMessengerContext).showSnackBar(
        SnackBar(
          content: Text("Error adding payout: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class TabSideClipper extends CustomClipper<Path> {
  final int selectedIndex;

  TabSideClipper({required this.selectedIndex});

  @override
  Path getClip(Size size) {
    Path path = Path();
    double tabHeight = size.height / 550;
    double selectedTabTop = selectedIndex * tabHeight;
    double selectedTabBottom = selectedTabTop + tabHeight;
    double curveRadius = 16.0; // Your specified curve radius

    path.moveTo(0, 0);
    path.lineTo(size.width, 0);

    // Top curve around selected tab
    if (selectedIndex > 0) {
      path.lineTo(size.width, selectedTabTop - curveRadius);
      // Smooth curve into the tab indent
      path.quadraticBezierTo(
          size.width, selectedTabTop, size.width - curveRadius, selectedTabTop);
      path.lineTo(size.width - curveRadius, selectedTabTop);
    } else {
      // If first tab is selected, start the indent from top
      path.lineTo(size.width - curveRadius, 0);
    }

    // Straight line along the tab indent
    path.lineTo(size.width - curveRadius, selectedTabBottom);

    // Bottom curve around selected tab
    if (selectedIndex < 4) {
      // Smooth curve out of the tab indent
      path.quadraticBezierTo(size.width, selectedTabBottom, size.width,
          selectedTabBottom + curveRadius);
      path.lineTo(size.width, size.height);
    } else {
      // If last tab is selected, end the indent at bottom
      path.lineTo(size.width, size.height);
    }

    path.lineTo(0, size.height);
    path.close();

    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => true;
}

class ContentSideClipper extends CustomClipper<Path> {
  final int selectedIndex;

  ContentSideClipper({required this.selectedIndex});

  @override
  Path getClip(Size size) {
    Path path = Path();
    double tabHeight = size.height / 4;
    double selectedTabTop = selectedIndex * tabHeight;
    double selectedTabBottom = selectedTabTop + tabHeight;
    double cornerRadius = 16.0;
    double indentDepth = 16.0;

    // Start with rounded top-left corner
    path.moveTo(cornerRadius, 0);
    path.quadraticBezierTo(0, 0, 0, cornerRadius);

    // Top part before the selected tab indent
    if (selectedIndex > 0) {
      path.lineTo(0, selectedTabTop - cornerRadius);
      // Smooth curve into the indent (curves inward)
      path.quadraticBezierTo(0, selectedTabTop, cornerRadius, selectedTabTop);
      path.quadraticBezierTo(indentDepth, selectedTabTop + cornerRadius,
          indentDepth, selectedTabTop + cornerRadius * 2);
    } else {
      // If first tab is selected, start indent from top
      path.lineTo(0, cornerRadius);
      path.quadraticBezierTo(
          cornerRadius, cornerRadius, indentDepth, cornerRadius * 2);
    }

    // Middle of the indent (straight line)
    path.lineTo(indentDepth, selectedTabBottom - cornerRadius * 2);

    // Bottom part - curve out of the selected tab indent
    path.quadraticBezierTo(indentDepth, selectedTabBottom - cornerRadius,
        cornerRadius, selectedTabBottom);
    path.quadraticBezierTo(
        0, selectedTabBottom, 0, selectedTabBottom + cornerRadius);

    // Now add the outward bulge for the tab below the selected one
    if (selectedIndex < 3) {
      double nextTabTop = selectedTabBottom + cornerRadius;
      double nextTabBottom = nextTabTop + tabHeight - (cornerRadius * 2);

      // Go down a bit then curve outward (bulge)
      path.lineTo(0, nextTabTop);
      path.quadraticBezierTo(-cornerRadius, nextTabTop + cornerRadius,
          -cornerRadius, nextTabTop + cornerRadius * 2);
      path.lineTo(-cornerRadius, nextTabBottom - cornerRadius);
      path.quadraticBezierTo(
          -cornerRadius, nextTabBottom, 0, nextTabBottom + cornerRadius);

      if (selectedIndex < 2) {
        // Continue to bottom if not the second-to-last tab
        path.lineTo(0, size.height - cornerRadius);
      } else {
        // Go to bottom
        path.lineTo(0, size.height - cornerRadius);
      }
    } else {
      // Last tab selected, just go to bottom
      path.lineTo(0, size.height - cornerRadius);
    }

    // Rounded bottom-left corner
    path.quadraticBezierTo(0, size.height, cornerRadius, size.height);
    path.lineTo(size.width, size.height);
    path.lineTo(size.width, 0);
    path.close();

    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => true;
}
// this is the end of the flow
