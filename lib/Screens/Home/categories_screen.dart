import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import 'package:intl/intl.dart';
import 'package:pinaka_pos/Database/isar_cache_entry.dart';
import '../../Blocs/Orders/order_bloc.dart';
import '../../Blocs/Search/product_search_bloc.dart';
import '../../Constants/misc_features.dart';
import '../../Database/db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Utilities/global_utility.dart';
import '../../Models/Orders/orders_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Orders/order_repository.dart';
import '../../Repositories/Search/product_search_repository.dart';
import '../../Utilities/responsive_layout.dart';
import '../../Widgets/widget_logs_toast.dart';
import '../../Widgets/widget_category_list.dart';
import '../../Widgets/widget_nested_grid_layout.dart';
import '../../Widgets/widget_order_panel.dart';
import '../../Widgets/widget_sub_category.dart';
import '../../Widgets/widget_topbar.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../../Blocs/Category/category_bloc.dart';
import '../../Repositories/Category/category_repository.dart';
import '../../Database/isar_service.dart';
import '../../Helper/api_response.dart';
import '../../Models/Category/category_model.dart';
import '../../Models/Category/category_product_model.dart';
import '../../Database/order_panel_db_helper.dart';
import '../../Constants/text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Auth/login_screen.dart';

class CategoriesScreen extends StatefulWidget {
  final int? lastSelectedIndex;
  /// When true, only the center content is shown (no TopBar, NavBar, RightOrderPanel).
  final bool embedInShell;

