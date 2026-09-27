"""
routers/shop.py — 硬件商城 API
醒伴 WakeMate Backend · 醒时科技 Wakeshift

SKU 目录 / 3D 模型库 / 定制下单 / 订单历史

[IS_MOCK_MODE 开关]
  SHOP_MOCK_MODE=true  → 返回内置 Mock 数据，无需对接真实打印供应商
  SHOP_MOCK_MODE=false → 接入 SHOP_SUPPLIER_API_URL 真实供应链 API

切换真实供应商步骤：
  1. 在 .env 设置 SHOP_MOCK_MODE=false
  2. 设置 SHOP_SUPPLIER_API_URL=https://your-supplier.com/api
  3. 在 _call_supplier() 函数中替换具体 HTTP 调用
"""
import uuid
from datetime import datetime, timezone
from typing import Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from core.config import get_settings
from db.database import get_db
from models.schemas import MessageOut
from routers.deps import get_current_user_id

router = APIRouter()
logger = structlog.get_logger()
settings = get_settings()

# ── Mock 商品数据 ──────────────────────────────────────────────────
_MOCK_SKUS = [
    {
        "id": "sku_001",
        "name": "标准款药珠手环",
        "category": "bracelet",
        "description": "7 颗药珠 + 智能扣头，日常佩戴首选。开箱即用，支持蓝牙配对。",
        "price_min": 199,
        "price_max": 299,
        "currency": "CNY",
        "in_stock": True,
        "coming_soon": False,
        "b2b_only": False,
        "customizable": False,
        "bead_count": 7,
        "color_options": ["白珠银扣", "黑珠黑扣", "原木珠金扣"],
        "preview_emoji": "⬜",
        "sort_order": 1,
    },
    {
        "id": "sku_002",
        "name": "3D 定制款珠子",
        "category": "custom",
        "description": "上传或选择模型，按需打印你专属的药珠造型。每颗独一无二。",
        "price_min": 39,
        "price_max": 99,
        "currency": "CNY",
        "in_stock": True,
        "coming_soon": False,
        "b2b_only": False,
        "customizable": True,
        "bead_count": 1,
        "color_options": ["白色PLA", "黑色PLA", "透明树脂", "哑光金"],
        "preview_emoji": "🎨",
        "sort_order": 2,
    },
    {
        "id": "sku_003",
        "name": "表链套件 20mm",
        "category": "watchband",
        "description": "适配 Apple Watch / 三星 / 佳明 20mm 表耳。含 2 颗药珠 + 专用扣头。",
        "price_min": 149,
        "price_max": 249,
        "currency": "CNY",
        "in_stock": True,
        "coming_soon": False,
        "b2b_only": False,
        "customizable": False,
        "bead_count": 2,
        "color_options": ["银色", "黑色", "玫瑰金"],
        "preview_emoji": "⌚",
        "sort_order": 3,
    },
    {
        "id": "sku_003b",
        "name": "表链套件 22mm",
        "category": "watchband",
        "description": "适配 22mm 表耳（华为 / Garmin / Suunto 等）。",
        "price_min": 149,
        "price_max": 249,
        "currency": "CNY",
        "in_stock": True,
        "coming_soon": False,
        "b2b_only": False,
        "customizable": False,
        "bead_count": 2,
        "color_options": ["银色", "黑色"],
        "preview_emoji": "⌚",
        "sort_order": 4,
    },
    {
        "id": "sku_004",
        "name": "小醒桌面摆件",
        "category": "companion",
        "description": "床头 AI 陪伴灯，圆形彩屏 + RGB 光环。服药到点自动提醒，轻触顶部确认。",
        "price_min": 399,
        "price_max": 699,
        "currency": "CNY",
        "in_stock": False,
        "coming_soon": True,
        "b2b_only": False,
        "customizable": False,
        "preview_emoji": "🌙",
        "sort_order": 5,
    },
    {
        "id": "sku_005",
        "name": "电子胸牌（企业版）",
        "category": "badge",
        "description": "水墨屏 + 急救 QR 码 + 数字虚拟人。适合养老机构、医院随访管理，B2B 批量采购。",
        "price_min": 0,
        "price_max": 0,
        "currency": "CNY",
        "in_stock": False,
        "coming_soon": False,
        "b2b_only": True,
        "customizable": False,
        "preview_emoji": "🪪",
        "sort_order": 6,
    },
]

_MOCK_MODELS = [
    {"id": "m_001", "name": "经典圆珠", "category": "round", "price": 0, "is_free": True,
     "description": "标准圆形珠子，经典百搭", "tags": ["基础款", "推荐"]},
    {"id": "m_002", "name": "星月造型", "category": "themed", "price": 19,
     "description": "新月 + 星星组合，契合醒伴品牌意象", "tags": ["品牌联名"]},
    {"id": "m_003", "name": "六棱柱", "category": "geometric", "price": 9,
     "description": "几何感强，适合简约风格", "tags": ["几何"]},
    {"id": "m_004", "name": "爱心珠", "category": "themed", "price": 15,
     "description": "送给关心你的家人，也送给自己", "tags": ["情感", "礼品"]},
    {"id": "m_005", "name": "自定义上传", "category": "upload", "price": 29,
     "description": "上传 STL/OBJ 文件，完全个性化定制", "tags": ["DIY", "专属"]},
]

