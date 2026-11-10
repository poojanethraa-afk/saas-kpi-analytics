-- Step 3: cleaning, reconciliation and SaaS KPIs
-- Run after uploading the 3 CSV files into SAAS_DEMO.RAW

USE WAREHOUSE COMPUTE_WH;
USE SCHEMA SAAS_DEMO.ANALYTICS;

-- 1) CRM without duplicates (one row per customer)
CREATE OR REPLACE VIEW CUSTOMERS_CLEAN AS
SELECT *
FROM RAW.CRM_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY COMPANY_NAME DESC) = 1;

-- 2) Reconciliation: where do CRM and billing disagree? (checked on the latest month)
CREATE OR REPLACE VIEW RECON_CRM_VS_BILLING AS
WITH last_month AS (
    SELECT MAX(TO_DATE(INVOICE_MONTH)) AS M FROM RAW.BILLING_INVOICES
),
billed AS (
    SELECT b.CUSTOMER_ID, b.AMOUNT AS BILLED_AMOUNT
    FROM RAW.BILLING_INVOICES b, last_month
    WHERE TO_DATE(b.INVOICE_MONTH) = last_month.M
),
crm AS (
    SELECT CUSTOMER_ID,
           MAX(COMPANY_NAME) AS COMPANY_NAME,
           MAX(CRM_STATUS)   AS CRM_STATUS,
           MAX(CRM_MRR)      AS CRM_MRR,
           COUNT(*)          AS CRM_ROWS
    FROM RAW.CRM_CUSTOMERS
    GROUP BY CUSTOMER_ID
)
SELECT COALESCE(c.CUSTOMER_ID, b.CUSTOMER_ID) AS CUSTOMER_ID,
       c.COMPANY_NAME, c.CRM_STATUS, c.CRM_MRR, b.BILLED_AMOUNT, c.CRM_ROWS,
       CASE
           WHEN c.CUSTOMER_ID IS NULL                                  THEN 'Invoiced, but missing in CRM'
           WHEN c.CRM_ROWS > 1                                         THEN 'Duplicate record in CRM'
           WHEN c.CRM_STATUS = 'Active'  AND b.CUSTOMER_ID IS NULL     THEN 'CRM Active, but no invoice in last month'
           WHEN c.CRM_STATUS = 'Churned' AND b.CUSTOMER_ID IS NOT NULL THEN 'CRM Churned, but still invoiced'
           WHEN c.CRM_STATUS = 'Active'  AND c.CRM_MRR <> b.BILLED_AMOUNT THEN 'CRM MRR differs from billed amount'
       END AS ISSUE
FROM crm c
FULL OUTER JOIN billed b ON b.CUSTOMER_ID = c.CUSTOMER_ID
WHERE ISSUE IS NOT NULL;

-- 3) Monthly revenue per customer, harmonized to EUR (CH customers pay in CHF)
CREATE OR REPLACE VIEW MRR_MONTHLY AS
SELECT b.CUSTOMER_ID,
       TO_DATE(b.INVOICE_MONTH)            AS MONTH,
       b.AMOUNT                            AS AMOUNT_LOCAL,
       b.CURRENCY,
       ROUND(b.AMOUNT * fx.RATE_TO_EUR, 2) AS MRR_EUR
FROM RAW.BILLING_INVOICES b
JOIN RAW.FX_RATES fx
  ON fx.CURRENCY = b.CURRENCY
 AND TO_DATE(fx.RATE_MONTH) = TO_DATE(b.INVOICE_MONTH);

-- 4) MRR movements: New / Expansion / Contraction / Churn / Retained per customer and month
--    Classified on the LOCAL amount, so CHF exchange-rate changes don't look like upsell
CREATE OR REPLACE VIEW MRR_MOVEMENTS AS
WITH months AS (SELECT DISTINCT MONTH FROM MRR_MONTHLY),
     custs  AS (SELECT DISTINCT CUSTOMER_ID FROM MRR_MONTHLY),
     grid AS (
         SELECT c.CUSTOMER_ID, m.MONTH,
                COALESCE(r.MRR_EUR, 0)      AS MRR_EUR,
                COALESCE(r.AMOUNT_LOCAL, 0) AS AMOUNT_LOCAL
         FROM custs c
         CROSS JOIN months m
         LEFT JOIN MRR_MONTHLY r ON r.CUSTOMER_ID = c.CUSTOMER_ID AND r.MONTH = m.MONTH
     ),
     lagged AS (
         SELECT *,
                LAG(MRR_EUR, 1, 0)      OVER (PARTITION BY CUSTOMER_ID ORDER BY MONTH) AS PREV_MRR_EUR,
                LAG(AMOUNT_LOCAL, 1, 0) OVER (PARTITION BY CUSTOMER_ID ORDER BY MONTH) AS PREV_AMOUNT_LOCAL
         FROM grid
     )
