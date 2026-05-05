import os
from typing import Optional
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

try:
    from livekit import api as livekit_api
except ImportError:  # pragma: no cover
    livekit_api = None


app = FastAPI(title="OneWay API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class StorefrontProduct(BaseModel):
    id: str
    storeId: Optional[str] = None
    name: str
    description: str
    price: float
    imageUrl: Optional[str] = None
    featured: bool = False
    published: bool = True
    isSubscription: bool = False


class StorefrontStore(BaseModel):
    id: str
    name: str
    slug: str
    tagline: Optional[str] = None
    featured: bool = True


class StorefrontResponse(BaseModel):
    store: StorefrontStore
    products: list[StorefrontProduct]
    featured: list[StorefrontProduct]
    heroTitle: str = "OneWay Live Storefront"
    heroSubtitle: str = "Shop live, call instantly, and buy securely from anywhere."


class LiveKitTokenRequest(BaseModel):
    roomName: str = Field(min_length=1)
    identity: str = Field(min_length=1)


class IceServer(BaseModel):
    urls: list[str]
    username: Optional[str] = None
    credential: Optional[str] = None


class LiveKitTokenResponse(BaseModel):
    token: str
    url: str
    iceServers: list[IceServer]


class InviteRequest(BaseModel):
    calleeUserId: str
    callerName: str
    roomName: str
    hasVideo: bool = True


def storefront_payload() -> StorefrontResponse:
    store = StorefrontStore(
        id="store-oneway-live",
        name="OneWay Live",
        slug="oneway-live",
        tagline="Premium live shopping, built for real devices.",
        featured=True,
    )

    products = [
        StorefrontProduct(
            id="prod-camera-light",
            storeId=store.id,
            name="Creator Key Light",
            description="Soft, flattering studio light tuned for live selling and video calls.",
            price=129.0,
            imageUrl="https://images.unsplash.com/photo-1516321318423-f06f85e504b3?auto=format&fit=crop&w=1200&q=80",
            featured=True,
        ),
        StorefrontProduct(
            id="prod-headset",
            storeId=store.id,
            name="Wireless Call Headset",
            description="Low-latency audio headset for LiveKit calling across Wi‑Fi and cellular.",
            price=199.0,
            imageUrl="https://images.unsplash.com/photo-1505740420928-5e560c06d30e?auto=format&fit=crop&w=1200&q=80",
            featured=False,
        ),
        StorefrontProduct(
            id="prod-phone-rig",
            storeId=store.id,
            name="Mobile Live Rig",
            description="Stabilized phone rig for creators who stream and sell on the go.",
            price=89.0,
            imageUrl="https://images.unsplash.com/photo-1516035069371-29a1b244cc32?auto=format&fit=crop&w=1200&q=80",
            featured=True,
        ),
    ]

    featured = [product for product in products if product.featured]
    return StorefrontResponse(store=store, products=products, featured=featured)


def build_turn_servers() -> list[IceServer]:
    turn_host = os.getenv("TURN_HOST", "turn.oneway.app")
    turn_username = os.getenv("TURN_USERNAME")
    turn_password = os.getenv("TURN_PASSWORD")

    return [
        IceServer(urls=["stun:stun.l.google.com:19302"]),
        IceServer(
            urls=[
                f"turn:{turn_host}:3478?transport=udp",
                f"turn:{turn_host}:3478?transport=tcp",
                f"turns:{turn_host}:5349?transport=tcp",
            ],
            username=turn_username,
            credential=turn_password,
        ),
    ]


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/storefront", response_model=StorefrontResponse)
async def storefront() -> StorefrontResponse:
    return storefront_payload()


@app.get("/products", response_model=list[StorefrontProduct])
async def products() -> list[StorefrontProduct]:
    return storefront_payload().products


@app.get("/featured")
async def featured() -> dict[str, object]:
    payload = storefront_payload()
    return {"products": payload.featured, "stores": [payload.store]}


@app.get("/api/storefronts")
async def storefronts() -> list[dict[str, object]]:
    payload = storefront_payload()
    return [
        {
            "id": payload.store.id,
            "ownerId": "owner-oneway",
            "name": payload.store.name,
            "slug": payload.store.slug,
            "description": payload.heroSubtitle,
            "category": "Live Commerce",
            "tagline": payload.store.tagline,
            "published": True,
            "products": payload.products,
            "collections": [],
            "theme": {
                "primaryHex": "#0A84FF",
                "accentHex": "#30D158",
                "background": "dark",
                "font": "SF Pro",
            },
            "layout": {
                "heroStyle": "immersive",
                "gridStyle": "cards",
                "spacing": 12,
            },
        }
    ]


@app.get("/api/history/recent")
async def history_recent(limit: int = 50) -> dict[str, list[dict[str, object]]]:
    entries = [
        {
            "id": "history-1",
            "callId": "call-history-1",
            "callerId": "Alex",
            "calleeId": "You",
            "direction": "incoming",
            "status": "completed",
            "durationSeconds": 425,
            "startedAt": 1_715_000_000_000,
            "endedAt": 1_715_000_425_000,
            "hasVideo": True,
            "voicemailId": None,
        }
    ]
    return {"entries": entries[:limit]}


@app.get("/api/voicemail/{user_id}")
async def voicemail(user_id: str) -> dict[str, list[dict[str, object]]]:
    return {"voicemails": []}


@app.post("/calls/invite")
async def calls_invite(payload: InviteRequest) -> dict[str, object]:
    return {
        "ok": True,
        "callId": str(uuid4()),
        "roomName": payload.roomName,
        "callerName": payload.callerName,
        "hasVideo": payload.hasVideo,
    }


@app.post("/livekit/token", response_model=LiveKitTokenResponse)
@app.post("/api/livekit/token", response_model=LiveKitTokenResponse)
async def livekit_token(payload: LiveKitTokenRequest) -> LiveKitTokenResponse:
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    livekit_url = os.getenv("LIVEKIT_URL", "wss://rtc.oneway.app")

    if not api_key or not api_secret:
        raise HTTPException(status_code=500, detail="LIVEKIT_API_KEY and LIVEKIT_API_SECRET are required")

    if livekit_api is None:
        raise HTTPException(status_code=500, detail="livekit-api package is not installed")

    token = (
        livekit_api.AccessToken(api_key, api_secret)
        .with_identity(payload.identity)
        .with_name(payload.identity)
        .with_grants(
            livekit_api.VideoGrants(
                room_join=True,
                room=payload.roomName,
                can_publish=True,
                can_subscribe=True,
                can_publish_data=True,
            )
        )
        .to_jwt()
    )

    return LiveKitTokenResponse(
        token=token,
        url=livekit_url,
        iceServers=build_turn_servers(),
    )