_MOCK_ORDERS: list[dict] = []  # 内存中的演示订单


# ── SKU 列表 ────────────────────────────────────────────────────────
@router.get("/skus", summary="商品 SKU 列表")
async def list_skus(
    category: Optional[str] = Query(None, description="筛选分类：bracelet/custom/watchband/companion/badge"),
):
    skus = _MOCK_SKUS
    if category:
        skus = [s for s in skus if s["category"] == category]
    return {"skus": skus, "total": len(skus)}


@router.get("/skus/{sku_id}", summary="SKU 详情")
async def get_sku(sku_id: str):
    sku = next((s for s in _MOCK_SKUS if s["id"] == sku_id), None)
    if not sku:
        raise HTTPException(status_code=404, detail="商品不存在")
    return sku


# ── 3D 模型库 ────────────────────────────────────────────────────────
@router.get("/models", summary="3D 模型库")
async def list_models(
    category: Optional[str] = Query(None),
):
    models = _MOCK_MODELS
    if category:
        models = [m for m in models if m["category"] == category]
    return {"models": models, "total": len(models)}


@router.get("/models/{model_id}", summary="模型详情")
async def get_model(model_id: str):
    model = next((m for m in _MOCK_MODELS if m["id"] == model_id), None)
    if not model:
        raise HTTPException(status_code=404, detail="模型不存在")
    return model


# ── 创建定制订单 ──────────────────────────────────────────────────────
@router.post("/orders", status_code=status.HTTP_201_CREATED, summary="创建定制订单")
async def create_order(
    body: dict,
    user_id: str = Depends(get_current_user_id),
):
    """
    创建硬件定制订单。

    [IS_MOCK_MODE] SHOP_MOCK_MODE=true 时仅保存到内存，不实际提交供应商。
    切换真实供应商：
      1. 设置 SHOP_MOCK_MODE=false + SHOP_SUPPLIER_API_URL
      2. 在 _call_supplier() 中实现真实 HTTP 调用
    """
    sku_id   = body.get("sku_id", "")
    model_id = body.get("model_id")
    quantity = body.get("quantity", 1)
    specs    = body.get("specs", {})     # 颜色、尺寸等
    note     = body.get("note", "")

    sku = next((s for s in _MOCK_SKUS if s["id"] == sku_id), None)
    if not sku:
        raise HTTPException(status_code=400, detail="无效的 SKU")

    # 计算价格
    unit_price = sku["price_min"]
    if model_id:
        model = next((m for m in _MOCK_MODELS if m["id"] == model_id), None)
        if model:
            unit_price += model.get("price", 0)

    order_id = f"ORD_{uuid.uuid4().hex[:8].upper()}"
    now = datetime.now(timezone.utc).isoformat()

    order = {
        "id": order_id,
        "user_id": user_id,
        "sku_id": sku_id,
        "sku_name": sku["name"],
        "model_id": model_id,
        "quantity": quantity,
        "unit_price": unit_price,
        "total_price": unit_price * quantity,
        "currency": "CNY",
        "specs": specs,
        "note": note,
        "status": "pending",  # pending / confirmed / printing / shipped / delivered
        "created_at": now,
        "estimated_days": 7,
    }

    if getattr(settings, 'shop_mock_mode', True):
        _MOCK_ORDERS.append(order)
        logger.info("mock_order_created", order_id=order_id, sku=sku_id)
    else:
        # 真实供应商接入点（IS_MOCK_MODE=false 时实现）
        await _call_supplier(order)

    return {
        "order_id": order_id,
        "status": "pending",
        "total_price": order["total_price"],
        "currency": "CNY",
        "estimated_days": 7,
        "message": "订单已提交，预计 7 个工作日内发货",
        "_mock": getattr(settings, 'shop_mock_mode', True),
    }


# ── 订单历史 ──────────────────────────────────────────────────────────
@router.get("/orders", summary="我的订单")
async def list_orders(
    user_id: str = Depends(get_current_user_id),
):
    orders = [o for o in _MOCK_ORDERS if o["user_id"] == user_id]
    return {"orders": orders, "total": len(orders)}


@router.get("/orders/{order_id}", summary="订单详情")
async def get_order(
    order_id: str,
    user_id: str = Depends(get_current_user_id),
):
    order = next((o for o in _MOCK_ORDERS if o["id"] == order_id and o["user_id"] == user_id), None)
    if not order:
        raise HTTPException(status_code=404, detail="订单不存在")
    return order


# ── 真实供应商接入桩（IS_MOCK_MODE=false 时替换此函数） ─────────────────
async def _call_supplier(order: dict) -> dict:
    """
    接入真实 3D 打印供应商 API。
    IS_MOCK_MODE=false + SHOP_SUPPLIER_API_URL 配置后，在此实现：
      import httpx
      async with httpx.AsyncClient() as client:
          resp = await client.post(
              f"{settings.shop_supplier_api_url}/orders",
              json=order,
              headers={"Authorization": f"Bearer {settings.shop_supplier_api_key}"},
          )
          return resp.json()
    """
    raise NotImplementedError("真实供应商接入：请在 services/shop_supplier.py 中实现")
