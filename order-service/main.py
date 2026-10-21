import io
import json
import os
import secrets
import sqlite3
import urllib.request
from datetime import date, datetime, timedelta, timezone
from typing import Dict, List, Literal, Optional

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill
from pydantic import BaseModel, Field

app = FastAPI(title="Order Service - Nasi Uduk Mpo Rohaya")

DB_PATH = os.getenv("ORDERS_DB_PATH", "/data/orders.db")
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")
MENU_SERVICE_URL = os.getenv("MENU_SERVICE_URL", "http://menu-service")
PAYMENT_NUMBER = os.getenv("PAYMENT_NUMBER", "+6285669684973")
WIB = timezone(timedelta(hours=7))

PAYMENT_METHODS = ("GoPay", "OVO", "ShopeePay")
UNPAID, PAID = "Belum Bayar", "Lunas"

class ExtraOrder(BaseModel):
    id: int
    qty: int = Field(1, ge=1, le=50)

class OrderRequest(BaseModel):
    customer_name: str
    package_id: int
    quantity: int = Field(1, ge=1, le=50)
    addons: List[str] = []
    extras: List[ExtraOrder] = []
    note: str = Field("", max_length=500)
    payment_method: Literal["GoPay", "OVO", "ShopeePay"]

class Order(BaseModel):
    order_id: int
    customer_name: str
    package_id: int
    package_name: str
    quantity: int
    addons: List[str]
    extras: List[Dict]
    note: str
    total: int
    payment_method: str
    payment_status: str
    paid_at: Optional[str]
    created_at: str

class PaymentUpdate(BaseModel):
    payment_status: Literal["Belum Bayar", "Lunas"]

COLUMNS = {
    "quantity": "INTEGER NOT NULL DEFAULT 1",
    "addons": "TEXT NOT NULL DEFAULT '[]'",
    "extras": "TEXT NOT NULL DEFAULT '[]'",
    "note": "TEXT NOT NULL DEFAULT ''",
    "total": "INTEGER NOT NULL DEFAULT 0",
    "payment_method": "TEXT NOT NULL DEFAULT ''",
    "payment_status": f"TEXT NOT NULL DEFAULT '{UNPAID}'",
    "paid_at": "TEXT",
}

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

