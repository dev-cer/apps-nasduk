from datetime import datetime, timezone
from itertools import count
from typing import List

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Order Service - Nasi Uduk Mpo Rohaya")

# ID paket yang tersedia di Menu Service
VALID_PACKAGE_IDS = {1, 2, 3, 4}

class OrderRequest(BaseModel):
    package_id: int
    customer_name: str

class Order(BaseModel):
    order_id: int
    package_id: int
    customer_name: str
    created_at: str

orders_db: List[Order] = []
order_counter = count(1)

@app.get("/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/api/v1/orders", response_model=List[Order])
def list_orders():
    return orders_db

@app.post("/api/v1/orders")
def create_order(req: OrderRequest):
    name = req.customer_name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Nama pemesan wajib diisi")
    if req.package_id not in VALID_PACKAGE_IDS:
        raise HTTPException(status_code=404, detail=f"Paket ID {req.package_id} tidak ditemukan")

    order = Order(
        order_id=next(order_counter),
        package_id=req.package_id,
        customer_name=name,
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    orders_db.append(order)
    return {"message": f"Pesanan {name} untuk paket {req.package_id} sudah diterima dapur", "order_id": order.order_id}
