"""Fixed catalogs for synthetic event generation."""

MERCHANTS = [
    {"merchant_id": f"M{i:04d}", "merchant_name": name}
    for i, name in enumerate(
        [
            "CloudPay Global",
            "SwiftCart Online",
            "TechBazaar",
            "FreshMart Delivery",
            "UrbanRide Transit",
            "PixelPlay Games",
            "GreenLeaf Organics",
            "JetSet Travel",
            "AudioWave Music",
            "ByteSize Storage",
            "NovaPharma",
            "SilverScreen Cinema",
            "AquaFit Wellness",
            "CodeBrew Coffee",
            "SkyLink Telecom",
            "PrimeStitch Fashion",
            "IronForge Hardware",
            "BloomBox Florist",
            "DataVault Hosting",
            "ZenSpa Retreat",
            "Velocity Motors",
            "CrystalClear Optics",
            "NorthStar Insurance",
            "EcoPower Energy",
        ],
        start=1,
    )
]

BINS = [
    {"issuer_bin": "411111", "card_brand": "VISA"},
    {"issuer_bin": "424242", "card_brand": "VISA"},
    {"issuer_bin": "555555", "card_brand": "MASTERCARD"},
    {"issuer_bin": "510510", "card_brand": "MASTERCARD"},
    {"issuer_bin": "378282", "card_brand": "AMEX"},
    {"issuer_bin": "371449", "card_brand": "AMEX"},
    {"issuer_bin": "601100", "card_brand": "DISCOVER"},
    {"issuer_bin": "644000", "card_brand": "DISCOVER"},
]

REGIONS = {
    "NA": ["US", "CA", "MX"],
    "EU": ["GB", "DE", "FR", "NL", "ES"],
    "APAC": ["JP", "AU", "SG", "IN"],
    "LATAM": ["BR", "AR", "CL", "CO"],
}

CARD_BRANDS = ["VISA", "MASTERCARD", "AMEX", "DISCOVER"]

PAYMENT_METHODS = ["CREDIT", "DEBIT", "PREPAID"]

DECLINE_CODES = [
    "INSUFFICIENT_FUNDS",
    "STOLEN_CARD",
    "EXPIRED_CARD",
    "DO_NOT_HONOR",
    "ISSUER_UNAVAILABLE",
    "INVALID_CVV",
    "VELOCITY_LIMIT",
    "FRAUD_SUSPECTED",
]
