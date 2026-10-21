from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional

app = FastAPI(title="Menu Service - Nasi Uduk Mpo Rohaya")

class AddOn(BaseModel):
    name: str
    target_users: Optional[str] = None

class PackageSet(BaseModel):
    id: int
    name: str
    items: List[str]
    allowed_addons: List[AddOn]
    max_addons: int = 1

menu_db = [
    PackageSet(id=1, name="Paket Komplit Arupa", items=["Nasi Uduk", "Bihun", "Orek Tempe", "Telur Balado", "Sambal Kacang & Merah (Dipisah)"], allowed_addons=[AddOn(name="Gorengan (Bakwan/Tempe)", target_users="Bayu, Pak Indra, Syifa"), AddOn(name="Semur (Tahu/Jengkol)", target_users="Daniel, Angel")]),
    PackageSet(id=2, name="Paket Sederhana Mpo", items=["Nasi Uduk", "Bihun", "Orek Tempe", "Sambal Kacang & Merah Campur"], allowed_addons=[AddOn(name="Bakwan / Tahu", target_users="Itin"), AddOn(name="Telur Balado")]),
    PackageSet(id=3, name="Paket Semur Mantap", items=["Nasi Uduk", "Telur Balado", "Orek Tempe", "Tahu Semur", "Sambal Kacang"], allowed_addons=[AddOn(name="Bihun", target_users="Falis"), AddOn(name="Ubah Porsi 1/2", target_users="Falis")]),
    PackageSet(id=4, name="Paket Hemat Bihun Only", items=["Bihun Goreng Porsi Full", "Sambal Kacang"], allowed_addons=[AddOn(name="Telur Balado / Bakwan")])
]

@app.get("/api/v1/menus", response_model=List[PackageSet])
def get_menus():
    return menu_db
