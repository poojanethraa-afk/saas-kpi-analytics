-- Step 1: create the database and two schemas
--   RAW       = data exactly as it comes from the source systems (CRM, billing)
--   ANALYTICS = cleaned data + KPI views for Power BI

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS SAAS_DEMO;
CREATE SCHEMA IF NOT EXISTS SAAS_DEMO.RAW;
CREATE SCHEMA IF NOT EXISTS SAAS_DEMO.ANALYTICS;

-- Keep the trial credits safe: warehouse sleeps after 60s of no use
ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = 60;
