// lib/features/shop/shop_page.dart
// 硬件商城页面
// SKU 列表 / 3D 定制入口 / 订单查看
// 醒伴 WakeMate Flutter APP · 醒时科技 Wakeshift

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';

// ── Providers ────────────────────────────────────────────────────
final _skusProvider =
    FutureProvider.family<List<dynamic>, String?>((ref, category) async {
  return ref.watch(apiProvider).getShopSkus(category: category);
});

// ── ShopPage ──────────────────────────────────────────────────────
class ShopPage extends ConsumerStatefulWidget {
  const ShopPage({super.key});

  @override
  ConsumerState<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends ConsumerState<ShopPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  static const _categories = [
    (label: '全部', value: null),
    (label: '药珠手环', value: 'bracelet'),
    (label: '3D 定制', value: 'custom'),
    (label: '桌面摆件', value: 'companion'),
    (label: '表链套件', value: 'watchband'),
    (label: '企业版', value: 'badge'),
  ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _categories.length, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WMColors.bgPage,
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          SliverToBoxAdapter(child: _buildBanner()),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarDelegate(
              TabBar(
                controller: _tabCtrl,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: WMColors.brandPrimary,
                unselectedLabelColor: WMColors.ink500,
                indicatorColor: WMColors.brandPrimary,
                indicatorSize: TabBarIndicatorSize.label,
                dividerColor: WMColors.ink200,
                labelStyle:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                tabs: _categories.map((c) => Tab(text: c.label)).toList(),
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children:
              _categories.map((c) => _SkuList(category: c.value)).toList(),
        ),
      ),
    );
  }

  Widget _buildBanner() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [WMColors.brandPrimaryStrong, WMColors.brandPrimary],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        WMSpacing.md,
        MediaQuery.of(context).padding.top + 12,
        WMSpacing.md,
        WMSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios,
                    color: Colors.white, size: 20),
                onPressed: () => Navigator.of(context).pop(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
              const Text('硬件商城',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  )),
            ],
          ),
          const SizedBox(height: WMSpacing.md),
          const Text('为你打造专属药珠',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 4),
          const Text('功能硬件 × 个人饰品 · 每一颗都是独一无二',
              style: TextStyle(fontSize: 13, color: Colors.white60)),
          const SizedBox(height: WMSpacing.md),
          // 3D 定制高亮入口
          GestureDetector(
            onTap: () => _tabCtrl.animateTo(2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: WMColors.brandAccent.withOpacity(0.15),
                border:
                    Border.all(color: WMColors.brandAccent.withOpacity(0.6)),
                borderRadius: WMRadius.pill,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_fix_high,
                      size: 16, color: WMColors.brandAccent),
                  const SizedBox(width: 6),
                  const Text('上传模型 · 3D 定制你的专属药珠 →',
                      style: TextStyle(
                          fontSize: 13,
                          color: WMColors.brandAccent,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── SKU 列表 ──────────────────────────────────────────────────────
class _SkuList extends ConsumerWidget {
  final String? category;
  const _SkuList({this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skusAsync = ref.watch(_skusProvider(category));

    return skusAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, __) => kMockMode
          ? _buildGrid(context, _mockSkus(category))
          : _buildError(context, ref),
      data: (skus) => _buildGrid(
        context,
        skus.isEmpty && kMockMode ? _mockSkus(category) : skus,
      ),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 48, color: WMColors.ink300),
            const SizedBox(height: WMSpacing.md),
            const Text('暂时无法加载商品',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: WMSpacing.sm),
            const Text('请检查网络后重试。',
                style: TextStyle(fontSize: 14, color: WMColors.ink500)),
            const SizedBox(height: WMSpacing.lg),
            OutlinedButton(
              onPressed: () => ref.invalidate(_skusProvider(category)),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<dynamic> skus) {
    if (skus.isEmpty) {
      return const Center(
        child: Text('暂无商品', style: TextStyle(color: WMColors.ink500)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(WMSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: skus.length,
      itemBuilder: (_, i) => _SkuCard(sku: skus[i] as Map<String, dynamic>),
    );
  }

  // Mock 数据（网络不可用时降级）
  List<Map<String, dynamic>> _mockSkus(String? cat) {
    final all = [
      {
        "id": "sku_001",
        "name": "标准款药珠手环",
        "category": "bracelet",
        "price_min": 199,
        "price_max": 299,
        "in_stock": true,
        "customizable": false,
        "image_asset": "assets/images/shop/bracelet.png",
        "preview_emoji": "",
        "coming_soon": false,
        "b2b_only": false
      },
      {
        "id": "sku_002",
        "name": "3D 定制款珠子",
        "category": "custom",
        "price_min": 39,
        "price_max": 99,
        "in_stock": true,
        "customizable": true,
        "image_asset": "assets/images/shop/custom-bead.png",
        "preview_emoji": "",
        "coming_soon": false,
        "b2b_only": false
      },
      {
        "id": "sku_003",
        "name": "表链套件 20mm",
        "category": "watchband",
        "price_min": 149,
        "price_max": 249,
        "in_stock": true,
        "customizable": false,
        "image_asset": "assets/images/shop/watchband.png",
        "preview_emoji": "",
        "coming_soon": false,
        "b2b_only": false
      },
      {
        "id": "sku_004",
        "name": "小醒桌面摆件",
        "category": "companion",
        "price_min": 399,
        "price_max": 699,
        "in_stock": false,
        "customizable": false,
        "image_asset": "assets/images/shop/companion.png",
        "preview_emoji": "",
        "coming_soon": true,
        "b2b_only": false
      },
      {
        "id": "sku_005",
        "name": "电子胸牌（企业版）",
        "category": "badge",
        "price_min": 0,
        "price_max": 0,
        "in_stock": false,
        "customizable": false,
        "image_asset": "assets/images/shop/badge.png",
        "preview_emoji": "",
        "coming_soon": false,
        "b2b_only": true
      },
    ];
    if (cat == null) return all;
    return all.where((s) => s['category'] == cat).toList();
  }
}

// ── SKU 商品卡 ────────────────────────────────────────────────────
class _SkuCard extends StatelessWidget {
  final Map<String, dynamic> sku;
  const _SkuCard({required this.sku});

  @override
  Widget build(BuildContext context) {
    final inStock = sku['in_stock'] as bool? ?? false;
    final comingSoon = sku['coming_soon'] as bool? ?? false;
    final b2bOnly = sku['b2b_only'] as bool? ?? false;
    final custom = sku['customizable'] as bool? ?? false;
    final priceMin = sku['price_min'] as int? ?? 0;
    final priceMax = sku['price_max'] as int? ?? 0;
    final imageAsset = sku['image_asset'] as String?;
    final emoji = sku['preview_emoji'] as String? ?? '';

    return GestureDetector(
      onTap: () => _onTap(context, inStock, comingSoon, b2bOnly),
      child: Container(
        decoration: BoxDecoration(
          color: WMColors.bgCard,
          borderRadius: WMRadius.lg,
          boxShadow: WMShadows.card,
          border: custom
              ? Border.all(
                  color: WMColors.brandAccent.withOpacity(0.5), width: 1.5)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 商品主图
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: custom
                      ? WMColors.brandAccentSoft
                      : WMColors.brandPrimarySoft,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(WMRadius.lgValue)),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (imageAsset != null)
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Image.asset(
                          imageAsset,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              Text(emoji, style: const TextStyle(fontSize: 48)),
                        ),
                      )
                    else if (emoji.isNotEmpty)
                      Text(emoji, style: const TextStyle(fontSize: 48)),
                    // 标签
                    if (comingSoon)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _tag('即将上线', WMColors.brandAccent, Colors.white),
                      ),
                    if (b2bOnly)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _tag('B2B', WMColors.ink700, Colors.white),
                      ),
                    if (custom)
                      Positioned(
                        top: 8,
                        left: 8,
                        child:
                            _tag('可定制', WMColors.brandAccent, WMColors.ink900),
                      ),
                    if (!inStock && !comingSoon && !b2bOnly)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _tag('缺货', WMColors.ink300, WMColors.ink700),
                      ),
                  ],
                ),
              ),
            ),

            // 信息区
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sku['name'] as String? ?? '',
                      maxLines: 2,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: WMColors.ink900,
                        height: 1.3,
                      )),
                  const SizedBox(height: 4),
                  if (b2bOnly)
                    const Text('联系商务询价',
                        style: TextStyle(fontSize: 12, color: WMColors.ink500))
                  else if (priceMin == 0 && priceMax == 0)
                    const Text('价格待定',
                        style: TextStyle(fontSize: 12, color: WMColors.ink500))
                  else
                    Text(
                      priceMin == priceMax
                          ? '¥$priceMin'
                          : '¥$priceMin – ¥$priceMax',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: WMColors.brandPrimary,
                      ),
                    ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    height: 32,
                    child: ElevatedButton(
                      onPressed: (inStock || custom)
                          ? () => _onTap(context, inStock, comingSoon, b2bOnly)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: custom
                            ? WMColors.brandAccent
                            : WMColors.brandPrimary,
                        foregroundColor:
                            custom ? WMColors.ink900 : Colors.white,
                        padding: EdgeInsets.zero,
                        shape:
                            RoundedRectangleBorder(borderRadius: WMRadius.sm),
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500),
                        elevation: 0,
                      ),
                      child: Text(
                        b2bOnly
                            ? '咨询采购'
                            : comingSoon
                                ? '敬请期待'
                                : custom
                                    ? '立即定制'
                                    : inStock
                                        ? '查看详情'
                                        : '到货通知',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: WMRadius.pill),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
      );

  void _onTap(
      BuildContext context, bool inStock, bool comingSoon, bool b2bOnly) {
    if (comingSoon) {
      _snack(context, '${sku['name']} 即将上线，敬请期待 ✨');
    } else if (b2bOnly) {
      _snack(context, '企业采购请联系：business@your-company.com');
    } else if (!inStock) {
      _snack(context, '已登记到货通知，有货时第一时间告知你');
    } else if (sku['customizable'] == true) {
      _showCustomDialog(context);
    } else {
      _snack(context, '商品详情页（接入电商平台后上线）');
    }
  }

  void _showCustomDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('3D 定制药珠'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('定制流程：', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('1. 在模型库选择或上传 STL 文件'),
            Text('2. 选择材质和颜色'),
            Text('3. 确认数量，提交订单'),
            Text('4. 7 个工作日内发货'),
            SizedBox(height: 12),
            Text('每颗 ¥39 起，含打印 + 组装 + 检测',
                style: TextStyle(
                    color: Color(0xFF8a6020), fontWeight: FontWeight.w500)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _snack(context, '定制通道开放中，请关注公众号获取上线通知');
            },
            child: const Text('立即定制'),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}

// ── TabBar SliverPersistentHeader ────────────────────────────────
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  const _TabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: WMColors.bgCard,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_TabBarDelegate old) => false;
}
