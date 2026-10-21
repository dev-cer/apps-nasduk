from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional

app = FastAPI(title="Menu Service - Nasi Uduk Mpo Rohaya")

ADDON_PRICE = 5000  # harga add-on / menu tambahan per item

class AddOn(BaseModel):
    name: str
    price: int = 0
    target_users: Optional[str] = None

class PackageSet(BaseModel):
    id: int
    name: str
    price: int
    items: List[str]
    allowed_addons: List[AddOn]
    max_addons: int = 1

class ExtraItem(BaseModel):
    id: int
    name: str
    price: int

menu_db = [
    PackageSet(id=1, name="Paket Komplit Arupa", price=20000, items=["Nasi Uduk", "Bihun", "Orek Tempe", "Telur Balado", "Sambal Kacang & Merah (Dipisah)"], allowed_addons=[AddOn(name="Gorengan (Bakwan/Tempe)", price=ADDON_PRICE, target_users="Bayu, Pak Indra, Syifa"), AddOn(name="Semur (Tahu/Jengkol)", price=ADDON_PRICE, target_users="Daniel, Angel")]),
    PackageSet(id=2, name="Paket Sederhana Mpo", price=15000, items=["Nasi Uduk", "Bihun", "Orek Tempe", "Sambal Kacang & Merah Campur"], allowed_addons=[AddOn(name="Bakwan / Tahu", price=ADDON_PRICE, target_users="Itin"), AddOn(name="Telur Balado", price=ADDON_PRICE)]),
    PackageSet(id=3, name="Paket Semur Mantap", price=17000, items=["Nasi Uduk", "Telur Balado", "Orek Tempe", "Tahu Semur", "Sambal Kacang"], allowed_addons=[AddOn(name="Bihun", price=ADDON_PRICE, target_users="Falis"), AddOn(name="Ubah Porsi 1/2", price=0, target_users="Falis")]),
    PackageSet(id=4, name="Paket Hemat Bihun Only", price=10000, items=["Bihun Goreng Porsi Full", "Sambal Kacang"], allowed_addons=[AddOn(name="Telur Balado / Bakwan", price=ADDON_PRICE)])
]

# Menu tambahan yang bisa dipesan di luar paket
extras_db = [
    ExtraItem(id=1, name="Gorengan (Bakwan/Tempe/Tahu)", price=ADDON_PRICE),
    ExtraItem(id=2, name="Semur (Tahu/Jengkol)", price=ADDON_PRICE),
    ExtraItem(id=3, name="Telur Balado", price=ADDON_PRICE),
    ExtraItem(id=4, name="Bihun", price=ADDON_PRICE),
]

@app.get("/api/v1/menus", response_model=List[PackageSet])
def get_menus():
    return menu_db

@app.get("/api/v1/extras", response_model=List[ExtraItem])
def get_extras():
    return extras_db
