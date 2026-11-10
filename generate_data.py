"""
Generates clean, fake SaaS data for a construction-software business for a mini KPI project.

Output (data/):
  CRM_CUSTOMERS.csv     - Salesforce-like customer list
  BILLING_INVOICES.csv  - monthly invoices from the billing system (local currency)
  FX_RATES.csv          - monthly CHF->EUR rates for harmonizing across countries
"""
import random
from pathlib import Path

import pandas as pd

random.seed(42)
OUT = Path(__file__).parent / "data"
OUT.mkdir(exist_ok=True)

MONTHS = pd.period_range("2025-01", "2026-09", freq="M")
LAST = MONTHS[-1]

PLANS = {  # plan -> monthly price (EUR, CHF)
    "Basis": (89, 95),
    "Regional": (149, 159),
    "Bundesweit": (299, 319),
}
PLAN_ORDER = list(PLANS)
TRADES = ["Hochbau", "Tiefbau", "Elektro", "Dach", "GaLaBau", "Maler", "Sanitaer/Heizung"]
DE_TEAMS = ["Nord", "Sued", "West", "Ost"]
PREFIX = ["Mueller", "Schmidt", "Weber", "Fischer", "Wagner", "Becker", "Hoffmann", "Koch",
          "Richter", "Klein", "Wolf", "Neumann", "Schwarz", "Braun", "Hofer", "Huber", "Keller"]
SUFFIX = ["Bau GmbH", "Bau AG", "Haustechnik GmbH", "Elektro GmbH", "Dachbau KG",
          "Tiefbau GmbH", "Garten- und Landschaftsbau", "Malerbetrieb", "Bauunternehmung"]

customers, invoices = [], []
for i in range(1, 501):
    cid = f"C{i:04d}"
    country = random.choices(["DE", "AT", "CH"], weights=[70, 15, 15])[0]
    team = random.choice(DE_TEAMS) if country == "DE" else {"AT": "Oesterreich", "CH": "Schweiz"}[country]
    currency = "CHF" if country == "CH" else "EUR"
    start = MONTHS[0] if i <= 150 else random.choice(MONTHS[1:])
    plan = random.choices(PLAN_ORDER, weights=[50, 35, 15])[0]

    active = True
    for m in pd.period_range(start, LAST, freq="M"):
        if m > start:  # plan changes / churn happen between months
            r = random.random()
            if r < 0.015:
                active = False
                break
            if r < 0.025 and plan != PLAN_ORDER[-1]:
                plan = PLAN_ORDER[PLAN_ORDER.index(plan) + 1]  # upgrade
            elif r < 0.03 and plan != PLAN_ORDER[0]:
                plan = PLAN_ORDER[PLAN_ORDER.index(plan) - 1]  # downgrade
        price = PLANS[plan][1 if currency == "CHF" else 0]
        invoices.append([cid, f"{m}-01", price, currency])

    customers.append({
        "CUSTOMER_ID": cid,
        "COMPANY_NAME": f"{random.choice(PREFIX)} {random.choice(SUFFIX)}",
        "COUNTRY": country,
        "TRADE": random.choice(TRADES),
        "SALES_TEAM": team,
        "SIGNUP_DATE": start.to_timestamp().strftime("%Y-%m-%d"),
        "CRM_STATUS": "Active" if active else "Churned",
        "PLAN": plan,
        "CRM_MRR": PLANS[plan][1 if currency == "CHF" else 0],
        "CURRENCY": currency,
    })

crm = pd.DataFrame(customers)
bill = pd.DataFrame(invoices, columns=["CUSTOMER_ID", "INVOICE_MONTH", "AMOUNT", "CURRENCY"])
fx = pd.DataFrame(
    [[f"{m}-01", "CHF", round(1.04 + 0.03 * random.random(), 4)] for m in MONTHS]
    + [[f"{m}-01", "EUR", 1.0] for m in MONTHS],
    columns=["RATE_MONTH", "CURRENCY", "RATE_TO_EUR"],
)

crm.to_csv(OUT / "CRM_CUSTOMERS.csv", index=False)
bill.to_csv(OUT / "BILLING_INVOICES.csv", index=False)
fx.to_csv(OUT / "FX_RATES.csv", index=False)
print(f"CRM rows: {len(crm)}, invoices: {len(bill)}, fx rows: {len(fx)}")
