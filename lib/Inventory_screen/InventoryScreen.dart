import 'dart:convert';
import 'dart:io';
import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import '../../Blocs/Auth/shift_bloc.dart';
import '../../Constants/text.dart';
import '../../Database/db_helper.dart';
import '../../Database/user_db_helper.dart';
import '../../Helper/Extentions/nav_layout_manager.dart';
import '../../Helper/Extentions/theme_notifier.dart';
import '../../Models/Auth/shift_summary_model.dart';
import '../../Preferences/pinaka_preferences.dart';
import '../../Repositories/Auth/shift_repository.dart';
import '../../Widgets/widget_topbar.dart';
import '../../Widgets/widget_navigation_bar.dart' as custom_widgets;
import '../Widgets/widget_alert_popup_dialogs.dart';
import 'Inventory_Tags/inventory_tag_Widget.dart';
import 'Inventory_Tags/inventory_tag_entity.dart';
import 'add_product_toinventory/add_product_inventory_bloc/add_product_inventory_bloc.dart';
import 'add_product_toinventory/add_product_inventory_bloc/add_product_inventory_event.dart';
import 'add_product_toinventory/add_product_inventory_bloc/add_product_inventory_state.dart';
import 'add_product_toinventory/add_product_inventory_entity.dart';
import 'add_product_toinventory/add_product_inventory_get_usecase.dart';
import 'add_product_toinventory/add_product_inventory_remote_data_source.dart';
import 'add_product_toinventory/add_product_inventory_repository_impl.dart';
import 'image_upload_repository.dart';
import 'inventory_Tax/inventory_tax_screen.dart';

import 'inventory_attribute_items/inventory_attribute_items_remote_data_source.dart';
import 'inventory_attributes/inventory_attributes_entity.dart';
import 'inventory_attributes/inventory_attributes_widgets.dart';
import 'inventory_categories/inventory_categories_widgets.dart';
import 'inventory_get_product_types/inventory_get_product_types_widget.dart';