@app.on_event("startup")
def init_db():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    with get_db() as conn:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS orders (
                order_id INTEGER PRIMARY KEY AUTOINCREMENT,
                package_id INTEGER NOT NULL,
                package_name TEXT NOT NULL,
                customer_name TEXT NOT NULL,
                created_at TEXT NOT NULL
            )"""
        )
        # Tambah kolom baru pada database lama tanpa menghapus data
        existing = {r["name"] for r in conn.execute("PRAGMA table_info(orders)")}
        for name, ddl in COLUMNS.items():
            if name not in existing:
                conn.execute(f"ALTER TABLE orders ADD COLUMN {name} {ddl}")

def fetch_json(path: str):
    try:
        with urllib.request.urlopen(MENU_SERVICE_URL + path, timeout=5) as res:
            return json.load(res)
    except Exception:
        raise HTTPException(status_code=503, detail="Menu Service tidak bisa dihubungi, coba lagi sebentar")

def require_admin(token: Optional[str]):
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="ADMIN_TOKEN belum diatur di server")
    if not token or not secrets.compare_digest(token, ADMIN_TOKEN):
        raise HTTPException(status_code=401, detail="Token admin salah")

def row_to_order(r: sqlite3.Row) -> Order:
    d = dict(r)
    d["addons"] = json.loads(d["addons"])
    d["extras"] = json.loads(d["extras"])
    return Order(**d)

def fetch_orders(day: Optional[date]) -> List[Order]:
    query, params = "SELECT * FROM orders", ()
    if day:
        query, params = query + " WHERE substr(created_at, 1, 10) = ?", (day.isoformat(),)
    with get_db() as conn:
        rows = conn.execute(query + " ORDER BY order_id", params).fetchall()
    return [row_to_order(r) for r in rows]

def describe_items(o: Order) -> str:
    parts = [f"{o.quantity}x {o.package_name}"]
    parts += [f"+ {a}" for a in o.addons]
    parts += [f"{e['qty']}x {e['name']}" for e in o.extras]
    return ", ".join(parts)

@app.get("/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/api/v1/orders", response_model=List[Order])
def list_orders(date: Optional[date] = None, x_admin_token: Optional[str] = Header(None)):
    require_admin(x_admin_token)
    return fetch_orders(date)

@app.patch("/api/v1/orders/{order_id}/payment", response_model=Order)
def update_payment(order_id: int, body: PaymentUpdate, x_admin_token: Optional[str] = Header(None)):
    require_admin(x_admin_token)
    paid_at = datetime.now(WIB).isoformat(timespec="seconds") if body.payment_status == PAID else None
    with get_db() as conn:
        cur = conn.execute(
            "UPDATE orders SET payment_status = ?, paid_at = ? WHERE order_id = ?",
            (body.payment_status, paid_at, order_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Pesanan tidak ditemukan")
        row = conn.execute("SELECT * FROM orders WHERE order_id = ?", (order_id,)).fetchone()
    return row_to_order(row)

@app.get("/api/v1/orders/export.xlsx")
def export_orders(date: Optional[date] = None, x_admin_token: Optional[str] = Header(None)):
    require_admin(x_admin_token)
    orders = fetch_orders(date)

    wb = Workbook()
    ws = wb.active
    ws.title = "Pesanan"
    ws.append(["No. Pesanan", "Waktu (WIB)", "Nama Pemesan", "Pesanan", "Catatan", "Total (Rp)", "Metode Bayar", "Status Bayar", "Waktu Lunas"])
    for cell in ws[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="B45309")
    for o in orders:
        waktu = datetime.fromisoformat(o.created_at).strftime("%Y-%m-%d %H:%M")
        lunas = datetime.fromisoformat(o.paid_at).strftime("%Y-%m-%d %H:%M") if o.paid_at else ""
        ws.append([o.order_id, waktu, o.customer_name, describe_items(o), o.note, o.total, o.payment_method, o.payment_status, lunas])
        ws.cell(row=ws.max_row, column=6).number_format = "#,##0"

    # Rekap jumlah porsi dan pendapatan per paket
    rekap = wb.create_sheet("Rekap")
    rekap.append(["Nama Paket", "Jumlah Porsi"])
    for cell in rekap[1]:
        cell.font = Font(bold=True)
    porsi: Dict[str, int] = {}
    for o in orders:
        porsi[o.package_name] = porsi.get(o.package_name, 0) + o.quantity
    for name, qty in porsi.items():
        rekap.append([name, qty])
    rekap.append([])
    for label, value in (
        ("Jumlah Pesanan", len(orders)),
        ("Total Tagihan (Rp)", sum(o.total for o in orders)),
        ("Sudah Lunas (Rp)", sum(o.total for o in orders if o.payment_status == PAID)),
        ("Belum Bayar (Rp)", sum(o.total for o in orders if o.payment_status != PAID)),
    ):
        rekap.append([label, value])
        rekap.cell(row=rekap.max_row, column=1).font = Font(bold=True)
        rekap.cell(row=rekap.max_row, column=2).number_format = "#,##0"

    for sheet, widths in ((ws, [12, 18, 24, 60, 30, 14, 14, 14, 18]), (rekap, [28, 16])):
        for col, width in zip("ABCDEFGHI", widths):
            sheet.column_dimensions[col].width = width

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    filename = f"pesanan-{date.isoformat() if date else 'semua'}.xlsx"
    return StreamingResponse(
        buf,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )

@app.post("/api/v1/orders")
def create_order(req: OrderRequest):
    name = req.customer_name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Nama pemesan wajib diisi")

    # Harga selalu dihitung ulang dari Menu Service, bukan dari browser
    menus = {m["id"]: m for m in fetch_json("/api/v1/menus")}
    package = menus.get(req.package_id)
    if not package:
        raise HTTPException(status_code=404, detail=f"Paket ID {req.package_id} tidak ditemukan")

    addon_prices = {a["name"]: a.get("price", 0) for a in package["allowed_addons"]}
    addons = list(dict.fromkeys(req.addons))
    unknown = [a for a in addons if a not in addon_prices]
    if unknown:
        raise HTTPException(status_code=400, detail=f"Add-on tidak tersedia untuk paket ini: {', '.join(unknown)}")
    if len(addons) > package.get("max_addons", 1):
        raise HTTPException(status_code=400, detail=f"Maksimal {package.get('max_addons', 1)} add-on untuk paket ini")

    extras_menu = {e["id"]: e for e in fetch_json("/api/v1/extras")} if req.extras else {}
    extras = []
    for e in req.extras:
        item = extras_menu.get(e.id)
        if not item:
            raise HTTPException(status_code=400, detail=f"Menu tambahan ID {e.id} tidak ditemukan")
        extras.append({"id": e.id, "name": item["name"], "qty": e.qty, "price": item["price"]})

    total = (package["price"] + sum(addon_prices[a] for a in addons)) * req.quantity
    total += sum(e["qty"] * e["price"] for e in extras)

    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO orders (package_id, package_name, customer_name, created_at, quantity, addons,
                                   extras, note, total, payment_method, payment_status)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (req.package_id, package["name"], name, datetime.now(WIB).isoformat(timespec="seconds"),
             req.quantity, json.dumps(addons), json.dumps(extras), req.note.strip(), total,
             req.payment_method, UNPAID),
        )
        order_id = cur.lastrowid
    return {
        "message": f"Pesanan {name} sudah diterima dapur",
        "order_id": order_id,
        "total": total,
        "payment_method": req.payment_method,
        "payment_number": PAYMENT_NUMBER,
        "payment_status": UNPAID,
    }