SELECT l.CUSTOMER_ID, l.MONTH, l.MRR_EUR, l.PREV_MRR_EUR,
       COALESCE(cc.COUNTRY, 'Unknown')    AS COUNTRY,
       COALESCE(cc.SALES_TEAM, 'Unknown') AS SALES_TEAM,
       COALESCE(cc.TRADE, 'Unknown')      AS TRADE,
       CASE
           WHEN l.PREV_AMOUNT_LOCAL = 0 AND l.AMOUNT_LOCAL > 0  THEN 'New'
           WHEN l.PREV_AMOUNT_LOCAL > 0 AND l.AMOUNT_LOCAL = 0  THEN 'Churn'
           WHEN l.AMOUNT_LOCAL > l.PREV_AMOUNT_LOCAL            THEN 'Expansion'
           WHEN l.AMOUNT_LOCAL < l.PREV_AMOUNT_LOCAL            THEN 'Contraction'
           ELSE 'Retained'
       END AS MOVEMENT
FROM lagged l
LEFT JOIN CUSTOMERS_CLEAN cc ON cc.CUSTOMER_ID = l.CUSTOMER_ID
WHERE l.AMOUNT_LOCAL > 0 OR l.PREV_AMOUNT_LOCAL > 0;

-- 5) Monthly KPIs, split by country and sales team (Power BI sums them up)
CREATE OR REPLACE VIEW KPI_MONTHLY AS
SELECT MONTH, COUNTRY, SALES_TEAM,
       SUM(MRR_EUR)                                                  AS MRR_EUR,
       SUM(MRR_EUR) * 12                                             AS ARR_EUR,
       COUNT_IF(MRR_EUR > 0)                                         AS ACTIVE_CUSTOMERS,
       COUNT_IF(PREV_MRR_EUR > 0)                                    AS CUSTOMERS_START_OF_MONTH,
       COUNT_IF(MOVEMENT = 'New')                                    AS NEW_CUSTOMERS,
       COUNT_IF(MOVEMENT = 'Churn')                                  AS CHURNED_CUSTOMERS,
       SUM(IFF(MOVEMENT = 'New',         MRR_EUR, 0))                AS NEW_MRR,
       SUM(IFF(MOVEMENT = 'Expansion',   MRR_EUR - PREV_MRR_EUR, 0)) AS EXPANSION_MRR,
       SUM(IFF(MOVEMENT = 'Contraction', MRR_EUR - PREV_MRR_EUR, 0)) AS CONTRACTION_MRR,
       SUM(IFF(MOVEMENT = 'Churn',       -PREV_MRR_EUR, 0))          AS CHURNED_MRR
FROM MRR_MOVEMENTS
WHERE MONTH > '2025-01-01'   -- first month has no "previous month", so everyone would look "New"
GROUP BY MONTH, COUNTRY, SALES_TEAM;

-- 6) NRR / GRR: revenue today from the customers we had 12 months ago
CREATE OR REPLACE VIEW NRR_12M AS
WITH months AS (SELECT DISTINCT MONTH FROM MRR_MONTHLY)
SELECT m.MONTH,
       SUM(b.MRR_EUR)                                                   AS BASE_MRR_12M_AGO,
       SUM(COALESCE(n.MRR_EUR, 0))                                      AS SAME_CUSTOMERS_MRR_NOW,
       ROUND(DIV0(SUM(COALESCE(n.MRR_EUR, 0)), SUM(b.MRR_EUR)), 3)      AS NRR,
       ROUND(DIV0(SUM(LEAST(COALESCE(n.MRR_EUR, 0), b.MRR_EUR)), SUM(b.MRR_EUR)), 3) AS GRR
FROM months m
JOIN MRR_MONTHLY b      ON b.MONTH = DATEADD(MONTH, -12, m.MONTH)
LEFT JOIN MRR_MONTHLY n ON n.CUSTOMER_ID = b.CUSTOMER_ID AND n.MONTH = m.MONTH
GROUP BY m.MONTH;

-- Quick checks
SELECT ISSUE, COUNT(*) AS CUSTOMERS FROM RECON_CRM_VS_BILLING GROUP BY ISSUE ORDER BY 2 DESC;
SELECT * FROM NRR_12M ORDER BY MONTH;