class InventoryScreen extends StatefulWidget {
  final int? lastSelectedIndex;
  const InventoryScreen({super.key, this.lastSelectedIndex});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen>
    with LayoutSelectionMixin {
  final _formKey = GlobalKey<FormState>();
  InventoryAttributesEntity? _lastSelectedAttribute;

  // Basic Information Controllers
  final TextEditingController _skuController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _regularPriceController = TextEditingController();
  final TextEditingController _salePriceController = TextEditingController();
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _taxClassController = TextEditingController();

  // Image picker
  final ImagePicker _picker = ImagePicker();
  File? _imageFile;
  List<int>? _imageBytes;

  // Product Type
  String? _selectedProductType;
  final FocusNode _skuFocusNode = FocusNode();  // ← Add this line

  // Category, Tag, Tax selection
  dynamic _selectedCategory;
  dynamic _selectedTax;
  final List<dynamic> _selectedTags = [];

  // Flags
  bool _hasVariablePrice = false;
  bool _manageStock = true;
  String _priceType = 'Fixed Price';

  // UI State
  int _selectedTab = 0;
  int _selectedSidebarIndex = 3;
  late ShiftBloc shiftBloc;
  final PinakaPreferences _preferences = PinakaPreferences();

  // Variants Data
  List<Map<String, dynamic>> _variants = [];

  // Attribute data for current variant being edited/added
  Map<String, dynamic>? _currentVariantAttribute;
  Map<String, dynamic>? _currentVariantAttributeItem;

  String? _selectedItemSlug;

  List<Map<String, dynamic>> _currentAttributes = [
    {'id': '1', 'unit': 'units', 'name': ''}
  ];
  String _currentVariantName = '';
  String _currentStock = '';
  String _currentRegularPrice = '';
  String _currentSalePrice = '';
  File? _currentImageFile;
  String? _selectedItemName;

  // Current variant index for editing
  int _currentVariantIndex = -1;

  // Add Product BLoC
  late AddProductInventoryTaxBloc _addProductBloc;

  // Controllers
  late TextEditingController _variantNameController;
  late TextEditingController _stockController;
  late TextEditingController _variantRegularPriceController;
  late TextEditingController _variantSalePriceController;

  List<TextEditingController> _attributeControllers = [];

  bool _showUnitNameInput = false;
  int  _activeAddItemAttrIdx = -1;
  final TextEditingController _unitNameInputController =
  TextEditingController();

  // Validation & Loading
  final Map<String, String?> _fieldErrors = {};
  bool _isSaving = false;
  List<Map<String, dynamic>> _currentVariantAttributes = [];

  // Add this to your existing state variables
  List<Map<String, dynamic>> _variantAttributes = [
    {
      'attribute': null,
      'attributeItem': null,
      'selectedSlug': null,
    }
  ];

  late final ImageUploadRepository _imageUploadRepo;




  @override
  void initState() {
    super.initState();
    _variantNameController = TextEditingController(text: _currentVariantName);
    _stockController = TextEditingController(text: _currentStock);
    _variantRegularPriceController =
        TextEditingController(text: _currentRegularPrice);
    _variantSalePriceController =
        TextEditingController(text: _currentSalePrice);
    _updateAttributeControllers();

    _selectedSidebarIndex = widget.lastSelectedIndex ?? 3;
    shiftBloc = ShiftBloc(ShiftRepository());

    _initializeAddProductBloc();

    _imageUploadRepo = ImageUploadRepository();
    //
    // WidgetsBinding.instance.addPostFrameCallback((_) {
    //   if (mounted) {
    //     FocusScope.of(context).requestFocus(_skuFocusNode);
    //   }
    // });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusScope.of(context).unfocus(); // ✅ ensures no keyboard
      }
    });
  }
  bool _hasEnteredValues() {
    return _variantNameController.text.isNotEmpty ||
        _stockController.text.isNotEmpty ||
        _variantRegularPriceController.text.isNotEmpty ||
        _variantSalePriceController.text.isNotEmpty ||
        _selectedCategory != null ||   // ✅ ADD THIS
        _selectedTags.isNotEmpty ||    // (optional but good)
        _selectedTax != null;          // (optional)
  }
  Future<bool> _handleBack() async {
    if (_hasEnteredValues()) {
      bool shouldProceed = false;

      await CustomDialog.showAreYouSure(
        context,
        description: "You have entered cash values. Do you want to discard and go back?",
        confirmText: "Yes, Confirm",
        cancelText: "No, Keep it",
        confirm: () {
          shouldProceed = true;
          Navigator.of(context).pop();
        },
      );

      if (shouldProceed) {
        Navigator.of(context).maybePop(); // for back button
      }

      return shouldProceed;
    } else {
      Navigator.of(context).maybePop();
      return true;
    }
  }

  void _handleUnitNameCreate() async {
    final name = _unitNameInputController.text.trim();
    if (name.isEmpty) return;

    final slug = name.toLowerCase().replaceAll(' ', '-');

    // Get the attributeId from the active row
    int? attributeId;
    if (_activeAddItemAttrIdx >= 0 &&
        _activeAddItemAttrIdx < _variantAttributes.length) {
      final attr = _variantAttributes[_activeAddItemAttrIdx]['attribute'];
      attributeId = attr?['id'] as int?;
    }

    //  Call API to create the term if attributeId is available
    if (attributeId != null) {
      try {
        final api = InventoryAttributeItemsApi();
        final newTerm = await api.createTerm(
          attributeId: attributeId,
          name: name,
          slug: slug,
        );

        if (kDebugMode) print('Term created: ${newTerm.name} (${newTerm.slug})');
      } catch (e) {
        if (kDebugMode) print('Failed to create term: $e');

      }
    }

    setState(() {
      if (_activeAddItemAttrIdx >= 0 &&
          _activeAddItemAttrIdx < _variantAttributes.length) {
        _variantAttributes[_activeAddItemAttrIdx]['selectedSlug'] = slug;
        _variantAttributes[_activeAddItemAttrIdx]['attributeItem'] = {
          'slug': slug,
          'name': name,
        };
      } else {
        _variantAttributes.add({
          'attribute': null,
          'attributeItem': {'slug': slug, 'name': name},
          'selectedSlug': slug,
        });
      }

      _showUnitNameInput = false;
      _activeAddItemAttrIdx = -1;
      _unitNameInputController.clear();
    });
  }

  void _updateAttributeControllers() {
    for (var controller in _attributeControllers) {
      controller.dispose();
    }
    _attributeControllers = _currentAttributes.map((attr) {
      return TextEditingController(text: attr['name'] ?? '');
    }).toList();
  }

  @override
  void dispose() {
    _variantNameController.dispose();
    _stockController.dispose();
    _variantRegularPriceController.dispose();
    _variantSalePriceController.dispose();
    _regularPriceController.dispose();
    _salePriceController.dispose();
    for (var controller in _attributeControllers) {
      controller.dispose();
    }
    super.dispose();

    _skuFocusNode.dispose();

  }

  void _initializeAddProductBloc() {
    final remoteDataSource = AddProductInventoryTaxRemoteDataSource();
    final repository = AddProductInventoryTaxRepositoryImpl(
        remoteDataSource: remoteDataSource);
    final useCase = AddProductInventoryTaxGetUseCase(repository: repository);
    _addProductBloc = AddProductInventoryTaxBloc(addProductUseCase: useCase);
  }

  Future<void> _pickImage() async {
    final XFile? image =
    await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (image == null) return;

    final bytes = await image.readAsBytes();
    final extension = image.path.split('.').last.toLowerCase();

    img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return;
    final resized = img.copyResize(decoded, width: 800);

    late List<int> finalBytes;
    if (extension == 'png') {
      finalBytes = img.encodePng(resized, level: 6);
    } else {
      finalBytes = img.encodeJpg(resized, quality: 80);
    }

    setState(() {
      _imageFile = File(image.path);
      _imageBytes = finalBytes;
    });
  }

  // Future<String?> _uploadImage(String filename, List<int> bytes) async {
  //   try {
  //     const String url = 'https://merchantretail.alektasolutions.com/wp-json/wp/v2/media';
  //     const String username = 'ck_xxx'; // ← replace with real keys
  //     const String password = 'cs_xxx';
  //
  //     final request = http.MultipartRequest('POST', Uri.parse(url));
  //     request.headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  //     request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
  //
  //     final response = await request.send();
  //
  //     if (response.statusCode == 201) {
  //       final respStr = await response.stream.bytesToString();
  //       final data = jsonDecode(respStr);
  //       return data['source_url'];
  //     } else {
  //       print('Image upload failed → ${response.statusCode} ${await response.stream.bytesToString()}');
  //       return null;
  //     }
  //   } catch (e) {
  //     print('Image upload exception: $e');
  //     return null;
  //   }
  // }

  Future<String?> _uploadImageForProduct(File imageFile,
      {String? customFileName}) async {
    final url = await _imageUploadRepo.uploadImage(
      imageFile: imageFile,
      fileName: customFileName,
    );
    return url;
  }

  String? _validateForm() {
    _fieldErrors.clear();

    if (_nameController.text.trim().isEmpty) {
      _fieldErrors['name'] = 'Product name is required';
    }
    // if (_selectedCategory == null) {
    //   _fieldErrors['category'] = 'Category is required';
    // }
    if (_selectedProductType == null || _selectedProductType!.isEmpty) {
      _fieldErrors['productType'] = 'Product type is required';
    }

    if (_selectedProductType?.toLowerCase() == 'variable') {
      if (_variants.isEmpty) {
        _fieldErrors['variants'] =
        'At least one variant is required for variable products';
      }
    } else {
      final cleanReg = _regularPriceController.text
          .trim()
          .replaceAll(RegExp(r'[^0-9.]'), '');
      final regPrice = double.tryParse(cleanReg) ?? 0.0;
      // if (regPrice <= 0) {
      //   _fieldErrors['regularPrice'] = 'Regular price must be greater than 0';
      // }
    }

    return _fieldErrors.isNotEmpty ? _fieldErrors.values.first : null;
  }

  // Future<AddProductInventoryTaxEntity?> _buildProductEntity() async {
  //   final validationError = _validateForm();
  //   if (validationError != null) return null;
  //
  //   // ── Main product image ────────────────────────────────────────
  //   String mainImageUrl = 'https://merchantretail.alektasolutions.com/wp-content/uploads/2025/12/biryani-removebg-preview-1.png';
  //
  //   if (_imageFile != null) {
  //     final uploadedUrl = await _uploadImageForProduct(
  //       _imageFile!,
  //       customFileName: 'product-${DateTime
  //           .now()
  //           .millisecondsSinceEpoch}.jpg',
  //
  //     );
  //     if (uploadedUrl != null) {
  //       mainImageUrl = uploadedUrl;
  //       print('╔═══════════════════════════════════════════════');
  //       print('║               UPLOAD SUCCESS                  ║');
  //       print('╚═══════════════════════════════════════════════');
  //       print('URL: $mainImageUrl');
  //     } else {
  //       // Optional: show snackbar or log
  //       print('Main image upload failed → using fallback');
  //     }
  //   }
  //
  //   // ── Categories & Tags ─────────────────────────────────────────
  //   final List<Map<String, dynamic>> categories = _selectedCategory != null
  //       ? [{'id': _selectedCategory.id ?? 0}]
  //       : [];
  //
  //   final List<Map<String, dynamic>> tags = [];
  //   final Set<String> seenSlugs = {};
  //   for (final tag in _selectedTags) {
  //     final slug = (tag.slug ?? '').trim();
  //     if (slug.isEmpty || seenSlugs.contains(slug)) continue;
  //     seenSlugs.add(slug);
  //     tags.add({
  //       'id': tag.id ?? 0,
  //       'name': tag.name?.trim() ?? slug,
  //       'slug': slug,
  //     });
  //   }
  //
  //   // ── Images ────────────────────────────────────────────────────
  //   final List<Map<String, dynamic>> images = [{'src': mainImageUrl}];
  //
  //   // ── Common meta ───────────────────────────────────────────────
  //   final List<Map<String, dynamic>> metaData = [
  //     {'key': 'custom_product', 'value': 'yes'},
  //     {'key': 'product_created_by', 'value': '1'},
  //     {'key': 'has_variable_price', 'value': _hasVariablePrice ? 'yes' : 'no'},
  //   ];
  //
  //   // ── SIMPLE PRODUCT ────────────────────────────────────────────
  //   if (_selectedProductType?.toLowerCase() != 'variable') {
  //     return AddProductInventoryTaxEntity(
  //       id: 0,
  //       name: _nameController.text.trim(),
  //       type: 'simple',
  //       sku: _skuController.text
  //           .trim()
  //           .isNotEmpty
  //           ? _skuController.text.trim()
  //           : 'SKU${DateTime
  //           .now()
  //           .millisecondsSinceEpoch}',
  //       regularPrice: _regularPriceController.text.trim(),
  //       salePrice: _salePriceController.text.trim(),
  //       categories: categories,
  //       tags: tags,
  //       images: images,
  //       metaData: metaData,
  //       attributes: const [],
  //       manageStock: _manageStock,
  //       stockQuantity: int.tryParse(_qtyController.text.trim()) ?? 0,
  //       taxStatus: _selectedTax != null ? 'taxable' : 'none',
  //       taxClass: _selectedTax?.taxClass ?? 'standard',
  //     );
  //   }
  //
  //   // ── VARIABLE PRODUCT ──────────────────────────────────────────
  //   if (_variants.isEmpty) return null;
  //
  //   // 1. Collect all possible attribute → values
  //   final Map<String, Set<String>> attributeOptionsMap = {};
  //
  //   for (final variant in _variants) {
  //     // Predefined attribute
  //     if (variant['attribute'] != null && variant['attributeItem'] != null) {
  //       final slug = (variant['attribute']['slug'] as String?)?.trim() ?? '';
  //       final value = (variant['attributeItem']['slug'] as String?)?.trim() ??
  //           (variant['attributeItem']['name'] as String?)?.trim() ??
  //           '';
  //
  //       if (slug.isNotEmpty && value.isNotEmpty) {
  //         attributeOptionsMap.putIfAbsent(slug, () => {}).add(value);
  //       }
  //     }
  //
  //     // Custom attributes (if you still use them)
  //     if (variant['attributes'] is List) {
  //       for (final attr in variant['attributes'] as List) {
  //         final name = (attr['name'] as String?)?.trim() ?? '';
  //         if (name.isEmpty) continue;
  //         final slug = 'pa_${name.toLowerCase().replaceAll(' ', '-')}';
  //         attributeOptionsMap.putIfAbsent(slug, () => {}).add(name);
  //       }
  //     }
  //   }
  //
  //   // 2. Build WooCommerce product.attributes format
  //   final List<Map<String, dynamic>> productAttributes = attributeOptionsMap
  //       .entries.map((entry) {
  //     final slug = entry.key;
  //     final cleanName = slug.replaceFirst('pa_', '').replaceAll('-', ' ');
  //     final capitalized = cleanName.split(' ').map((w) =>
  //     w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '').join(' ');
  //
  //     return {
  //       'id': 0,
  //       'name': capitalized,
  //       'slug': slug,
  //       'visible': true,
  //       'variation': true,
  //       'options': entry.value.toList(),
  //     };
  //   }).toList();
  //
  //   // 3. Build variations payload (the most important part)
  //   final List<Map<String, dynamic>> variationsPayload = [];
  //
  //   for (final variant in _variants) {
  //     final Map<String, dynamic> attrs = {};
  //
  //     // Predefined attribute
  //     if (variant['attribute'] != null && variant['attributeItem'] != null) {
  //       final slug = variant['attribute']['slug']?.toString().trim() ?? '';
  //       final value = variant['attributeItem']['slug']?.toString().trim() ??
  //           variant['attributeItem']['name']?.toString().trim() ??
  //           '';
  //
  //       if (slug.isNotEmpty && value.isNotEmpty) {
  //         attrs[slug] = value;
  //       }
  //     }
  //
  //     // Custom attributes (if any)
  //     if (variant['attributes'] is List) {
  //       for (final attr in variant['attributes'] as List) {
  //         final name = attr['name']?.toString().trim() ?? '';
  //         if (name.isNotEmpty) {
  //           final slug = 'pa_${name.toLowerCase().replaceAll(' ', '-')}';
  //           attrs[slug] = name;
  //         }
  //       }
  //     }
  //
  //     String? variantImageUrl;
  //
  //     if (variant['imageFile'] != null && variant['imageFile'] is File) {
  //       try {
  //         variantImageUrl = await _uploadImageForProduct(
  //           variant['imageFile'] as File,
  //           customFileName: 'variant-${DateTime
  //               .now()
  //               .millisecondsSinceEpoch}.jpg',
  //         );
  //       } catch (e) {
  //         print("Variant image upload failed: $e");
  //       }
  //     }
  //
  //     variationsPayload.add({
  //       'attributes': attrs,
  //       'regular_price': (variant['regularPrice']?.toString() ?? '0').trim(),
  //       'sale_price': (variant['salePrice']?.toString() ?? '').trim(),
  //     //   'stock_quantity': int.tryParse(variant['stock']?.toString() ?? '0') ??
  //     //       0,
  //     //   if (variantImageUrl != null) 'image': {'src': variantImageUrl},
  //     // });
  //       'manage_stock': true,
  //       'stock_quantity':
  //       int.tryParse(variant['stock']?.toString() ?? '0') ?? 0,
  //       if (variantImageUrl != null) 'image': {'src': variantImageUrl},
  //     });
  //
  //     // variationsPayload.add({
  //     //   'attributes': attrs,
  //     //   'regular_price': (variant['regularPrice']?.toString() ?? '0').trim(),
  //     //   'sale_price': (variant['salePrice']?.toString() ?? '').trim(),
  //     // //   'stock_quantity': int.tryParse(variant['stock']?.toString() ?? '0') ??
  //     // //       0,
  //     // //   if (variantImageUrl != null) 'image': {'src': variantImageUrl},
  //     // // });
  //     //   'manage_stock': true,
  //     //   'stock_quantity':
  //     //   int.tryParse(variant['stock']?.toString() ?? '0') ?? 0,
  //     //   if (variantImageUrl != null) 'image': {'src': variantImageUrl},
  //     // });
  //   }
  //
  //   // 4. Add variations payload to meta (you can rename key if backend expects different name)
  //   metaData.add({
  //     'key': '_pos_variations_payload',
  //     'value': variationsPayload,
  //   });
  //
  //   // Optional: keep debug version too
  //   metaData.add({
  //     'key': '_pos_variations_payload_debug',
  //     'value': variationsPayload,
  //   });
  //
  //   return AddProductInventoryTaxEntity(
  //     id: 0,
  //     name: _nameController.text.trim(),
  //     type: 'variable',
  //     sku: _skuController.text
  //         .trim()
  //         .isNotEmpty
  //         ? _skuController.text.trim()
  //         : 'SKU${DateTime
  //         .now()
  //         .millisecondsSinceEpoch}',
  //     regularPrice: '',
  //     salePrice: '',
  //     categories: categories,
  //     tags: tags,
  //     images: images,
  //     metaData: metaData,
  //     attributes: productAttributes,
  //     manageStock: false, // 🔥 FIX
  //     stockQuantity: 0,
  //     taxStatus: _selectedTax != null ? 'taxable' : 'none',
  //     taxClass: _selectedTax?.taxClass ?? 'standard',
  //   );
  // }

  Future<AddProductInventoryTaxEntity?> _buildProductEntity() async {
    final validationError = _validateForm();
    if (validationError != null) return null;

    // ── Main product image ────────────────────────────────────────
    String mainImageUrl =
        'https://indigo.alektasolutions.com/wp-content/uploads/2026/05/no_image-16-1.png';

    if (_imageFile != null) {
      final uploadedUrl = await _uploadImageForProduct(
        _imageFile!,
        customFileName: 'product-${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      if (uploadedUrl != null) {
        mainImageUrl = uploadedUrl;
        print('╔═══════════════════════════════════════════════');
        print('║               UPLOAD SUCCESS                  ║');
        print('╚═══════════════════════════════════════════════');
        print('URL: $mainImageUrl');
      } else {
        print('Main image upload failed → using fallback');
      }
    }

    // ── Categories & Tags ─────────────────────────────────────────
    final List<Map<String, dynamic>> categories = _selectedCategory != null
        ? [
      {'id': _selectedCategory.id ?? 0}
    ]
        : [];

    final List<Map<String, dynamic>> tags = [];
    final Set<String> seenSlugs = {};
    for (final tag in _selectedTags) {
      final slug = (tag.slug ?? '').trim();
      if (slug.isEmpty || seenSlugs.contains(slug)) continue;
      seenSlugs.add(slug);
      tags.add({
        'id': tag.id ?? 0,
        'name': tag.name?.trim() ?? slug,
        'slug': slug,
      });
    }

    // ── Images ────────────────────────────────────────────────────
    final List<Map<String, dynamic>> images = [
      {'src': mainImageUrl}
    ];

    // ── Common meta ───────────────────────────────────────────────
    final List<Map<String, dynamic>> metaData = [
      {'key': 'custom_product', 'value': 'yes'},
      {'key': 'product_created_by', 'value': '1'},
      {'key': 'has_variable_price', 'value': _hasVariablePrice ? 'yes' : 'no'},
    ];

    // ── SIMPLE PRODUCT ────────────────────────────────────────────
    if (_selectedProductType?.toLowerCase() != 'variable') {
      // Clean and parse stock (integer)
      final stockQty = int.tryParse(_qtyController.text.trim()) ?? 0;

      // Clean prices
      String cleanReg = (_regularPriceController.text.trim())
          .replaceAll(RegExp(r'[^0-9.]'), '');
      String cleanSale =
      (_salePriceController.text.trim()).replaceAll(RegExp(r'[^0-9.]'), '');

      double regPrice = double.tryParse(cleanReg) ?? 0.0;
      double? salePrice = double.tryParse(cleanSale);

      return AddProductInventoryTaxEntity(
        id: 0,
        name: _nameController.text.trim(),
        type: 'simple',
        sku: _skuController.text.trim().isNotEmpty
            ? _skuController.text.trim()
            : 'SKU${DateTime.now().millisecondsSinceEpoch}',
        regularPrice: regPrice.toStringAsFixed(2),
        salePrice: salePrice != null && salePrice > 0
            ? salePrice.toStringAsFixed(2)
            : '',
        categories: categories,
        tags: tags,
        images: images,
        metaData: metaData,
        attributes: const [],
        manageStock: true,
        stockQuantity: stockQty, // ← Stock from main qty field (e.g. 3)
        taxStatus: _selectedTax != null ? 'taxable' : 'none',
        taxClass: _selectedTax?.taxClass ?? 'standard',
      );
    }

    // ── VARIABLE PRODUCT ──────────────────────────────────────────
    if (_variants.isEmpty) return null;

    // 1. Collect attribute options for top-level attributes array
    final Map<String, Set<String>> attributeOptionsMap = {};

    for (final variant in _variants) {
      // Multiple attributes
      if (variant['attributes'] is List) {
        for (final attr in variant['attributes'] as List) {
          final name = (attr['attribute']?['name'] as String?)?.trim() ?? '';
          final slugValue = (attr['selectedSlug'] as String?)?.trim() ?? '';
          if (name.isNotEmpty && slugValue.isNotEmpty) {
            final slug = 'pa_${name.toLowerCase().replaceAll(' ', '-')}';
            attributeOptionsMap.putIfAbsent(slug, () => {}).add(slugValue);
          }
        }
      }
      // Single attribute fallback
      else if (variant['attribute'] != null &&
          variant['attributeItem'] != null) {
        final slug = (variant['attribute']['slug'] as String?)?.trim() ?? '';
        final value = (variant['attributeItem']['slug'] as String?)?.trim() ??
            (variant['attributeItem']['name'] as String?)?.trim() ??
            '';
        if (slug.isNotEmpty && value.isNotEmpty) {
          attributeOptionsMap.putIfAbsent(slug, () => {}).add(value);
        }
      }
    }

    // 2. Build top-level product.attributes (required!)
    final List<Map<String, dynamic>> productAttributes =
    attributeOptionsMap.entries.map((entry) {
      final slug = entry.key;
      final cleanName = slug.replaceFirst('pa_', '').replaceAll('-', ' ');
      final capitalized = cleanName
          .split(' ')
          .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '')
          .join(' ');

      return {
        'id': 0,
        'name': capitalized,
        'slug': slug,
        'visible': true,
        'variation': true,
        'options': entry.value.toList(),
      };
    }).toList();

    // 3. Build variations payload (with per-variant stock)
    final List<Map<String, dynamic>> variationsPayload = [];

    for (final variant in _variants) {
      final Map<String, dynamic> attrs = {};

      // Handle multiple attributes
      if (variant['attributes'] is List) {
        for (final attr in variant['attributes'] as List) {
          final attrSlug =
              (attr['attribute']?['slug'] as String?)?.trim() ?? '';
          final valueSlug = (attr['selectedSlug'] as String?)?.trim() ?? '';
          if (attrSlug.isNotEmpty && valueSlug.isNotEmpty) {
            attrs[attrSlug] = valueSlug;
          }
        }
      }
      // Fallback single attribute
      else if (variant['attribute'] != null &&
          variant['attributeItem'] != null) {
        final slug = variant['attribute']['slug']?.toString().trim() ?? '';
        final value = variant['attributeItem']['slug']?.toString().trim() ??
            variant['attributeItem']['name']?.toString().trim() ??
            '';
        if (slug.isNotEmpty && value.isNotEmpty) {
          attrs[slug] = value;
        }
      }

      // Clean prices → always string with 2 decimals
      String cleanReg = (variant['regularPrice']?.toString() ?? '0')
          .replaceAll(RegExp(r'[^0-9.]'), '');
      String cleanSale = (variant['salePrice']?.toString() ?? '')
          .replaceAll(RegExp(r'[^0-9.]'), '');

      double regPrice = double.tryParse(cleanReg) ?? 0.0;
      double? salePrice = double.tryParse(cleanSale);

      // Stock – must be integer (this is what you want!)
      int stockQty = int.tryParse(variant['stock']?.toString() ?? '0') ?? 0;

      // Variation payload
      // Map<String, dynamic> variation = {
      //   'attributes': attrs,
      //   'regular_price': regPrice.toStringAsFixed(2),
      //   'sale_price': salePrice != null && salePrice > 0 ? salePrice.toStringAsFixed(2) : null,
      //   'manage_stock': true,
      //   'stock_quantity': stockQty, // ← This is sent as integer (e.g. 3)
      // };

      Map<String, dynamic> variation = {
        'attributes': attrs,
        'regular_price': regPrice.toStringAsFixed(2),
        if (salePrice != null && salePrice > 0)
          'sale_price': salePrice.toStringAsFixed(2),
        'manage_stock': true,
        'stock': stockQty,
      };

      // Remove null sale_price if not present
      variation.removeWhere((key, value) => value == null);

      // Variant image
      String? variantImageUrl;
      if (variant['imageFile'] != null && variant['imageFile'] is File) {
        try {
          variantImageUrl = await _uploadImageForProduct(
            variant['imageFile'] as File,
            customFileName:
            'variant-${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          if (variantImageUrl != null) {
            variation['image'] = {'src': variantImageUrl};
          }
        } catch (e) {
          print("Variant image upload failed: $e");
        }
      }

      variationsPayload.add(variation);
    }

    // 4. Add variations payload to meta
    metaData.add({
      'key': '_pos_variations_payload',
      'value': variationsPayload,
    });

    // Optional debug copy
    metaData.add({
      'key': '_pos_variations_payload_debug',
      'value': variationsPayload,
    });

    // 5. Return variable product entity
    return AddProductInventoryTaxEntity(
      id: 0,
      name: _nameController.text.trim(),
      type: 'variable',
      sku: _skuController.text.trim().isNotEmpty
          ? _skuController.text.trim()
          : 'SKU${DateTime.now().millisecondsSinceEpoch}',
      regularPrice: '', // empty for variable
      salePrice: '', // empty for variable
      categories: categories,
      tags: tags,
      images: images,
      metaData: metaData,
      attributes: productAttributes,
      manageStock: false, // Stock managed per variation
      stockQuantity: 0, // Stock managed per variation
      taxStatus: _selectedTax != null ? 'taxable' : 'none',
      taxClass: _selectedTax?.taxClass ?? 'standard',
    );
  }

  void _printFormData() {
    print('=== FORM DATA ===');
    print('Product Name: ${_nameController.text}');
    print('SKU: ${_skuController.text}');
    print('Product Type: $_selectedProductType');
    print('Has Variable Price: $_hasVariablePrice');
    print('Regular Price: ${_regularPriceController.text}');
    print('Sale Price: ${_salePriceController.text}');
    print('Stock Quantity: ${_qtyController.text}');

    if (_selectedCategory != null) {
      print(
          'Category: ${_selectedCategory.name} (ID: ${_selectedCategory.id})');
    }

    if (_selectedTax != null) {
      print('Tax: ${_selectedTax.name} (Class: ${_selectedTax.taxClass})');
    }

    if (_selectedTags.isNotEmpty) {
      print('Tags:');
      final unique = <String, dynamic>{};
      for (var tag in _selectedTags) {
        final slug = tag.slug ?? '';
        if (!unique.containsKey(slug)) unique[slug] = tag;
      }
      for (var tag in unique.values) {
        print('  - ${tag.name} (slug: ${tag.slug})');
      }
    }

    if (_variants.isNotEmpty) {
      print('=== VARIANTS ===');
      for (int i = 0; i < _variants.length; i++) {
        var v = _variants[i];
        print('Variant ${i + 1}: ${v['name'] ?? 'Unnamed'}');
        print('  Stock: ${v['stock'] ?? '—'}');
        print('  Regular Price: ${v['regularPrice'] ?? '—'}');
        print('  Sale Price: ${v['salePrice'] ?? '—'}');

        if (v['attribute'] != null) {
          print(
              '  Attribute: ${v['attribute']['name']} (Slug: ${v['attribute']['slug']})');
        }
        if (v['attributeItem'] != null) {
          final item = v['attributeItem'];
          print('  Selected Item Slug: ${item['slug'] ?? item['name'] ?? '—'}');
        }
      }
    }
    print('=== END FORM DATA ===');
  }

  Future<void> _saveProduct() async {
    if (_isSaving || !mounted) return;
    _fieldErrors.clear();
    setState(() => _isSaving = true);

    try {
      print('╔═══════════════════════════════════════════════');
      print('║          STARTING PRODUCT SAVE PROCESS        ║');
      print('╚═══════════════════════════════════════════════');

      _printFormData();

      final validationError = _validateForm();
      if (validationError != null) {
        print('✗ Validation failed: $validationError');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(validationError), backgroundColor: Colors.orange),
          );
        }
        return;
      }

      final product = await _buildProductEntity();
      if (product == null) {
        print('✗ Failed to build product entity');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Failed to prepare product data'),
                backgroundColor: Colors.red),
          );
        }
        return;
      }

      print('✓ Entity ready → ${product.name} (${product.type})');
      _addProductBloc.add(AddProductInventoryTaxSubmitEvent(product: product));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Saving product...'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e, st) {
      print('Save failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _clearForm() {
    _formKey.currentState?.reset();
    _skuController.clear();
    _nameController.clear();
    _regularPriceController.clear();
    _salePriceController.clear();
    _qtyController.clear();
    _taxClassController.clear();
    _variantNameController.clear();
    _stockController.clear();
    _variantRegularPriceController.clear();
    _variantSalePriceController.clear();

    setState(() {
      _imageFile = null;
      _imageBytes = null;

      _selectedProductType = null;
      _selectedCategory = null;
      _selectedTax = null;
      _selectedTags.clear();

      _hasVariablePrice = false;
      _manageStock = true;
      _priceType = 'Fixed Price';

      _variants.clear();
      _variantAttributes = [
        {'attribute': null, 'attributeItem': null, 'selectedSlug': null}
      ];

      _currentVariantName = '';
      _currentStock = '';
      _currentRegularPrice = '';
      _currentSalePrice = '';
      _currentImageFile = null;
      _currentVariantIndex = -1;
      _currentVariantAttribute = null;
      _currentVariantAttributeItem = null;
      _selectedItemSlug = null;

      _fieldErrors.clear();
    });

    _updateAttributeControllers();
  }

  Widget _buildTabButton(String text, int index, ThemeNotifier themeHelper) {
    bool isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Color(0xFF2196F3) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : (themeHelper.themeMode == ThemeMode.dark
                ? Colors.white70
                : Colors.black54),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final themeHelper = Provider.of<ThemeNotifier>(context);
    final isDark = themeHelper.themeMode == ThemeMode.dark;
    final screenWidth = MediaQuery.of(context).size.width;

    bool isSmallScreen = screenWidth < 768;
    bool isMediumScreen = screenWidth >= 768 && screenWidth < 1024;

    return BlocConsumer<AddProductInventoryTaxBloc,
        AddProductInventoryTaxState>(
      bloc: _addProductBloc,
      listener: (context, state) {
        if (state is AddProductInventoryTaxLoaded) {
          setState(() {
            _isSaving = false;
          });
          if (Navigator.canPop(context)) {
            Navigator.pop(context, true);
          } else {
            _clearForm();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Product Added: ${state.product.name}'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else if (state is AddProductInventoryTaxError) {
          setState(() {
            _isSaving = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(' Error: ${state.message}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      },
      builder: (context, state) {
        return Scaffold(
          backgroundColor: isDark ? Color(0xFF1F1D2B) : Color(0xFFF5F5F5),
          body: Column(
            children: [
              TopBar(
                screen: Screen.ORDERS,
                onModeChanged: () async {
                  String newLayout;
                  if (sidebarPosition == SidebarPosition.left) {
                    newLayout = SharedPreferenceTextConstants.navRightOrderLeft;
                  } else if (sidebarPosition == SidebarPosition.right) {
                    newLayout =
                        SharedPreferenceTextConstants.navBottomOrderLeft;
                  } else {
                    newLayout = orderPanelPosition == OrderPanelPosition.left
                        ? SharedPreferenceTextConstants.navBottomOrderRight
                        : SharedPreferenceTextConstants.navLeftOrderRight;
                  }
                  PinakaPreferences.layoutSelectionNotifier.value = newLayout;
                  await UserDbHelper().saveUserSettings(
                      {AppDBConst.layoutSelection: newLayout},
                      modeChange: true);
                  setState(() {});
                },
              ),
              const Divider(color: Colors.grey, thickness: 0.4, height: 1),
              Expanded(
                child: Row(
                  children: [
                    if (sidebarPosition == SidebarPosition.left)
                      custom_widgets.NavigationBar(
                        selectedSidebarIndex: _selectedSidebarIndex,
                        onWillNavigate: (_) => _handleBack(),
                        onSidebarItemSelected: (index) =>
                            setState(() => _selectedSidebarIndex = index),
                        isVertical: true,
                      ),
                    Expanded(
                      child: Container(
                        margin: EdgeInsets.all(isSmallScreen ? 5 : 10),
                        decoration: BoxDecoration(
                          color: isDark ? Color(0xFF1F1D2B) : Colors.white,
                          borderRadius: BorderRadius.circular(6.0),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: isSmallScreen ? 8.0 : 16.0, vertical: 10),
                              child: Row(
                                children: [
                                  // Back button
                                  Container(
                                    height: 38,
                                    decoration: BoxDecoration(
                                        color: isDark ? Color(0xFF3B4259) : Color(0xFF3B4259),
                                        borderRadius: BorderRadius.circular(8.0)),
                                    child: TextButton.icon(
                                      onPressed: _handleBack,
                                      icon: const Icon(Icons.arrow_back_rounded,
                                          color: Colors.white, size: 15),
                                      label: const Text('Back',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600)),
                                      style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8)),
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  // Title centered
                                  Expanded(
                                    child: Text(
                                      'Add Product',
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700,
                                        color: isDark ? Colors.white : Colors.black87,
                                      ),
                                    ),
                                  ),
                                  // Clear Data button (outlined red)
                                  OutlinedButton(
                                    onPressed: _clearForm,
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Color(0xFFE53935), width: 1.5),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                      padding:
                                      const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                                      foregroundColor: Color(0xFFE53935),
                                    ),
                                    child: const Text(
                                      'Clear Data',
                                      style: TextStyle(
                                        color: Color(0xFFE53935),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // Save & Update button (green)
                                  ElevatedButton(
                                    onPressed: _isSaving ? null : _saveProduct,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2E7D32),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                      padding:
                                      const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                                    ),
                                    child: _isSaving
                                        ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                          AlwaysStoppedAnimation<Color>(Colors.white)),
                                    )
                                        : const Text(
                                      'Save & Update',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: _selectedTab == 0
                                  ? _buildAddProductTab(
                                  isDark, isSmallScreen, isMediumScreen)
                                  : _buildAuditListTab(isDark, isSmallScreen),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (sidebarPosition == SidebarPosition.right)
                      custom_widgets.NavigationBar(
                        selectedSidebarIndex: _selectedSidebarIndex,
                        onWillNavigate: (_) => _handleBack(),
                        onSidebarItemSelected: (index) =>
                            setState(() => _selectedSidebarIndex = index),
                        isVertical: true,
                      ),
                  ],
                ),
              ),
              if (sidebarPosition == SidebarPosition.bottom)
                custom_widgets.NavigationBar(
                  selectedSidebarIndex: _selectedSidebarIndex,
                  onWillNavigate: (_) => _handleBack(),
                  onSidebarItemSelected: (index) =>
                      setState(() => _selectedSidebarIndex = index),
                  isVertical: false,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAddProductTab(
      bool isDark, bool isSmallScreen, bool isMediumScreen) {
    return SingleChildScrollView(
      padding:
      EdgeInsets.symmetric(horizontal: isSmallScreen ? 8 : 16, vertical: 8),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            _buildDesktopLayout(isDark),

            const SizedBox(height: 32),

            ..._buildValidationErrors(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildValidationErrors() {
    List<Widget> errorWidgets = [];

    if (_fieldErrors.containsKey('name')) {
      errorWidgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            _fieldErrors['name']!,
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    }

    if (_fieldErrors.containsKey('category')) {
      errorWidgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            _fieldErrors['category']!,
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    }

    if (_fieldErrors.containsKey('productType')) {
      errorWidgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            _fieldErrors['productType']!,
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    }

    if (_fieldErrors.containsKey('regularPrice')) {
      errorWidgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            _fieldErrors['regularPrice']!,
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    }

    if (_fieldErrors.containsKey('quantity')) {
      errorWidgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            _fieldErrors['quantity']!,
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    }

    if (_fieldErrors.containsKey('variants')) {
      errorWidgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            _fieldErrors['variants']!,
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    }

    return errorWidgets;
  }

  // Widget _buildMobileLayout(bool isDark, bool isSmallScreen) {
  //   return Column(
  //     crossAxisAlignment: CrossAxisAlignment.start,
  //     children: [
  //       _buildProductImageSection(isDark, isSmallScreen),
  //       SizedBox(height: 16),
  //       _buildSKUSection(isDark, isSmallScreen),
  //       SizedBox(height: 16),
  //       Text('Product Name',
  //           style: TextStyle(
  //               fontSize: 14,
  //               fontWeight: FontWeight.w600,
  //               color: isDark ? Colors.white : Colors.black87)),
  //       SizedBox(height: 8),
  //       TextFormField(
  //         controller: _nameController,
  //         decoration: InputDecoration(
  //           hintText: 'Enter product name',
  //           border: OutlineInputBorder(
  //             borderRadius: BorderRadius.circular(6),
  //             borderSide: BorderSide(
  //                 color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0)),
  //           ),
  //           filled: true,
  //           fillColor: isDark ? Color(0xFF252837) : Color(0xFFF8F9FA),
  //         ),
  //         style: TextStyle(color: isDark ? Colors.white : Colors.black87),
  //       ),
  //       SizedBox(height: 16),
  //       Text('Category',
  //           style: TextStyle(
  //               fontSize: 14,
  //               fontWeight: FontWeight.w600,
  //               color: isDark ? Colors.white : Colors.black87)),
  //       SizedBox(height: 8),
  //       InventoryCategoriesDropdown(
  //         onCategorySelected: (category) {
  //           setState(() {
  //             _selectedCategory = category;
  //           });
  //         },
  //       ),
  //       SizedBox(height: 16),
  //       Text('Product Type',
  //           style: TextStyle(
  //               fontSize: 14,
  //               fontWeight: FontWeight.w600,
  //               color: isDark ? Colors.white : Colors.black87)),
  //       SizedBox(height: 8),
  //       InventoryGetProductTypesWidget(
  //         onTypeSelected: (selectedType) {
  //           setState(() {
  //             _selectedProductType = selectedType;
  //           });
  //         },
  //       ),
  //       SizedBox(height: 16),
  //       _buildPriceSection(isDark),
  //       SizedBox(height: 16),
  //       Text('Tax',
  //           style: TextStyle(
  //               fontSize: 14,
  //               fontWeight: FontWeight.w600,
  //               color: isDark ? Colors.white : Colors.black87)),
  //       SizedBox(height: 8),
  //       InventoryTaxDropdownWidget(
  //         onTaxSelected: (tax) {
  //           setState(() {
  //             _selectedTax = tax;
  //           });
  //         },
  //       ),
  //       SizedBox(height: 16),
  //       Text('Stock',
  //           style: TextStyle(
  //               fontSize: 14,
  //               fontWeight: FontWeight.w600,
  //               color: isDark ? Colors.white : Colors.black87)),
  //       SizedBox(height: 8),
  //       TextFormField(
  //         controller: _qtyController,
  //         keyboardType: TextInputType.number,
  //         // enabled: !_hasVariablePrice,
  //         decoration: InputDecoration(
  //           hintText: 'Enter quantity',
  //           border: OutlineInputBorder(
  //             borderRadius: BorderRadius.circular(6),
  //             borderSide: BorderSide(
  //                 color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0)),
  //           ),
  //           filled: true,
  //           fillColor: isDark ? Color(0xFF252837) : Color(0xFFF8F9FA),
  //         ),
  //         style: TextStyle(color: isDark ? Colors.white : Colors.black87),
  //       ),
  //
  //       SizedBox(height: 16),
  //       SizedBox(height: 8),
  //       InventoryTagMultiSelectWidget(
  //         onTypeSelected: (tag) {
  //           if (tag != null) {
  //             setState(() {
  //               _selectedTags.clear();
  //               _selectedTags.add(tag);
  //             });
  //           }
  //         },
  //       ),
  //       SizedBox(height: 10),
  //       _buildVariantSection(isDark, isSmallScreen),
  //
  //       // Add Save & Update button for mobile layout
  //       Container(
  //         //padding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
  //         child: Row(
  //           mainAxisAlignment: MainAxisAlignment.end,
  //           children: [
  //             OutlinedButton(
  //               onPressed: _clearForm,
  //               child: Text(
  //                 'Clear',
  //                 style: TextStyle(
  //                   color: Color(0xFF2196F3),
  //                   fontSize: 12,
  //                   fontWeight: FontWeight.w600,
  //                 ),
  //               ),
  //               style: OutlinedButton.styleFrom(
  //                 side: BorderSide(color: Color(0xFF2196F3), width: 2),
  //                 shape: RoundedRectangleBorder(
  //                     borderRadius: BorderRadius.circular(6)),
  //                 padding: EdgeInsets.symmetric(
  //                     horizontal: isSmallScreen ? 30 : 50, vertical: 10),
  //               ),
  //             ),
  //             SizedBox(width: 16),
  //             ElevatedButton(
  //               onPressed: _isSaving ? null : _saveProduct,
  //               child: _isSaving
  //                   ? SizedBox(
  //                 width: 15,
  //                 height: 15,
  //                 child: CircularProgressIndicator(
  //                   strokeWidth: 2,
  //                   valueColor:
  //                   AlwaysStoppedAnimation<Color>(Colors.white),
  //                 ),
  //               )
  //                   : Text(
  //                 'Save & Update',
  //                 style: TextStyle(
  //                   color: Colors.white,
  //                   fontSize: 12,
  //                   fontWeight: FontWeight.w600,
  //                 ),
  //               ),
  //               style: ElevatedButton.styleFrom(
  //                 backgroundColor: Color(0xFF2196F3),
  //                 shape: RoundedRectangleBorder(
  //                     borderRadius: BorderRadius.circular(6)),
  //                 padding: EdgeInsets.symmetric(
  //                     horizontal: isSmallScreen ? 30 : 50, vertical: 16),
  //               ),
  //             ),
  //           ],
  //         ),
  //       ),
  //     ],
  //   );
  // }

  Widget _buildDesktopLayout(bool isDark) {
    final screenHeight = MediaQuery.of(context).size.height;
    final maxCardHeight = screenHeight * 0.65;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Desktop Cards Row (65% height)
        SizedBox(
          height: maxCardHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Basic Information Card
              Expanded(
                flex: 3,
                child: Container(
                  child: Card(
                    color: Theme.of(context).cardColor,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        // HEADER
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2262A3)
                                : const Color(0xFFEFF7FF), // ✅ updated color
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Basic Information',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),

                        Expanded(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding:
                              const EdgeInsets.symmetric(horizontal: 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  /// PRODUCT IMAGE
                                  Text(
                                    'Product Image',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 6),

                                  // Row(
                                  //   crossAxisAlignment:
                                  //   CrossAxisAlignment.start,
                                  //   children: [
                                  //     GestureDetector(
                                  //       onTap: _pickImage,
                                  //       child: Stack(
                                  //         children: [
                                  //           Container(
                                  //             width: 70,
                                  //             height: 70,
                                  //             decoration: BoxDecoration(
                                  //               borderRadius:
                                  //               BorderRadius.circular(8),
                                  //               border: Border.all(
                                  //                 color: isDark
                                  //                     ? const Color(0xFF3B4259)
                                  //                     : const Color(0xFFE0E0E0),
                                  //                 width: 2,
                                  //               ),
                                  //               color: isDark
                                  //                   ? const Color(0xFF252837)
                                  //                   : Colors.white,
                                  //               image: _imageFile != null
                                  //                   ? DecorationImage(
                                  //                 image: FileImage(
                                  //                     _imageFile!),
                                  //                 fit: BoxFit.cover,
                                  //               )
                                  //                   : null,
                                  //             ),
                                  //             child: _imageFile == null
                                  //                 ? Column(
                                  //               mainAxisAlignment:
                                  //               MainAxisAlignment
                                  //                   .center,
                                  //               children: [
                                  //                 Container(
                                  //                   padding: EdgeInsets.all(6), // controls circle size
                                  //                   decoration: BoxDecoration(
                                  //                     color: Color(0xFF2196F3).withOpacity(0.1), // light background
                                  //                     shape: BoxShape.circle,
                                  //                   ),
                                  //                   child: Icon(
                                  //                     Icons.image_outlined,
                                  //                     size: 12,
                                  //                     color: Color(0xFF2196F3),
                                  //                   ),
                                  //                 ),
                                  //
                                  //                 const SizedBox(height: 2),
                                  //
                                  //                 Padding(
                                  //                   padding: const EdgeInsets.only(left: 16.0),
                                  //                   child: Text(
                                  //                     'Upload Image',
                                  //                     style: TextStyle(
                                  //                       fontSize: 10,
                                  //                       color: isDark ? Colors.white70 : Colors.black54,
                                  //                     ),
                                  //                   ),
                                  //                 ),
                                  //               ],
                                  //             )
                                  //                 : null,
                                  //           ),
                                  //           if (_imageFile != null)
                                  //             Positioned(
                                  //               top: 4,
                                  //               right: 4,
                                  //               child: GestureDetector(
                                  //                 onTap: () {
                                  //                   setState(() {
                                  //                     _imageFile = null;
                                  //                   });
                                  //                 },
                                  //                 child: Container(
                                  //                   padding:
                                  //                   const EdgeInsets.all(4),
                                  //                   decoration:
                                  //                   const BoxDecoration(
                                  //                     color: Colors.black54,
                                  //                     shape: BoxShape.circle,
                                  //                   ),
                                  //                   child: const Icon(
                                  //                     Icons.close,
                                  //                     size: 12,
                                  //                     color: Colors.white,
                                  //                   ),
                                  //                 ),
                                  //               ),
                                  //             ),
                                  //         ],
                                  //       ),
                                  //     ),
                                  //
                                  //     const SizedBox(width: 10),
                                  //
                                  //     /// IMAGE TEXT INFO (Aligned)
                                  //     Expanded(
                                  //       child: Column(
                                  //         crossAxisAlignment:
                                  //         CrossAxisAlignment.start,
                                  //         mainAxisAlignment:
                                  //         MainAxisAlignment.center,
                                  //         children: [
                                  //           Text(
                                  //             'Please upload a clear image of the item',
                                  //             style: TextStyle(
                                  //               fontSize: 10,
                                  //               color: isDark
                                  //                   ? Colors.white54
                                  //                   : Colors.black45,
                                  //             ),
                                  //           ),
                                  //           const SizedBox(height: 6),
                                  //           Text(
                                  //             'Max File Size : 200KB',
                                  //             style: TextStyle(
                                  //               fontSize: 10,
                                  //               fontWeight: FontWeight.w500,
                                  //               color: isDark
                                  //                   ? Colors.white70
                                  //                   : Colors.black87,
                                  //             ),
                                  //           ),
                                  //         ],
                                  //       ),
                                  //     ),
                                  //   ],
                                  // ),

                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      GestureDetector(
                                        onTap: _pickImage,
                                        child: Stack(
                                          children: [
                                            DottedBorder(
                                              borderType: BorderType.RRect,
                                              radius: Radius.circular(8),
                                              dashPattern: [4, 3],
                                              color: isDark
                                                  ? const Color(0xFF3B4259)
                                                  : const Color(0xFFE0E0E0),
                                              strokeWidth: 1.5,
                                              child: Container(
                                                width: 70,
                                                height: 70,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(8),
                                                  // ❌ removed solid border here
                                                  color: isDark
                                                      ? const Color(0xFF252837)
                                                      : Colors.white,
                                                  image: _imageFile != null
                                                      ? DecorationImage(
                                                    image: FileImage(_imageFile!),
                                                    fit: BoxFit.cover,
                                                  )
                                                      : null,
                                                ),
                                                child: _imageFile == null
                                                    ? Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Container(
                                                      padding: EdgeInsets.all(6),
                                                      decoration: BoxDecoration(
                                                        color: Color(0xFF2196F3).withOpacity(0.1),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: Icon(
                                                        Icons.image_outlined,
                                                        size: 12,
                                                        color: Color(0xFF2196F3),
                                                      ),
                                                    ),

                                                    const SizedBox(height: 2),

                                                    Padding(
                                                      padding: const EdgeInsets.only(left: 16.0),
                                                      child: Text(
                                                        'Upload Image',
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          color: isDark
                                                              ? Colors.white70
                                                              : Colors.black54,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                )
                                                    : null,
                                              ),
                                            ),

                                            if (_imageFile != null)
                                              Positioned(
                                                top: 4,
                                                right: 4,
                                                child: GestureDetector(
                                                  onTap: () {
                                                    setState(() {
                                                      _imageFile = null;
                                                    });
                                                  },
                                                  child: Container(
                                                    padding: const EdgeInsets.all(4),
                                                    decoration: const BoxDecoration(
                                                      color: Colors.black54,
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: const Icon(
                                                      Icons.close,
                                                      size: 12,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(width: 10),

                                      Flexible(
                                        child: Padding(
                                          padding: const EdgeInsets.only(left: 8.0),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                'Please upload a clear image of the item',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: isDark
                                                      ? Colors.white54
                                                      : Colors.black45,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                'Max File Size : 200KB',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w500,
                                                  color: isDark
                                                      ? Colors.white70
                                                      : Colors.black87,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 6),

                                  /// SKU
                                  Text(
                                    'SKU',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 6),

                                  Container(
                                    height: 44, // FIXED HEIGHT
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF252837)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isDark
                                            ? const Color(0xFF3B4259)
                                            : const Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                      children: [
                                        Expanded(
                                          child: TextFormField(
                                            controller: _skuController,
                                            autofocus: false,
                                            focusNode: _skuFocusNode,   // ← Add this line

                                            style: TextStyle(
                                              color: isDark
                                                  ? Colors.white
                                                  : Colors.black87,
                                              fontSize: 12,
                                            ),
                                            decoration: InputDecoration(
                                              hintText: 'Generate the SKU',
                                              hintStyle: TextStyle(
                                                color: isDark
                                                    ? Colors.white24
                                                    : Colors.black26,
                                                fontSize: 12,
                                              ),
                                              border: InputBorder.none,
                                              isDense: true,
                                              contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 14),
                                            ),
                                          ),
                                        ),

                                        /// GENERATE BUTTON (Centered, disabled when SKU present)
                                        InkWell(
                                          onTap: _skuController.text.trim().isEmpty
                                              ? () {
                                            setState(() {
                                              _skuController.text =
                                              'SKU${DateTime.now().millisecondsSinceEpoch}';
                                            });
                                          }
                                              : null,
                                          child: Container(
                                            height: double.infinity,
                                            alignment: Alignment.center,
                                            padding: const EdgeInsets.symmetric(horizontal: 20),
                                            decoration: BoxDecoration(
                                              gradient: _skuController.text.trim().isEmpty
                                                  ? LinearGradient(
                                                colors: [
                                                  Color(0xFFE91E63),
                                                  Color(0xFFFF8A80),
                                                ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              )
                                                  : LinearGradient(
                                                colors: [
                                                  Colors.grey.shade400,
                                                  Colors.grey.shade500,
                                                ],
                                              ),
                                              borderRadius: BorderRadius.only(
                                                topRight: Radius.circular(8),
                                                bottomRight: Radius.circular(8),
                                              ),
                                            ),
                                            child: const Text(
                                              'Generate',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(height: 6),

                                  /// PRODUCT NAME
                                  Text(
                                    'Product Name',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  TextFormField(
                                    controller: _nameController,
                                    decoration: InputDecoration(
                                      hintText: 'Enter the name',
                                      hintStyle: TextStyle(
                                        fontSize: 13,
                                        color: Colors.black,
                                      ),
                                      isDense: true,

                                      // ✅ DEFAULT BORDER
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(6),
                                        borderSide: BorderSide(color: Colors.grey),
                                      ),

                                      // ✅ WHEN NOT FOCUSED
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(6),
                                        borderSide: BorderSide(color: Colors.grey),
                                      ),

                                      // ✅ WHEN FOCUSED
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(6),
                                        borderSide: BorderSide(
                                          color: Colors.grey, // 👈 keep grey
                                          width: 1.5,
                                        ),
                                      ),

                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 8,
                                      ),
                                    ),
                                    style: TextStyle(
                                      color: isDark ? Colors.white : Colors.black87,
                                    ),
                                  ),

                                  const SizedBox(height: 6),

                                  /// CATEGORY
                                  Text(
                                    'Category',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w100,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    height: 48,
                                    child: InventoryCategoriesDropdown(
                                      onCategorySelected: (category) {
                                        setState(() {
                                          _selectedCategory = category;
                                        });
                                      },
                                    ),
                                  ),

                                  const SizedBox(height: 6),

                                  /// PRODUCT TYPE
                                  Text(
                                    'Product Type',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    height: 48,
                                    child: InventoryGetProductTypesWidget(
                                      onTypeSelected: (selectedType) {
                                        setState(() {
                                          _selectedProductType = selectedType;
                                        });
                                      },
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
                ),
              ),

              SizedBox(width: 16),

              // Pricing & Tax Card
              Expanded(
                flex: 3,
                child: Container(
                  child: Material(
                    color: isDark ? const Color(0xFF1E1E2D) : Colors.white,
                    elevation: 2,
                    borderRadius: BorderRadius.circular(12),
                    child: Column(
                      children: [
                        // Header
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFFDAC14A)
                                : const Color(0xFFFFFBEB), // ✅ updated color
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Pricing & Tax',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),

                        // Body
                        Expanded(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Builder(
                                builder: (_) {
                                  final bool isProductTypeVariable =
                                      _selectedProductType == 'variable';
                                  final bool isPriceStockDisabled =
                                      _hasVariablePrice ||
                                          isProductTypeVariable;
                                  final bool isPriceStockDisabledStock =
                                      isProductTypeVariable;
                                  final Color disabledFill = isDark
                                      ? const Color(0xFF2A2D3E)
                                      : Colors.grey.shade200;
                                  final Color disabledText = isDark
                                      ? Colors.grey.shade500
                                      : Colors.grey.shade500;

                                  // Unified height for all TextFormFields
                                  const double fieldHeight = 36;
                                  final priceTextStyle = TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                    color: isPriceStockDisabled
                                        ? disabledText
                                        : (isDark ? Colors.white : Colors.black87),
                                  );

                                  return Column(
                                    crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                    children: [
                                      // Prices Row
                                      // 🔥 Common style (ADD THIS ABOVE)
                                      //   final priceTextStyle = TextStyle(
                                      //   fontSize: 14,
                                      //   fontWeight: FontWeight.w600,
                                      //   height: 1.2,
                                      //   color: isPriceStockDisabled
                                      //       ? disabledText
                                      //       : (isDark ? Colors.white : Colors.black87),
                                      // );

                                      Row(
                                        children: [
                                          // Regular Price
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'Regular Price',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                    color: isPriceStockDisabled
                                                        ? Colors.grey
                                                        : (isDark ? Colors.white70 : Colors.black87),
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                SizedBox(
                                                  height: fieldHeight,
                                                  child: TextFormField(
                                                    controller: _regularPriceController,
                                                    enabled: !isPriceStockDisabled,
                                                    keyboardType: TextInputType.number,
                                                    textAlign: TextAlign.right,
                                                    inputFormatters: [
                                                      TextInputFormatter.withFunction((oldValue, newValue) {
                                                        final text = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
                                                        if (text.isEmpty) return const TextEditingValue(text: '');
                                                        final value = int.parse(text) / 100;
                                                        final newText = value.toStringAsFixed(2);
                                                        return TextEditingValue(
                                                          text: newText,
                                                          selection: TextSelection.collapsed(offset: newText.length),
                                                        );
                                                      }),
                                                    ],
                                                    style: priceTextStyle, // ✅ SAME STYLE
                                                    decoration: InputDecoration(
                                                      prefixText: '\$ ',
                                                      hintText: '0.00',
                                                      hintStyle: priceTextStyle.copyWith(color: Colors.grey), // ✅ FIX
                                                      isDense: true,
                                                      filled: true,
                                                      fillColor: isPriceStockDisabled
                                                          ? disabledFill
                                                          : Colors.transparent,
                                                      border: const OutlineInputBorder(),
                                                      contentPadding: const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 8,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                          const SizedBox(width: 16),

                                          // Sale Price
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'Sale Price',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                    color: isPriceStockDisabled
                                                        ? Colors.grey
                                                        : (isDark ? Colors.white70 : Colors.black87),
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                SizedBox(
                                                  height: fieldHeight,
                                                  child: TextFormField(
                                                    controller: _salePriceController,
                                                    enabled: !isPriceStockDisabled,
                                                    keyboardType: TextInputType.number,
                                                    textAlign: TextAlign.right,
                                                    inputFormatters: [
                                                      TextInputFormatter.withFunction((oldValue, newValue) {
                                                        final text = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
                                                        if (text.isEmpty) return const TextEditingValue(text: '');
                                                        final value = int.parse(text) / 100;
                                                        final newText = value.toStringAsFixed(2);
                                                        return TextEditingValue(
                                                          text: newText,
                                                          selection: TextSelection.collapsed(offset: newText.length),
                                                        );
                                                      }),
                                                    ],
                                                    style: priceTextStyle, // ✅ SAME STYLE
                                                    decoration: InputDecoration(
                                                      prefixText: '\$ ',
                                                      hintText: '0.00',
                                                      hintStyle: priceTextStyle.copyWith(color: Colors.grey), // ✅ FIX
                                                      filled: true,
                                                      isDense: true,
                                                      fillColor: isPriceStockDisabled
                                                          ? disabledFill
                                                          : Colors.transparent,
                                                      border: const OutlineInputBorder(),
                                                      contentPadding: const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 8,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),

                                      const SizedBox(height: 6),

                                      // Variable Price Checkbox
                                      IgnorePointer(
                                        ignoring: isProductTypeVariable,
                                        child: Opacity(
                                          opacity:
                                          isProductTypeVariable ? 0.5 : 1,
                                          child: VariablePriceCheckboxWidget(
                                            value: _hasVariablePrice,
                                            isDark: isDark,
                                            name: 'Variable Product',
                                            slug: 'variable-product',
                                            onChanged: (checked) {
                                              setState(() {
                                                _hasVariablePrice = checked;
                                                if (checked) {
                                                  _regularPriceController
                                                      .clear();
                                                  _salePriceController.clear();
                                                  _qtyController.clear();
                                                }
                                                const slug = 'variable-product';
                                                if (checked) {
                                                  if (!_selectedTags.any(
                                                          (t) => t.slug == slug)) {
                                                    _selectedTags.add(
                                                      const Inventory_Tag_Entity(
                                                        id: 0,
                                                        name:
                                                        'Variable Product',
                                                        slug: slug,
                                                        description: '',
                                                        count: 0,
                                                      ),
                                                    );
                                                  }
                                                } else {
                                                  _selectedTags.removeWhere(
                                                          (t) => t.slug == slug);
                                                }
                                              });
                                            },
                                          ),
                                        ),
                                      ),

                                      const SizedBox(height: 14),

                                      // Tax
                                      Text(
                                        'Tax',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: isProductTypeVariable
                                              ? (isDark
                                              ? Colors.grey.shade300
                                              : Colors.black87)
                                              : (isDark
                                              ? Colors.white70
                                              : Colors.black87),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SizedBox(
                                        height: fieldHeight,
                                        child: InventoryTaxDropdownWidget(
                                          onTaxSelected: (tax) {
                                            setState(() => _selectedTax = tax);
                                          },
                                        ),
                                      ),

                                      const SizedBox(height: 6),

                                      // Stock
                                      Text(
                                        'Stock',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: isPriceStockDisabledStock
                                              ? (isDark
                                              ? Colors.grey.shade500
                                              : Colors.grey)
                                              : (isDark
                                              ? Colors.white70
                                              : Colors.black87),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      SizedBox(
                                        height: fieldHeight,
                                        child: TextFormField(
                                          controller: _qtyController,
                                          enabled: !isPriceStockDisabledStock,
                                          keyboardType: TextInputType.number,

                                          // ✅ LEFT ALIGN TEXT
                                          textAlign: TextAlign.left,

                                          style: TextStyle(
                                            color: isPriceStockDisabledStock
                                                ? disabledText
                                                : (isDark ? Colors.white : Colors.black87),
                                            fontSize: 13,
                                          ),

                                          decoration: InputDecoration(
                                            hintText: 'Enter the quantity',
                                            filled: true,
                                            isDense: true,
                                            fillColor: isPriceStockDisabledStock
                                                ? disabledFill
                                                : Colors.transparent,

                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(color: Colors.grey.shade400),
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(color: Colors.grey.shade400),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(
                                                color: Colors.grey.shade600,
                                                width: 2.5,
                                              ),
                                            ),
                                            disabledBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide(color: Colors.grey.shade900),
                                            ),

                                            contentPadding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 8,
                                            ),
                                          ),
                                        ),
                                      ),

                                      const SizedBox(height: 2),

                                      // Tags
                                      Text(
                                        'Tags',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: isProductTypeVariable
                                              ? Colors.grey
                                              : (isDark
                                              ? Colors.white70
                                              : Colors.black87),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        height: 130,
                                        child: InventoryTagMultiSelectWidget(
                                          onTypeSelected: (tag) {
                                            if (tag != null) {
                                              setState(() {
                                                _selectedTags.clear();
                                                _selectedTags.add(tag);
                                              });
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              SizedBox(width: 16),

              // Variants Card
              Expanded(
                flex: 5,
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E3A5F) : Colors.white,

                    // ✅ SAME radius everywhere
                    borderRadius: BorderRadius.circular(12),

                    // ✅ BORDER
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.grey.shade300,
                      width: 1,
                    ),

                    // ✅ SHADOW
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Colors.black.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.15),
                        blurRadius: 8,
                        spreadRadius: 0,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),

                  child: Column(
                    children: [
                      // 🔷 HEADER
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF4180DD)
                              : const Color(0xFFEFF6FF),

                          // ✅ MATCH SAME RADIUS
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            topRight: Radius.circular(12),
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              "Variant's",
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '(Optional)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: isDark ? Colors.white54 : Colors.black45,
                              ),
                            ),
                            const Spacer(),
                            if (_variants.isNotEmpty)
                              Container(
                                padding:
                                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2196F3).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_variants.length} added',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF2196F3),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // ⚪ BODY
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _buildVariantContent(isDark),
                        ),
                      ),
                    ],
                  ),
                ),
              )],
          ),
        ),

        // Add Save & Update button after cards
        // Container(
        //   padding: EdgeInsets.only(top: 8),
        //   child: Row(
        //     mainAxisAlignment: MainAxisAlignment.end,
        //     children: [
        //       OutlinedButton(
        //         onPressed: _clearForm,
        //         child: Text(
        //           'Clear',
        //           style: TextStyle(
        //             color: Color(0xFF2196F3),
        //             fontSize: 13,
        //             fontWeight: FontWeight.w600,
        //           ),
        //         ),
        //         style: OutlinedButton.styleFrom(
        //           side: BorderSide(color: Color(0xFF2196F3), width: 2),
        //           shape: RoundedRectangleBorder(
        //               borderRadius: BorderRadius.circular(6)),
        //           padding: EdgeInsets.symmetric(horizontal: 50, vertical: 10),
        //         ),
        //       ),
        //       SizedBox(width: 16),
        //       ElevatedButton(
        //         onPressed: _isSaving ? null : _saveProduct,
        //         child: _isSaving
        //             ? SizedBox(
        //           width: 20,
        //           height: 20,
        //           child: CircularProgressIndicator(
        //             strokeWidth: 2,
        //             valueColor:
        //             AlwaysStoppedAnimation<Color>(Colors.white),
        //           ),
        //         )
        //             : Text(
        //           'Save & Update',
        //           style: TextStyle(
        //             color: Colors.white,
        //             fontSize: 13,
        //             fontWeight: FontWeight.w600,
        //           ),
        //         ),
        //         style: ElevatedButton.styleFrom(
        //           backgroundColor: Color(0xFF2196F3),
        //           shape: RoundedRectangleBorder(
        //               borderRadius: BorderRadius.circular(6)),
        //           padding: EdgeInsets.symmetric(horizontal: 50, vertical: 10),
        //         ),
        //       ),
        //     ],
        //   ),
        // ),
      ],
    );
  }

  Widget _buildProductImageSection(bool isDark, bool isSmallScreen) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('Product Image',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87)),
        SizedBox(height: 8),
        GestureDetector(
          onTap: _pickImage,
          child: Container(
            width: isSmallScreen ? double.infinity : 140,
            height: 140,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isDark ? Color(0xFF252837) : Color(0xFFF8F9FA),
              border: Border.all(
                  color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0)),
              image: _imageFile != null
                  ? DecorationImage(
                image: FileImage(_imageFile!),
                fit: BoxFit.cover,
              )
                  : null,
            ),
            child: _imageFile == null
                ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.image_outlined,
                    size: 10, color: Color(0xFF2196F3)),
                SizedBox(height: 8),
                Text('Upload Image',
                    style: TextStyle(
                        color: Color(0xFF2196F3), fontSize: 10)),
              ],
            )
                : null,
          ),
        ),
        SizedBox(height: 4),
        Text('Please upload a clear image of the item',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
            textAlign: TextAlign.center),
        Text('Max File Size : 200KB',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ],
    );
  }

  Widget _buildSKUSection(bool isDark, bool isSmallScreen) {
    final bool canGenerateSku = _skuController.text.trim().isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SKU',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87)),
        SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _skuController,
                style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                decoration: InputDecoration(
                  hintText: 'Generate the Sku',
                  hintStyle:
                  TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  filled: true,
                  fillColor: isDark ? Color(0xFF252837) : Color(0xFFF8F9FA),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                        color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0)),
                  ),
                  contentPadding:
                  EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
            SizedBox(width: 8),
            Container(
              height: 48,
              decoration: BoxDecoration(
                gradient: canGenerateSku
                    ? const LinearGradient(
                  colors: [
                    Color(0xFFF6339A),
                    Color(0xFFFF2056),
                  ],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
                    : null,
                color: canGenerateSku ? null : Colors.grey.shade400,
                borderRadius: BorderRadius.circular(6),
              ),
              child: ElevatedButton(
                onPressed: canGenerateSku
                    ? () => setState(() => _skuController.text =
                'SKU${DateTime.now().millisecondsSinceEpoch}')
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent, // ✅ keeps gradient visible
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                child: const Text(
                  'Generate',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          ],
        ),
      ],
    );
  }

  Widget _buildPriceSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Price',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87)),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(
                child: _buildPriceField(
                    'Regular Price', _regularPriceController, isDark)),
            SizedBox(width: 16),
            Expanded(
                child: _buildPriceField(
                    'Sale Price', _salePriceController, isDark)),
          ],
        ),
        SizedBox(height: 8),
        Row(
          children: [
            Checkbox(
              value: _hasVariablePrice,
              onChanged: (val) =>
                  setState(() => _hasVariablePrice = val ?? false),
              activeColor: Colors.white,
              side: BorderSide(color: isDark ? Colors.white38 : Colors.black38),
            ),
            Expanded(
              child: Text(
                'If the product has Variable Price',
                style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPriceField(
      String label, TextEditingController controller, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.black54)),
        SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: false),
          textAlign: TextAlign.right,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            TextInputFormatter.withFunction((oldValue, newValue) {
              final rawText = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
              if (rawText.isEmpty) {
                return const TextEditingValue(text: '');
              }
              final cents = int.tryParse(rawText) ?? 0;
              final dollars = cents / 100;
              final formatted = dollars.toStringAsFixed(2);
              return TextEditingValue(
                text: formatted,
                selection: TextSelection.collapsed(offset: formatted.length),
              );
            }),
          ],
          style: TextStyle(color: isDark ? Colors.white : Colors.black87),
          decoration: InputDecoration(
            prefixText: '\$ ',
            hintText: '0.00',
            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            filled: true,
            fillColor: isDark ? Color(0xFF252837) : Color(0xFFF8F9FA),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                  color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0)),
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildVariantSection(bool isDark, bool isSmallScreen) {
    return Container(
      width: 480,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Color(0xFF1E3A5F) : Color(0xFFF0F7FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isDark ? Color(0xFF2196F3) : Color(0xFFBBDEFB), width: 1),
      ),
      child: _buildVariantContent(isDark),
    );
  }

  Widget _buildVariantContent(bool isDark) {
    final bool isVariantsEnabled =
        (_selectedProductType ?? '').toLowerCase() == 'variable';

    // Helper to generate name from selected attributes
    String _generateVariantName() {
      if (_variantAttributes.isEmpty) return '';

      final parts = <String>[];

      for (var attr in _variantAttributes) {
        final attrName = attr['attribute']?['name'] as String?;
        final selectedSlug = attr['selectedSlug'] as String?;

        if (attrName != null &&
            selectedSlug != null &&
            selectedSlug.trim().isNotEmpty) {
          // Make slug look nicer (capitalize words)
          final niceValue = selectedSlug
              .split('-')
              .map((w) => w.isNotEmpty
              ? w[0].toUpperCase() + w.substring(1).toLowerCase()
              : '')
              .join(' ');

          parts.add('$attrName: $niceValue');
        }
      }

      if (parts.isEmpty) return '';

      // You can change separator: ' / ' or ' - ' or ', '
      return parts.join(' • ');
    }

    return SingleChildScrollView(
      child: Opacity(
        opacity: isVariantsEnabled ? 1.0 : 0.5,
        child: IgnorePointer(
          ignoring: !isVariantsEnabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isVariantsEnabled) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.red.withOpacity(0.12)
                        : Colors.red.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.red.shade400, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Variants are only available when Product Type is "Variable"',
                          style: TextStyle(
                            color: isDark
                                ? Colors.red.shade300
                                : Colors.red.shade700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],

              // Existing variants list (unchanged)
              if (_variants.isNotEmpty) ...[
                ..._variants.asMap().entries.map((entry) {
                  int index = entry.key;
                  var variant = entry.value;
                  return Container(
                    margin: EdgeInsets.only(bottom: 16, left: 10, right: 10),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? Color(0xFF1F1D2B) : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0),
                      ),
                    ),
                    child: Row(
                      children: [
                        // Index Number
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Color(0xFF2196F3).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF2196F3),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 16),

                        // Image with remove button (unchanged)
                        Stack(
                          children: [
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: isDark
                                    ? Color(0xFF252837)
                                    : Color(0xFFF8F9FA),
                                border: Border.all(
                                  color: isDark
                                      ? Color(0xFF3B4259)
                                      : Color(0xFFE0E0E0),
                                ),
                              ),
                              child: variant['imageFile'] != null
                                  ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  variant['imageFile'],
                                  fit: BoxFit.cover,
                                ),
                              )
                                  : Icon(
                                Icons.image_outlined,
                                size: 32,
                                color: Colors.grey.shade400,
                              ),
                            ),
                            if (variant['imageFile'] != null)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      variant['imageFile'] = null;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),

                        SizedBox(width: 16),

                        // Details (unchanged)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                variant['name'] ?? 'Unnamed',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              SizedBox(height: 8),
                              // Text(
                              //   '\$ ${(() {
                              //     final raw = variant['salePrice']?.toString() ?? '0';
                              //     final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
                              //     final value = double.tryParse(cleaned) ?? 0.0;
                              //     return value.toStringAsFixed(2);
                              //   })()}',
                              //   style: TextStyle(
                              //     fontSize: 14,
                              //     fontWeight: FontWeight.w500,
                              //     color: isDark ? Colors.white70 : Colors.black54,
                              //   ),
                              // ),

                              SizedBox(height: 8),
                              Row(
                                children: [
                                  Builder(
                                    builder: (context) {
                                      final regValue = double.tryParse(
                                        (variant['regularPrice'] ?? '0')
                                            .toString()
                                            .replaceAll(RegExp(r'[^0-9.]'), ''),
                                      ) ??
                                          0.0;

                                      final saleValue = double.tryParse(
                                        (variant['salePrice'] ?? '')
                                            .toString()
                                            .replaceAll(RegExp(r'[^0-9.]'), ''),
                                      ) ??
                                          0.0;

                                      final hasSale = saleValue > 0;

                                      return Row(
                                        children: [
                                          // 🔹 Regular Price
                                          Text(

                                            '\$${regValue.toStringAsFixed(2)}',
                                            style: TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.w600,
                                              color: hasSale
                                                  ? Colors.grey.shade600
                                                  : (isDark ? Colors.white70 : Colors.black54),
                                              decoration:
                                              hasSale ? TextDecoration.lineThrough : null,
                                            ),
                                          ),

                                          // 🔹 Sale Price
                                          if (hasSale) ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              '\$${saleValue.toStringAsFixed(2)}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600, // SAME weight
                                                color: isDark
                                                    ? Colors.orange.shade300
                                                    : Colors.orange.shade700,
                                              ),
                                            ),
                                          ],
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              )
                            ],
                          ),
                        ),

                        // Edit + Delete (unchanged)
                        Row(
                          children: [
                            InkWell(
                              onTap: () {
                                setState(() {
                                  _currentVariantIndex = index;
                                  _currentVariantName = variant['name'] ?? '';
                                  _currentStock = variant['stock'] ?? '';
                                  _currentRegularPrice =
                                      variant['regularPrice']?.toString() ?? '';
                                  _currentSalePrice =
                                      variant['salePrice']?.toString() ?? '';
                                  _currentImageFile = variant['imageFile'];

                                  if (variant['attributes'] != null &&
                                      (variant['attributes'] as List)
                                          .isNotEmpty) {
                                    _variantAttributes =
                                    List<Map<String, dynamic>>.from(
                                        variant['attributes']);
                                  } else {
                                    _variantAttributes = [
                                      {
                                        'attribute': variant['attribute'],
                                        'attributeItem':
                                        variant['attributeItem'],
                                        'selectedSlug': variant['attributeItem']
                                        ?['slug'],
                                      }
                                    ];
                                  }

                                  _variantNameController.text = _currentVariantName;
                                  _stockController.text = _currentStock;
                                  _variantRegularPriceController.text = _currentRegularPrice;
                                  _variantSalePriceController.text = _currentSalePrice;
                                });
                              },
                              child: Container(
                                padding: EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Color(0xFF2196F3).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color:
                                      Color(0xFF2196F3).withOpacity(0.3)),
                                ),
                                child: Icon(Icons.edit_outlined,
                                    size: 20, color: Color(0xFF2196F3)),
                              ),
                            ),
                            SizedBox(width: 8),
                            InkWell(
                              onTap: () {
                                setState(() {
                                  _variants.removeAt(index);
                                });
                              },
                              child: Container(
                                padding: EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Color(0xFFEF5350).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color:
                                      Color(0xFFEF5350).withOpacity(0.3)),
                                ),
                                child: Icon(Icons.delete_outline,
                                    size: 20, color: Color(0xFFEF5350)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
                SizedBox(height: 8),
              ],

              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isDark ? Color(0xFF1F1D2B) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark ? Color(0xFF3B4259) : Color(0xFFE0E0E0),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Image Upload (unchanged)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Variant Image',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.grey.shade400
                                    : Colors.grey.shade600,
                              ),
                            ),
                            SizedBox(height: 8),
                            Stack(
                              children: [
                                InkWell(
                                  onTap: () async {
                                    final XFile? pickedFile =
                                    await _picker.pickImage(
                                      source: ImageSource.gallery,
                                      maxWidth: 200,
                                      maxHeight: 200,
                                      imageQuality: 85,
                                    );
                                    if (pickedFile != null) {
                                      setState(() {
                                        _currentImageFile =
                                            File(pickedFile.path);
                                      });
                                    }
                                  },
                                  child: Container(
                                    width: 100,
                                    height: 100,
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? Color(0xFF252837)
                                          : Color(0xFFF8F9FA),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isDark
                                            ? Color(0xFF3B4259)
                                            : Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    child: _currentImageFile != null
                                        ? ClipRRect(
                                      borderRadius:
                                      BorderRadius.circular(8),
                                      child: Image.file(
                                        _currentImageFile!,
                                        fit: BoxFit.cover,
                                      ),
                                    )
                                        : Column(
                                      mainAxisAlignment:
                                      MainAxisAlignment.center,
                                      children: const [
                                        Icon(
                                          Icons.cloud_upload_outlined,
                                          size: 24,
                                          color: Color(0xFF2196F3),
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Upload',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF2196F3),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (_currentImageFile != null)
                                  Positioned(
                                    top: 6,
                                    right: 6,
                                    child: GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _currentImageFile = null;
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: const BoxDecoration(
                                          color: Colors.black54,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.close,
                                          size: 12,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        SizedBox(width: 6),

                        Expanded(
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Variant Name',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isDark
                                                ? Colors.grey.shade400
                                                : Colors.grey.shade600,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        Container(
                                          height: 36,
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: isDark
                                                ? Color(0xFF2A2D3E)
                                                : Colors.grey.shade100,
                                            borderRadius:
                                            BorderRadius.circular(6),
                                            border: Border.all(
                                              color: isDark
                                                  ? Color(0xFF3B4259)
                                                  : Colors.grey.shade300,
                                            ),
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              _generateVariantName().isNotEmpty
                                                  ? _generateVariantName()
                                                  : 'Auto from attributes',
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: _generateVariantName()
                                                    .isNotEmpty
                                                    ? (isDark
                                                    ? Colors.white70
                                                    : Colors.black54)
                                                    : (isDark
                                                    ? Colors.grey.shade500
                                                    : Colors.grey.shade600),
                                                fontStyle:
                                                _generateVariantName()
                                                    .isEmpty
                                                    ? FontStyle.italic
                                                    : null,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  SizedBox(
                                    width: 100,
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Stock',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isDark
                                                ? Colors.grey.shade400
                                                : Colors.grey.shade600,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        SizedBox(
                                          height: 36,
                                          child: TextField(
                                            controller: _stockController,
                                            onChanged: (value) =>
                                            _currentStock = value,
                                            keyboardType: TextInputType.number,
                                            decoration: InputDecoration(
                                              hintText: '0',
                                              filled: true,
                                              fillColor: isDark
                                                  ? Color(0xFF252837)
                                                  : Color(0xFFF8F9FA),
                                              border: OutlineInputBorder(
                                                  borderRadius:
                                                  BorderRadius.circular(6)),
                                              contentPadding:
                                              EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                  vertical: 0),
                                            ),
                                            style: TextStyle(fontSize: 14),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Regular Price',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isDark
                                                ? Colors.grey.shade400
                                                : Colors.grey.shade600,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        SizedBox(
                                          height: 36,
                                          child: TextField(
                                            // controller: _regularPriceController,
                                            controller: _variantRegularPriceController,

                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: false),
                                            textAlign: TextAlign.right,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly,
                                              TextInputFormatter.withFunction(
                                                      (oldValue, newValue) {
                                                    final rawText = newValue.text
                                                        .replaceAll(
                                                        RegExp(r'[^0-9]'), '');
                                                    if (rawText.isEmpty)
                                                      return const TextEditingValue(
                                                          text: '');
                                                    final cents =
                                                        int.tryParse(rawText) ?? 0;
                                                    final dollars = cents / 100;
                                                    final formatted =
                                                    dollars.toStringAsFixed(2);
                                                    return TextEditingValue(
                                                      text: formatted,
                                                      selection:
                                                      TextSelection.collapsed(
                                                          offset:
                                                          formatted.length),
                                                    );
                                                  }),
                                            ],
                                            decoration: InputDecoration(
                                              prefixText: '\$ ',
                                              hintText: '0.00',
                                              filled: true,
                                              fillColor: isDark
                                                  ? Color(0xFF252837)
                                                  : Color(0xFFF8F9FA),
                                              border: OutlineInputBorder(
                                                  borderRadius:
                                                  BorderRadius.circular(6)),
                                              contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                  vertical: 0),
                                            ),
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: isDark
                                                    ? Colors.white
                                                    : Colors.black87),
                                            onChanged: (value) =>
                                            _currentRegularPrice = value,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Sale Price',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isDark
                                                ? Colors.grey.shade400
                                                : Colors.grey.shade600,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        SizedBox(
                                          height: 36,
                                          child: TextField(
                                            controller: _variantSalePriceController,
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: false),
                                            textAlign: TextAlign.right,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly,
                                              TextInputFormatter.withFunction(
                                                      (oldValue, newValue) {
                                                    final rawText = newValue.text
                                                        .replaceAll(
                                                        RegExp(r'[^0-9]'), '');
                                                    if (rawText.isEmpty)
                                                      return const TextEditingValue(
                                                          text: '');
                                                    final cents =
                                                        int.tryParse(rawText) ?? 0;
                                                    final dollars = cents / 100;
                                                    final formatted =
                                                    dollars.toStringAsFixed(2);
                                                    return TextEditingValue(
                                                      text: formatted,
                                                      selection:
                                                      TextSelection.collapsed(
                                                          offset:
                                                          formatted.length),
                                                    );
                                                  }),
                                            ],
                                            decoration: InputDecoration(
                                              prefixText: '\$ ',
                                              hintText: '0.00',
                                              filled: true,
                                              fillColor: isDark
                                                  ? Color(0xFF252837)
                                                  : Color(0xFFF8F9FA),
                                              border: OutlineInputBorder(
                                                  borderRadius:
                                                  BorderRadius.circular(6)),
                                              contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                  vertical: 0),
                                            ),
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: isDark
                                                    ? Colors.white
                                                    : Colors.black87),
                                            onChanged: (value) =>
                                            _currentSalePrice = value,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Attributes',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    SizedBox(height: 6),
// Replace this block in your ..._variantAttributes.asMap().entries.map((entry) { ... })

                    ..._variantAttributes.asMap().entries.expand((entry) {
                      final idx = entry.key;
                      final attr = entry.value;
                      final isLast = idx == _variantAttributes.length - 1;

                      return [
                        // ── Attribute Row ──────────────────────────────────────────
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Index badge
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2196F3).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Center(
                                  child: Text(
                                    '${idx + 1}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF2196F3),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),

                              // Attribute + Items Dropdown
                              Expanded(
                                flex: 3,
                                child: SizedBox(
                                  height: 48,
                                  child: InventoryAttributesWithItemsWidget(
                                    onAttributeSelected: (attribute) {
                                      setState(() {
                                        _variantAttributes[idx]['attribute'] = {
                                          'id': attribute.id,
                                          'name': attribute.name,
                                          'slug': attribute.slug,
                                        };
                                        _variantAttributes[idx]['attributeItem'] = null;
                                        _variantAttributes[idx]['selectedSlug'] = null;
                                      });
                                    },
                                    onItemSlugSelected: (attribute, slug) {
                                      setState(() {
                                        _variantAttributes[idx]['attributeItem'] = {'slug': slug};
                                        _variantAttributes[idx]['selectedSlug'] = slug;
                                        // Hide unit name input if it was open for this row
                                        if (_activeAddItemAttrIdx == idx) {
                                          _showUnitNameInput = false;
                                          _activeAddItemAttrIdx = -1;
                                        }
                                      });
                                    },
                                    // ✅ KEY FIX: wire up onAddItemTapped
                                    onAddItemTapped: () {
                                      setState(() {
                                        _showUnitNameInput = true;
                                        _activeAddItemAttrIdx = idx;
                                        _unitNameInputController.clear();
                                      });
                                    },
                                    onRegisterRefresher: (refresher) {
                                      // _attributeRefreshers[idx] = refresher;
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),

                              // // Selected slug display
                              // Expanded(
                              //   flex: 2,
                              //   child: Container(
                              //     height: 40,
                              //     padding: const EdgeInsets.symmetric(horizontal: 12),
                              //     decoration: BoxDecoration(
                              //       color: isDark ? const Color(0xFF252837) : Colors.white70,
                              //       borderRadius: BorderRadius.circular(8),
                              //       border: Border.all(
                              //         color: isDark
                              //             ? const Color(0xFF3B4259)
                              //             : const Color(0xFFE0E0E0),
                              //       ),
                              //     ),
                              //     child: Align(
                              //       alignment: Alignment.centerLeft,
                              //       child: Text(
                              //         attr['selectedSlug'] ?? 'Not selected',
                              //         style: TextStyle(
                              //           fontSize: 12,
                              //           color: isDark ? Colors.white70 : Colors.black54,
                              //         ),
                              //         overflow: TextOverflow.ellipsis,
                              //       ),
                              //     ),
                              //   ),
                              // ),
                              // const SizedBox(width: 12),

                              // Add / Remove button
                              if (isLast)
                                TextButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      _variantAttributes.add({
                                        'attribute': null,
                                        'attributeItem': null,
                                        'selectedSlug': null,
                                      });
                                    });
                                  },
                                  icon: const Icon(Icons.add_circle_outline, size: 18, color: Color(0xFF2196F3)),
                                  label: const Text(
                                    'Add',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Color(0xFF2196F3),
                                      fontWeight: FontWeight.w500,
                                      decoration: TextDecoration.underline,
                                      decorationColor: Color(0xFF2196F3),
                                    ),
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                  ),
                                ),
                              if (!isLast && _variantAttributes.length > 1)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: InkWell(
                                    onTap: () {
                                      setState(() {
                                        _variantAttributes.removeAt(idx);
                                        if (_activeAddItemAttrIdx == idx) {
                                          _showUnitNameInput = false;
                                          _activeAddItemAttrIdx = -1;
                                        }
                                      });
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEF5350).withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: const Color(0xFFEF5350).withOpacity(0.3)),
                                      ),
                                      child: const Icon(Icons.delete_outline,
                                          size: 20, color: Color(0xFFEF5350)),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),

                        // ✅ KEY FIX: Unit Name input appears BELOW the matching attribute row
                        if (_showUnitNameInput && _activeAddItemAttrIdx == idx)
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1A2535)
                                  : const Color(0xFFF0F7FF),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF2A3F5F)
                                    : const Color(0xFFBBDEFB),
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  'Unit Name : ',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isDark ? Colors.white70 : Colors.black87,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF252837)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isDark
                                            ? const Color(0xFF3B4259)
                                            : Colors.grey.shade300,
                                      ),
                                    ),
                                    child: TextField(
                                      controller: _unitNameInputController,
                                      autofocus: true,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isDark ? Colors.white : Colors.black87,
                                      ),
                                      decoration: InputDecoration(
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 10),
                                        hintText: 'e.g. blue, XL, 500ml...',
                                        hintStyle: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? Colors.grey.shade600
                                              : Colors.grey.shade400,
                                        ),
                                      ),
                                      onSubmitted: (_) => _handleUnitNameCreate(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  height: 40,
                                  child: ElevatedButton(
                                    onPressed: _handleUnitNameCreate,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFB9F5C8),
                                      foregroundColor: const Color(0xFF1B8A3A),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                      padding:
                                      const EdgeInsets.symmetric(horizontal: 22),
                                    ),
                                    child: const Text(
                                      'Create',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF1B8A3A),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ];
                    }).toList(),
                    SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      height: 36,
                      child: ElevatedButton(
                        onPressed: isVariantsEnabled
                            ? () {
                          final generatedName =
                          _generateVariantName().trim();
                          if (generatedName.isEmpty) {
                            return;
                          }

                          setState(() {
                            _currentVariantName = generatedName;

                            Map<String, dynamic>? singleAttribute;
                            Map<String, dynamic>? singleAttributeItem;

                            for (var attr in _variantAttributes) {
                              if (attr['attribute'] != null &&
                                  attr['attributeItem'] != null) {
                                singleAttribute = attr['attribute'];
                                singleAttributeItem =
                                attr['attributeItem'];
                                break;
                              }
                            }

                            Map<String, dynamic> newVariant = {
                              'name': _currentVariantName,
                              'stock': _currentStock.isNotEmpty ? _currentStock : '0',
                              'regularPrice': _variantRegularPriceController.text.isNotEmpty
                                  ? _variantRegularPriceController.text
                                  : '0.00',
                              'salePrice': _variantSalePriceController.text.isNotEmpty
                                  ? _variantSalePriceController.text
                                  : '',
                              'imageFile': _currentImageFile,
                              'attribute': singleAttribute,
                              'attributeItem': singleAttributeItem,
                              'attributes':
                              List<Map<String, dynamic>>.from(
                                  _variantAttributes),
                            };

                            if (_currentVariantIndex >= 0) {
                              _variants[_currentVariantIndex] =
                                  newVariant;
                            } else {
                              _variants.add(newVariant);
                            }

                            _currentVariantName = '';
                            _currentStock = '';
                            _currentRegularPrice = '';
                            _currentSalePrice = '';
                            _currentImageFile = null;
                            _currentVariantIndex = -1;
                            _variantNameController.clear();
                            _stockController.clear();
                            _regularPriceController.clear();
                            _salePriceController.clear();

                            _variantRegularPriceController.clear();
                            _variantSalePriceController.clear();

                            _variantAttributes = [
                              {
                                'attribute': null,
                                'attributeItem': null,
                                'selectedSlug': null,
                              }
                            ];
                          });
                        }
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isVariantsEnabled
                              ? Color(0xFF00BFA5)
                              : Colors.grey.shade300,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          disabledBackgroundColor: Colors.grey.shade300,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _currentVariantIndex >= 0
                                  ? Icons.check
                                  : Icons.add,
                              size: 20,
                            ),
                            SizedBox(width: 8),
                            Text(
                              _currentVariantIndex >= 0
                                  ? 'Update Variant'
                                  : 'Add New Variant',
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuditListTab(bool isDark, bool isSmallScreen) {
    return Center(
      child: Text(
        'Audit List - Feature coming soon',
        style: TextStyle(
          fontSize: 18,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
    );
  }
}
