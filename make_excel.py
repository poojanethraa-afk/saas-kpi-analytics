"""Bundles the three CSVs into one Excel file (one sheet each) and checks CRM vs billing consistency."""
import pandas as pd
from openpyxl.utils import get_column_letter

crm = pd.read_csv("data/CRM_CUSTOMERS.csv", parse_dates=["SIGNUP_DATE"])
bill = pd.read_csv("data/BILLING_INVOICES.csv", parse_dates=["INVOICE_MONTH"])
fx = pd.read_csv("data/FX_RATES.csv", parse_dates=["RATE_MONTH"])

last = bill.groupby("CUSTOMER_ID").agg(LM=("INVOICE_MONTH", "max"), A=("AMOUNT", "last"))
j = crm.set_index("CUSTOMER_ID").join(last)
active = j.CRM_STATUS == "Active"
bad = j[(active != (j.LM == bill.INVOICE_MONTH.max())) | (active & (j.CRM_MRR != j.A))]
print("inconsistent rows:", len(bad))

with pd.ExcelWriter("saas_kpi_data.xlsx", engine="openpyxl",
                    date_format="YYYY-MM-DD", datetime_format="YYYY-MM-DD") as xw:
    for name, df in [("CRM_CUSTOMERS", crm), ("BILLING_INVOICES", bill), ("FX_RATES", fx)]:
        df.to_excel(xw, sheet_name=name, index=False)
        ws = xw.sheets[name]
        ws.freeze_panes = "A2"
        ws.auto_filter.ref = ws.dimensions
        for i, col in enumerate(df.columns, 1):
            width = max(len(col), df[col].astype(str).str.len().max()) + 2
            ws.column_dimensions[get_column_letter(i)].width = min(width, 32)

print(crm.CRM_STATUS.value_counts().to_dict(), crm.COUNTRY.value_counts().to_dict())