  const CategoriesScreen({super.key, this.lastSelectedIndex, this.embedInShell = false});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen>
    with WidgetsBindingObserver, LayoutSelectionMixin {
  final List<String> items = List.generate(18, (index) => 'Bud Light');
  int _selectedSidebarIndex = 0;
  List<int> quantities = [1, 1, 1, 1];

  bool isLoading = true;
  bool isAddingItemLoading = false;
  bool isLoadingNestedContent = false;

  final ValueNotifier<int?> fastKeyTabIdNotifier = ValueNotifier<int?>(null);
  final OrderHelper orderHelper = OrderHelper();
  final productBloc = ProductBloc(ProductRepository());
  final PinakaPreferences _preferences = PinakaPreferences();

  late CategoryBloc _categoryBloc;
  List<CategoryModel> categories = [];
  List<CategoryModel> subCategories = [];
  int? _selectedCategoryIndex;
  int? _editingCategoryIndex;
  int? _selectedSubCategoryIndex;
  final ScrollController _categoryScrollController = ScrollController();
  bool _hasAutoTappedOnce = false;

  // --- PRODUCTS + PAGINATION (client-side) ---
  static const int _pageSize = 20;
  final List<Map<String, dynamic>> _allCategoryProducts = [];
  int _visibleProductCount = _pageSize;
  bool _autoLoadCompleted = false;
  bool _isPaginating = false;
  bool _hasMoreProductsToShow = false;

  List<Map<String, dynamic>> categoryProducts = [];
  int? selectedItemIndex;
  List<int?> reorderedIndices = [];
  List<String> navigationPath = [];
  List<int> categoryHierarchy = [0];
  int currentCategoryLevel = 0;
  String? lastSelectedProduct;
  bool isShowingSubCategories = false;
  StreamSubscription? _updateOrderSubscription;
  late OrderBloc orderBloc;
  int _refreshCounter = 0;
  bool _isAutoLoading = false;

  // --- Lazy load trigger (scroll) ---
  bool _shouldEnableLazyLoad() {
    // Requirement: enable pagination only after auto-load is done
    if (!_autoLoadCompleted) return false;

    // Only when products are visible (not while subcategory list is showing)
    if (isShowingSubCategories) return false;

    // Don’t paginate while shimmer/loading
    if (isLoadingNestedContent) return false;

    return true;
  }

  void _resetPaginationState() {
    _visibleProductCount = _pageSize;
    _isPaginating = false;
    _hasMoreProductsToShow = false;
  }

  void _applyVisibleProducts({required bool reset}) {
    if (reset) {
      _visibleProductCount = _pageSize;
    }

    if (!_autoLoadCompleted) {
      // Before auto-load completes, keep legacy behavior (show all)
      categoryProducts = List<Map<String, dynamic>>.from(_allCategoryProducts);
      _hasMoreProductsToShow = false;
      reorderedIndices = List.filled(categoryProducts.length, null);
      return;
    }

    final int total = _allCategoryProducts.length;
    final int take = _visibleProductCount.clamp(0, total);

    categoryProducts = _allCategoryProducts.take(take).toList();
    _hasMoreProductsToShow = take < total;
    reorderedIndices = List.filled(categoryProducts.length, null);
  }

  Future<void> _loadMoreVisibleProducts() async {
    if (!_shouldEnableLazyLoad()) return;
    if (_isPaginating) return;
    if (!_hasMoreProductsToShow) return;

    setState(() => _isPaginating = true);
    await Future.delayed(const Duration(milliseconds: 120));

    if (!mounted) return;

    setState(() {
      _visibleProductCount += _pageSize;
      _applyVisibleProducts(reset: false);
      _isPaginating = false;
    });
  }

  bool _onProductsScrollNotification(ScrollNotification notification) {
    if (!_shouldEnableLazyLoad()) return false;

    // Only react to vertical scrolling inside product grid/list area
    if (notification.metrics.axis != Axis.vertical) return false;

    // When close to bottom, load next 50
    final remaining = notification.metrics.maxScrollExtent - notification.metrics.pixels;
    if (remaining < 300) {
      _loadMoreVisibleProducts();
    }
    return false;
  }

  void _showAutoLoadingDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final dialogBg = isDark ? const Color(0xFF1A1C2A) : Colors.white;

    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final textSecondary = isDark ? Colors.white70 : Colors.grey;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return WillPopScope(
          onWillPop: () async => false,
          child: Dialog(
            backgroundColor: dialogBg,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark ? const Color(0xFF3B1F1F) : const Color(0xFFFFEDED),
                    ),
                    child: const Icon(
                      Icons.info_outline_rounded,
                      size: 34,
                      color: Color(0xFFE74C3C),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const SizedBox(
                    height: 34,
                    width: 34,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFFE74C3C),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    "Loading Categories",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Please wait while we securely sync your latest data.\nThis may not take much time. Do not close the app.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _closeOnlyDialog() {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  final Set<String> _hiddenCategoryNames = {
    "promotions",
    "uncategorized",
    "default",
    "custom product",
  };
  List<CategoryModel> get visibleCategories {
    return categories.where((c) {
      final name = c.name.toLowerCase().trim();
      return !_hiddenCategoryNames.contains(name);
    }).toList();
  }

  void _hideAutoLoadingDialog() {
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  @override
  void initState() {
    super.initState();
    orderBloc = OrderBloc(OrderRepository());
    WidgetsBinding.instance.addObserver(this);
    _selectedSidebarIndex = widget.lastSelectedIndex ?? 1;
    _categoryBloc = CategoryBloc(CategoryRepository());
    reorderedIndices = List.filled(categoryProducts.length, null);

    _loadTopLevelCategories();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadLastSelectedCategory();
    }
  }

  Future<void> _autoTapAllCategories() async {
    if (categories.isEmpty || _hasAutoTappedOnce) return;

    _hasAutoTappedOnce = true;

    setState(() {
      _isAutoLoading = true;
      _autoLoadCompleted = false; // still not completed
    });
    _showAutoLoadingDialog();

    for (int i = 0; i < categories.length; i++) {
      if (!mounted) break;

      _scrollToCategory(i);
      await Future.delayed(const Duration(milliseconds: 250));

      if (kDebugMode) {
        print("🚀 Auto tapping category → ${categories[i].name}");
      }

      _onCategoryTapped(i);

      while (isLoadingNestedContent) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await Future.delayed(const Duration(milliseconds: 300));
    }

    _hideAutoLoadingDialog();
    if (!mounted) return;

    setState(() {
      _isAutoLoading = false;
      _autoLoadCompleted = true; // NOW enable pagination/lazy load
    });

    if (kDebugMode) {
      print("✅ Auto load completed; pagination enabled");
    }
  }

  Future<void> _loadLastSelectedCategory() async {
    final prefs = await SharedPreferences.getInstance();
    final int? index = prefs.getInt('lastSelectedCategoryIndex');

    final int safeIndex = (index != null && index >= 0 && index < categories.length) ? index : 0;

    setState(() {
      _selectedCategoryIndex = safeIndex;
      navigationPath = [categories[safeIndex].name];
      categoryHierarchy = [0, categories[safeIndex].id];
      currentCategoryLevel = 1;
      isShowingSubCategories = true;
      isLoadingNestedContent = true;

      // reset pagination on entry
      _resetPaginationState();
      _allCategoryProducts.clear();
      categoryProducts.clear();
    });

    await _loadSubCategories(categories[safeIndex].id);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCategory(safeIndex);
    });

    await prefs.setInt('lastSelectedCategoryIndex', safeIndex);
  }

  void _scrollToCategory(int index) {
    if (!_categoryScrollController.hasClients) return;

    final position = _categoryScrollController.position;
    final double itemWidth = ResponsiveLayout.getHeight(80) + 10;
    final double screenWidth = MediaQuery.of(context).size.width;

    double offset = (index * itemWidth) - (screenWidth / 2) + (itemWidth / 2);

    offset = offset.clamp(position.minScrollExtent, position.maxScrollExtent);

    _categoryScrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _saveLastSelectedCategory(int index) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lastSelectedCategoryIndex', index);
  }

  Future<void> _loadTopLevelCategories() async {
    setState(() {
      isLoading = true;
      isLoadingNestedContent = true;
    });

    _categoryBloc.fetchCategories(0);

    await for (final response in _categoryBloc.categoriesStream) {
      if (!mounted) break;

      if (response.status == Status.COMPLETED && response.data != null) {
        categories = response.data!.categories;
        for (var category in categories) {
          print("Category: ${category.name}");
        }

        setState(() {
          isLoading = false;
          isLoadingNestedContent = false;
        });

        final bool isProductCacheEmpty = await _isProductCacheEmpty();

        if (isProductCacheEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _autoTapAllCategories();
          });
        } else {
          // If cache exists, consider auto-load already done
          setState(() {
            _autoLoadCompleted = true;
          });
          await _loadLastSelectedCategory();
        }
        break;
      }

      if (response.status == Status.ERROR) {
        setState(() {
          isLoading = false;
          isLoadingNestedContent = false;
        });

        if (response.message?.contains("Unauthorised") ?? false) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => LoginScreen()),
          );
        }
        break;
      }
    }
  }

  Future<void> _loadSubCategories(int parentId) async {
    _categoryBloc.fetchCategories(parentId);

    await for (final response in _categoryBloc.categoriesStream) {
      if (!mounted) break;

      if (response.status == Status.COMPLETED && response.data != null) {
        setState(() {
          subCategories = response.data!.categories;
          isShowingSubCategories = true;

          // reset product + pagination state when moving category level
          _resetPaginationState();
          _allCategoryProducts.clear();
          categoryProducts.clear();

          _selectedSubCategoryIndex = null;
          isLoadingNestedContent = false;
        });

        if (Misc.enableCategoryProductWithSubCategoryList || subCategories.isEmpty) {
          _loadProductsByCategory(parentId);
        }
        break;
      }

      if (response.status == Status.ERROR) {
        setState(() => isLoadingNestedContent = false);
        break;
      }
    }
  }

  Future<void> _loadProductsByCategory(int categoryId) async {
    setState(() {
      isLoadingNestedContent = true;

      // reset product state for new category/subcategory selection
      _resetPaginationState();
      _allCategoryProducts.clear();
      categoryProducts.clear();
    });

    _categoryBloc.fetchProductsByCategory(categoryId);

    await for (final response in _categoryBloc.productsStream) {
      if (!mounted) break;

      if (response.status == Status.COMPLETED && response.data != null) {
        final Map<int, Map<String, dynamic>> uniqueProducts = {};

        for (final product in response.data!.products) {
          final tags = (product.tags ?? [])
              .map((t) => {
            "id": t.id,
            "name": t.name?.toLowerCase() ?? "",
            "slug": t.slug?.toLowerCase() ?? "",
          })
              .toList();

          final ageRestrictedLower = TextConstants.age_restricted.toLowerCase();
          final ageTag = tags.firstWhere(
            (t) =>
                (t["name"]?.toString() ?? "").toLowerCase() == ageRestrictedLower ||
                (t["slug"]?.toString() ?? "").toLowerCase() == ageRestrictedLower,
            orElse: () => <String, dynamic>{},
          );

          int minAge = int.tryParse(ageTag["slug"]?.toString() ?? "0") ?? 0;
          if (minAge == 0 && ageTag.isNotEmpty) {
            minAge = 18;
          }

          uniqueProducts[product.id] = {
            'fast_key_product_id': product.id,
            'fast_key_item_name': product.name,
            'fast_key_item_image': product.images.isNotEmpty ? product.images.first : '',
            'fast_key_item_price': product.price,
            'fast_key_item_sku': product.sku ?? '',
            'fast_key_item_min_age': minAge,
            'has_age_restriction': minAge > 0,
            'fast_key_item_tags': tags,
            'variations': product.variations,
            'type': product.type,
          };
        }

        setState(() {
          _allCategoryProducts
            ..clear()
            ..addAll(uniqueProducts.values);

          // Apply pagination only after auto-load completes
          _applyVisibleProducts(reset: true);

          isShowingSubCategories = false;
          isLoadingNestedContent = false;
        });
        break;
      }

      if (response.status == Status.ERROR) {
        setState(() => isLoadingNestedContent = false);
        break;
      }
    }
  }

  void _onCategoryTapped(int index) {
    if (_selectedCategoryIndex == index || index < 0 || index >= categories.length) return;

    setState(() {
      _selectedCategoryIndex = index;
      navigationPath = [categories[index].name];
      subCategories.clear();

      // reset products + pagination
      _resetPaginationState();
      _allCategoryProducts.clear();
      categoryProducts.clear();

      isShowingSubCategories = true;
      categoryHierarchy = [0, categories[index].id];
      currentCategoryLevel = 1;
      _selectedSubCategoryIndex = null;
      isLoadingNestedContent = true;
    });

    _saveLastSelectedCategory(index);
    _loadSubCategories(categories[index].id);
  }

  Future<bool> _isProductCacheEmpty() async {
    final isar = await IsarService.instance;
    final any = await isar.isarCacheEntrys.filter().keyStartsWith('products_').findFirst();
    return any == null;
  }

  void _onSubCategoryTapped(int index) {
    if (index < 0 || index >= subCategories.length) return;

    final selectedSubCategory = subCategories[index];

    setState(() {
      _selectedSubCategoryIndex = index;

      if (currentCategoryLevel < categoryHierarchy.length) {
        navigationPath = navigationPath.sublist(0, currentCategoryLevel);
        categoryHierarchy = categoryHierarchy.sublist(0, currentCategoryLevel + 1);
      }
      navigationPath.add(selectedSubCategory.name);
      categoryHierarchy.add(selectedSubCategory.id);
      currentCategoryLevel++;
      isShowingSubCategories = true;

      // reset products + pagination on deeper nav
      _resetPaginationState();
      _allCategoryProducts.clear();
      categoryProducts.clear();

      isLoadingNestedContent = true;
    });

    _loadSubCategories(selectedSubCategory.id);
  }

  void _onBackToCategories() {
    if (currentCategoryLevel > 0) {
      setState(() {
        currentCategoryLevel--;
        navigationPath.removeLast();
        categoryHierarchy.removeLast();
        isShowingSubCategories = true;

        _resetPaginationState();
        _allCategoryProducts.clear();
        categoryProducts.clear();

        _selectedSubCategoryIndex = null;
      });

      if (currentCategoryLevel == 0) {
        _loadSubCategories(categories[_selectedCategoryIndex!].id);
      } else {
        _loadSubCategories(categoryHierarchy.last);
      }
    }
  }

  Stopwatch? refreshUIStopwatch;

  void _onItemSelected(int index, bool variantAdded) async {
    if (index == 0 && showBackButton) {
      _onBackToCategories();
      return;
    }

    if (variantAdded == true) {
      if (!Misc.enableUILogMessages) {
        if (Navigator.canPop(context)) {
          _closeOnlyDialog();
        }
      }
      _refreshOrderList();
      return;
    }

    final adjustedIndex = index - (showBackButton ? 1 : 0);
    if (adjustedIndex < 0 || adjustedIndex >= categoryProducts.length) return;

    final selectedProduct = categoryProducts[adjustedIndex];
    final serverOrderId = orderHelper.activeOrderId;
    final dbOrderId = orderHelper.activeOrderId;

    try {
      _updateOrderSubscription?.cancel();
      StreamSubscription? subscription;

      Stopwatch? addProductStopwatch;
      if (Misc.enableUILogMessages) {
        addProductStopwatch = Stopwatch()..start();
      }

      subscription = orderBloc.updateOrderStream.listen((response) async {
        if (!mounted) {
          subscription?.cancel();
          return;
        }

        if (response.status == Status.LOADING) {
          const Center(child: CircularProgressIndicator());
        } else if (response.status == Status.COMPLETED) {
          if (kDebugMode) print("Item added to order $dbOrderId via API");

          if (Misc.showDebugSnackBar) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Item '${selectedProduct[AppDBConst.fastKeyItemName]}' added to order"),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );
          }

          if (Misc.enableUILogMessages && addProductStopwatch != null) {
            addProductStopwatch.stop();
            globalProcessSteps.add(
              ProcessStep(
                name: TextConstants.addProductToOrder,
                timeTaken: addProductStopwatch.elapsedMilliseconds / 1000.0,
              ),
            );
          }

          if (Misc.enableUILogMessages) {
            refreshUIStopwatch = Stopwatch()..start();
          }
          _refreshOrderList();
          subscription?.cancel();
        } else if (response.status == Status.ERROR) {
          if (Misc.enableUILogMessages && addProductStopwatch != null) {
            addProductStopwatch.stop();
            globalProcessSteps.clear();
          }
          _refreshOrderList();
          subscription?.cancel();
        }
      });

      // await orderBloc.updateOrderProducts(
      //   orderId: serverOrderId,
      //   dbOrderId: dbOrderId,
      //   lineItems: [
      //     OrderLineItem(
      //       productId: selectedProduct[AppDBConst.fastKeyProductId],
      //       quantity: 1,
      //     ),
      //   ],
      // );
    } catch (e) {
      if (kDebugMode) print("Exception in _onItemSelected: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(TextConstants.errorAddingItem),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      _updateOrderSubscription?.cancel();
      _updateOrderSubscription = null;
    }
  }

  void _onNavigationPathTapped(int index) {
    if (index < 0 || index >= navigationPath.length) return;
    if (index == currentCategoryLevel - 1) return;

    setState(() {
      navigationPath = navigationPath.sublist(0, index + 1);
      categoryHierarchy = categoryHierarchy.sublist(0, index + 2);
      currentCategoryLevel = index + 1;
      isShowingSubCategories = true;

      _resetPaginationState();
      _allCategoryProducts.clear();
      categoryProducts.clear();

      _selectedSubCategoryIndex = null;
    });

    if (index == 0) {
      _loadSubCategories(categories[_selectedCategoryIndex!].id);
    } else {
      _loadSubCategories(categoryHierarchy.last);
    }
  }

  void _refreshOrderList() {
    setState(() {
      _refreshCounter++;
    });

    if (Misc.enableUILogMessages && refreshUIStopwatch != null) {
      refreshUIStopwatch?.stop();
      globalProcessSteps.add(
        ProcessStep(
          name: TextConstants.refreshDBUITime,
          timeTaken: refreshUIStopwatch!.elapsedMilliseconds / 1000.0,
        ),
      );
    }

    if (Misc.enableUILogMessages && globalProcessSteps.isNotEmpty) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return LogsToast(
            steps: globalProcessSteps,
            onClose: () {
              globalProcessSteps.clear();
              Navigator.of(dialogContext).pop();
            },
          );
        },
      );
    }
  }

  bool get showBackButton => currentCategoryLevel >= 2;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _categoryBloc.dispose();
    orderBloc.dispose();
    fastKeyTabIdNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visibleCategories = categories.where((c) {
      final name = c.name.toLowerCase().trim();
      return !_hiddenCategoryNames.contains(name);
    }).toList();

    final categoryListItems = visibleCategories.map((category) {
      return {
        'title': category.name,
        'image': category.image ?? 'assets/default.png',
        'itemCount': category.count,
      };
    }).toList();

    final subCategoryListItems = subCategories.map((subCategory) {
      return {
        'name': subCategory.name,
        'image': subCategory.image ?? 'assets/default.png',
        'count': subCategory.count,
      };
    }).toList();

    Widget buildProductsWidget(Widget child) {
      return NotificationListener<ScrollNotification>(
        onNotification: _onProductsScrollNotification,
        child: child,
      );
    }

    if (widget.embedInShell) {
      return Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          CategoryList(
            isHorizontal: true,
            isLoading: isLoading,
            isAddButtonEnabled: false,
            categories: categoryListItems,
            selectedIndex: _selectedCategoryIndex == null ? null : visibleCategories.indexWhere((c) => c.id == categories[_selectedCategoryIndex!].id),
            editingIndex: _editingCategoryIndex,
            scrollController: _categoryScrollController,
            onAddButtonPressed: null,
            onCategoryTapped: (uiIndex) {
              final selectedCategory = visibleCategories[uiIndex];
              final realIndex = categories.indexWhere((c) => c.id == selectedCategory.id);
              if (realIndex != -1) _onCategoryTapped(realIndex);
            },
            onReorder: (oldIndex, newIndex) {
              setState(() {
                final List<CategoryModel> tempCategories = List.from(categories);
                final item = tempCategories.removeAt(oldIndex);
                tempCategories.insert(newIndex, item);
                categories = tempCategories;
                if (_selectedCategoryIndex == oldIndex) {
                  _selectedCategoryIndex = newIndex;
                } else if (oldIndex < _selectedCategoryIndex! && newIndex >= _selectedCategoryIndex!) {
                  _selectedCategoryIndex = _selectedCategoryIndex! - 1;
                } else if (oldIndex > _selectedCategoryIndex! && newIndex <= _selectedCategoryIndex!) {
                  _selectedCategoryIndex = _selectedCategoryIndex! + 1;
                }
              });
            },
          ),
          if (currentCategoryLevel > 0)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                child: Container(
                  margin: const EdgeInsets.only(left: 10, right: 10, top: 0, bottom: 0),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1D1C2C) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).brightness == Brightness.dark ? Colors.black.withOpacity(0.3) : Colors.black.withOpacity(0.05),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (navigationPath.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 5, 10, 4),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: List.generate(navigationPath.length, (index) {
                                final isDark = Theme.of(context).brightness == Brightness.dark;
                                return GestureDetector(
                                  onTap: () => _onNavigationPathTapped(index),
                                  child: Row(
                                    children: [
                                      Text(navigationPath[index], style: TextStyle(fontSize: 16, fontFamily: 'poppins', fontWeight: FontWeight.w800, color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF4C5F7D))),
                                      if (index < navigationPath.length - 1)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                          child: Icon(Icons.arrow_forward_ios_rounded, size: 16, color: isDark ? const Color(0xFFB0B0B0) : Colors.blue),
                                        ),
                                    ],
                                  ),
                                );
                              }),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10.0),
                        child: Divider(thickness: 3, color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2C2C2E) : const Color(0xFFF1F1F3)),
                      ),
                      Expanded(
                        child: Misc.enableCategoryProductWithSubCategoryList
                            ? Column(
                          children: [
                            SizedBox(
                              height: 140,
                              child: SubCategoryGridWidget(
                                isLoading: isLoadingNestedContent,
                                subCategories: subCategoryListItems,
                                selectedSubCategoryIndex: _selectedSubCategoryIndex,
                                onSubCategoryTapped: _onSubCategoryTapped,
                              ),
                            ),
                            Expanded(
                              child: buildProductsWidget(
                                NestedGridWidget(
                                  isPaginating: _isPaginating,
                                  productBloc: productBloc,
                                  orderHelper: orderHelper,
                                  isHorizontal: true,
                                  isLoading: isLoadingNestedContent,
                                  showAddButton: false,
                                  showBackButton: showBackButton,
                                  items: categoryProducts,
                                  selectedItemIndex: selectedItemIndex,
                                  reorderedIndices: reorderedIndices,
                                  onAddButtonPressed: null,
                                  onBackButtonPressed: _onBackToCategories,
                                  onItemTapped: (index, {bool? variantAdded}) => _onItemSelected(index, variantAdded ?? false),
                                  onReorder: (oldIndex, newIndex) {
                                    if (oldIndex == 0 || newIndex == 0) return;
                                    final adjustedOldIndex = oldIndex - (showBackButton ? 1 : 0);
                                    final adjustedNewIndex = newIndex - (showBackButton ? 1 : 0);
                                    if (adjustedOldIndex < 0 || adjustedNewIndex < 0 || adjustedOldIndex >= categoryProducts.length || adjustedNewIndex >= categoryProducts.length) return;
                                    setState(() {
                                      categoryProducts = List<Map<String, dynamic>>.from(categoryProducts);
                                      final item = categoryProducts.removeAt(adjustedOldIndex);
                                      categoryProducts.insert(adjustedNewIndex, item);
                                      reorderedIndices = List.filled(categoryProducts.length, null);
                                      reorderedIndices[adjustedNewIndex] = adjustedNewIndex;
                                      selectedItemIndex = adjustedNewIndex;
                                    });
                                  },
                                  onDeleteItem: (index) {},
                                  onCancelReorder: () => setState(() => reorderedIndices = List.filled(categoryProducts.length, null)),
                                  showDeleteButton: false,
                                ),
                              ),
                            ),
                          ],
                        )
                            : buildProductsWidget(
                          NestedGridWidget(
                            isPaginating: _isPaginating,
                            productBloc: productBloc,
                            orderHelper: orderHelper,
                            isHorizontal: true,
                            isLoading: isLoadingNestedContent,
                            showAddButton: false,
                            showBackButton: showBackButton,
                            items: categoryProducts,
                            selectedItemIndex: selectedItemIndex,
                            reorderedIndices: reorderedIndices,
                            onAddButtonPressed: null,
                            onBackButtonPressed: _onBackToCategories,
                            onItemTapped: (index, {bool? variantAdded}) => _onItemSelected(index, variantAdded ?? false),
                            onReorder: (oldIndex, newIndex) {
                              if (oldIndex == 0 || newIndex == 0) return;
                              final adjustedOldIndex = oldIndex - (showBackButton ? 1 : 0);
                              final adjustedNewIndex = newIndex - (showBackButton ? 1 : 0);
                              if (adjustedOldIndex < 0 || adjustedNewIndex < 0 || adjustedOldIndex >= categoryProducts.length || adjustedNewIndex >= categoryProducts.length) return;
                              setState(() {
                                categoryProducts = List<Map<String, dynamic>>.from(categoryProducts);
                                final item = categoryProducts.removeAt(adjustedOldIndex);
                                categoryProducts.insert(adjustedNewIndex, item);
                                reorderedIndices = List.filled(categoryProducts.length, null);
                                reorderedIndices[adjustedNewIndex] = adjustedNewIndex;
                                selectedItemIndex = adjustedNewIndex;
                              });
                            },
                            onDeleteItem: (index) {},
                            onCancelReorder: () => setState(() => reorderedIndices = List.filled(categoryProducts.length, null)),
                            showDeleteButton: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }

    // Widget buildProductsWidget(Widget child) {
    //   // Wrap the products area to detect scrolling and lazy load more
    //   return NotificationListener<ScrollNotification>(
    //     onNotification: _onProductsScrollNotification,
    //     child: Stack(
    //       children: [
    //         child,
    //         if (_shouldEnableLazyLoad() && _isPaginating)
    //           Align(
    //             alignment: Alignment.bottomCenter,
    //             child: Padding(
    //               padding: const EdgeInsets.only(bottom: 8),
    //               child: Container(
    //                 padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    //                 decoration: BoxDecoration(
    //                   color: Theme.of(context).brightness == Brightness.dark
    //                       ? const Color(0xFF2C2C2E)
    //                       : Colors.white,
    //                   borderRadius: BorderRadius.circular(999),
    //                   boxShadow: [
    //                     BoxShadow(
    //                       color: Colors.black.withOpacity(0.08),
    //                       blurRadius: 10,
    //                       offset: const Offset(0, 4),
    //                     )
    //                   ],
    //                 ),
    //                 child: const SizedBox(
    //                   width: 18,
    //                   height: 18,
    //                   child: CircularProgressIndicator(
    //                     strokeWidth: 2.2,
    //                     color: Color(0xFFE74C3C),
    //                   ),
    //                 ),
    //               ),
    //             ),
    //           ),
    //
    //       ],
    //     ),
    //   );
    // }

    return Scaffold(
      body: Column(
        children: [
          TopBar(
            screen: Screen.CATEGORY,
            onModeChanged: () async {
              String newLayout;
              if (sidebarPosition == SidebarPosition.left) {
                newLayout = SharedPreferenceTextConstants.navRightOrderLeft;
              } else if (sidebarPosition == SidebarPosition.right) {
                newLayout = SharedPreferenceTextConstants.navBottomOrderLeft;
              } else {
                newLayout = orderPanelPosition == OrderPanelPosition.left
                    ? SharedPreferenceTextConstants.navBottomOrderRight
                    : SharedPreferenceTextConstants.navLeftOrderRight;
              }

              PinakaPreferences.layoutSelectionNotifier.value = newLayout;
              await UserDbHelper().saveUserSettings({AppDBConst.layoutSelection: newLayout}, modeChange: true);
              setState(() {});
            },
            onProductSelected: (product) async {
              try {
                if (kDebugMode) {
                  print("###### serverOrderId: ${orderHelper.activeOrderId}");
                }
                _refreshOrderList();
              } catch (e, s) {
                if (kDebugMode) print("Exception in onProductSelected: $e, Stack: $s");
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(TextConstants.errorAddingItem),
                    backgroundColor: Colors.red,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
          const Divider(color: Colors.grey, thickness: 0.4, height: 1),
          Expanded(
            child: Row(
              children: [
                if (sidebarPosition == SidebarPosition.left)
                  custom_widgets.NavigationBar(
                    selectedSidebarIndex: _selectedSidebarIndex,
                    onSidebarItemSelected: (index) {
                      setState(() {
                        _selectedSidebarIndex = index;
                      });
                    },
                    isVertical: true,
                  ),
                if (sidebarPosition == SidebarPosition.right ||
                    (sidebarPosition == SidebarPosition.bottom && orderPanelPosition == OrderPanelPosition.left))
                  RightOrderPanel(
                    key: const ValueKey('order_panel'),
                    quantities: quantities,
                    refreshOrderList: _refreshOrderList,
                    refreshKey: _refreshCounter,
                  ),
                Expanded(
                  child: Column(
                    children: [
                      CategoryList(
                        isHorizontal: true,
                        isLoading: isLoading,
                        isAddButtonEnabled: false,
                        categories: categoryListItems,
                        selectedIndex: _selectedCategoryIndex == null
                            ? null
                            : visibleCategories.indexWhere(
                              (c) => c.id == categories[_selectedCategoryIndex!].id,
                        ),
                        editingIndex: _editingCategoryIndex,
                        scrollController: _categoryScrollController,
                        onAddButtonPressed: null,
                        onCategoryTapped: (uiIndex) {
                          final selectedCategory = visibleCategories[uiIndex];
                          final realIndex = categories.indexWhere((c) => c.id == selectedCategory.id);

                          if (realIndex != -1) {
                            _onCategoryTapped(realIndex);
                          }
                        },
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            final List<CategoryModel> tempCategories = List.from(categories);
                            final item = tempCategories.removeAt(oldIndex);
                            tempCategories.insert(newIndex, item);
                            categories = tempCategories;

                            if (_selectedCategoryIndex == oldIndex) {
                              _selectedCategoryIndex = newIndex;
                            } else if (oldIndex < _selectedCategoryIndex! && newIndex >= _selectedCategoryIndex!) {
                              _selectedCategoryIndex = _selectedCategoryIndex! - 1;
                            } else if (oldIndex > _selectedCategoryIndex! && newIndex <= _selectedCategoryIndex!) {
                              _selectedCategoryIndex = _selectedCategoryIndex! + 1;
                            }
                          });
                        },
                      ),
                      if (currentCategoryLevel > 0)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                            child: Container(
                              margin: const EdgeInsets.only(left: 10, right: 10, top: 0, bottom: 0),
                              decoration: BoxDecoration(
                                color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1D1C2C) : Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? Colors.black.withOpacity(0.3)
                                        : Colors.black.withOpacity(0.05),
                                    blurRadius: 6,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (navigationPath.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 5, 10, 4),
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children: List.generate(navigationPath.length, (index) {
                                            final isDark = Theme.of(context).brightness == Brightness.dark;

                                            return GestureDetector(
                                              onTap: () => _onNavigationPathTapped(index),
                                              child: Row(
                                                children: [
                                                  Text(
                                                    navigationPath[index],
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontFamily: 'poppins',
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF4C5F7D),
                                                    ),
                                                  ),
                                                  if (index < navigationPath.length - 1)
                                                    Padding(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                                      child: Icon(
                                                        Icons.arrow_forward_ios_rounded,
                                                        size: 16,
                                                        color: isDark ? const Color(0xFFB0B0B0) : Colors.blue,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            );
                                          }),
                                        ),
                                      ),
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10.0),
                                    child: Divider(
                                      thickness: 3,
                                      color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2C2C2E) : const Color(0xFFF1F1F3),
                                    ),
                                  ),
                                  Expanded(
                                    child: Misc.enableCategoryProductWithSubCategoryList
                                        ? Column(
                                      children: [
                                        SizedBox(
                                          height: 140,
                                          child: SubCategoryGridWidget(
                                            isLoading: isLoadingNestedContent,
                                            subCategories: subCategoryListItems,
                                            selectedSubCategoryIndex: _selectedSubCategoryIndex,
                                            onSubCategoryTapped: _onSubCategoryTapped,
                                          ),
                                        ),
                                        Expanded(
                                          child: buildProductsWidget(
                                            NestedGridWidget(
                                              isPaginating: _isPaginating,
                                              productBloc: productBloc,
                                              orderHelper: orderHelper,
                                              isHorizontal: true,
                                              isLoading: isLoadingNestedContent,
                                              showAddButton: false,
                                              showBackButton: showBackButton,
                                              items: categoryProducts,
                                              selectedItemIndex: selectedItemIndex,
                                              reorderedIndices: reorderedIndices,
                                              onAddButtonPressed: null,
                                              onBackButtonPressed: _onBackToCategories,
                                              onItemTapped: (index, {bool? variantAdded}) =>
                                                  _onItemSelected(index, variantAdded ?? false),
                                              onReorder: (oldIndex, newIndex) {
                                                if (oldIndex == 0 || newIndex == 0) return;
                                                final adjustedOldIndex = oldIndex - (showBackButton ? 1 : 0);
                                                final adjustedNewIndex = newIndex - (showBackButton ? 1 : 0);
                                                if (adjustedOldIndex < 0 ||
                                                    adjustedNewIndex < 0 ||
                                                    adjustedOldIndex >= categoryProducts.length ||
                                                    adjustedNewIndex >= categoryProducts.length) {
                                                  return;
                                                }
                                                setState(() {
                                                  categoryProducts = List<Map<String, dynamic>>.from(categoryProducts);
                                                  final item = categoryProducts.removeAt(adjustedOldIndex);
                                                  categoryProducts.insert(adjustedNewIndex, item);
                                                  reorderedIndices = List.filled(categoryProducts.length, null);
                                                  reorderedIndices[adjustedNewIndex] = adjustedNewIndex;
                                                  selectedItemIndex = adjustedNewIndex;
                                                });
                                              },
                                              onDeleteItem: (index) {},
                                              onCancelReorder: () {
                                                setState(() {
                                                  reorderedIndices = List.filled(categoryProducts.length, null);
                                                });
                                              },
                                              showDeleteButton: false,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                        : buildProductsWidget(
                                      NestedGridWidget(
                                        isPaginating: _isPaginating,
                                        productBloc: productBloc,
                                        orderHelper: orderHelper,
                                        isHorizontal: true,
                                        isLoading: isLoadingNestedContent,
                                        showAddButton: false,
                                        showBackButton: showBackButton,
                                        items: categoryProducts,
                                        selectedItemIndex: selectedItemIndex,
                                        reorderedIndices: reorderedIndices,
                                        onAddButtonPressed: null,
                                        onBackButtonPressed: _onBackToCategories,
                                        onItemTapped: (index, {bool? variantAdded}) =>
                                            _onItemSelected(index, variantAdded ?? false),
                                        onReorder: (oldIndex, newIndex) {
                                          if (oldIndex == 0 || newIndex == 0) return;
                                          final adjustedOldIndex = oldIndex - (showBackButton ? 1 : 0);
                                          final adjustedNewIndex = newIndex - (showBackButton ? 1 : 0);
                                          if (adjustedOldIndex < 0 ||
                                              adjustedNewIndex < 0 ||
                                              adjustedOldIndex >= categoryProducts.length ||
                                              adjustedNewIndex >= categoryProducts.length) {
                                            return;
                                          }
                                          setState(() {
                                            categoryProducts = List<Map<String, dynamic>>.from(categoryProducts);
                                            final item = categoryProducts.removeAt(adjustedOldIndex);
                                            categoryProducts.insert(adjustedNewIndex, item);
                                            reorderedIndices = List.filled(categoryProducts.length, null);
                                            reorderedIndices[adjustedNewIndex] = adjustedNewIndex;
                                            selectedItemIndex = adjustedNewIndex;
                                          });
                                        },
                                        onDeleteItem: (index) {},
                                        onCancelReorder: () {
                                          setState(() {
                                            reorderedIndices = List.filled(categoryProducts.length, null);
                                          });
                                        },
                                        showDeleteButton: false,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (sidebarPosition != SidebarPosition.right &&
                    !(sidebarPosition == SidebarPosition.bottom && orderPanelPosition == OrderPanelPosition.left))
                  RightOrderPanel(
                    key: const ValueKey('order_panel'),
                    quantities: quantities,
                    refreshOrderList: _refreshOrderList,
                    refreshKey: _refreshCounter,
                  ),
                if (sidebarPosition == SidebarPosition.right)
                  custom_widgets.NavigationBar(
                    selectedSidebarIndex: _selectedSidebarIndex,
                    onSidebarItemSelected: (index) {
                      setState(() {
                        _selectedSidebarIndex = index;
                      });
                    },
                    isVertical: true,
                  ),
              ],
            ),
          ),
          if (sidebarPosition == SidebarPosition.bottom)
            custom_widgets.NavigationBar(
              selectedSidebarIndex: _selectedSidebarIndex,
              onSidebarItemSelected: (index) {
                setState(() {
                  _selectedSidebarIndex = index;
                });
              },
              isVertical: false,
            ),
        ],
      ),
    );
  }
}