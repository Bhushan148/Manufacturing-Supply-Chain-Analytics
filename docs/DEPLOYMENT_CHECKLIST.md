# Phase 7 — Power BI Service Deployment Checklist

Manual actions in Power BI Desktop + the Power BI Service portal. The shared model holds
all logic (measures, incremental refresh, RLS roles); the 3 thin reports inherit it.

## 1. Workspace
- [ ] Create workspace `Manufacturing Analytics` (or `…-DEV` / `…-PROD`).

## 2. Publish (model first, then reports)
- [ ] Publish `Manufacturing_SemanticModel.pbip` → workspace (this is the shared dataset).
- [ ] Publish `01_Executive_Overview`, `02_Inventory_Procurement`, `03_Fulfillment_Logistics`
      (thin reports — they live-connect to the published model; do NOT import data).

## 3. On-Premises Data Gateway (SQL Server is local)
- [ ] Install + register the Standard gateway on a machine that can reach `localhost\Manufacturing_DW`.
- [ ] Add data source: SQL Server `localhost`, database `Manufacturing_DW`, auth = Windows.
- [ ] Map the semantic model to the gateway (dataset ▸ Settings ▸ Gateway connection).

## 4. Refresh
- [ ] Scheduled refresh on the model — schedule it AFTER the SQL Agent ETL window
      (Python incremental → `usp_RunFullETL` → then model refresh).
- [ ] Incremental refresh: already defined in TMDL (rolling 6-yr window; refresh last
      6 months for Sales/PO, 3 months for Shipment/Inventory). Activates on first Service refresh.

## 5. Row-Level Security (RLS)
RLS logic lives in the MODEL (two roles, already built). Do the assignment + data here:
- [ ] Populate `SecurityWarehouseAccess` with real `User Email → Warehouse ID` rows
      (replace the synthetic rows; emails must match sign-in UPNs).
- [ ] Dataset ▸ Security:
      - `All Warehouses` → execs / leadership / admins (no filter).
      - `Warehouse Manager` → warehouse/regional managers (dynamic filter).
      - Do NOT add the same person to both (roles combine to widest access).
- [ ] Test ▸ "View as role" for each role before sharing.
- [ ] Note: Workspace Admin/Member/Contributor bypass RLS; only Viewers / App consumers are filtered.
- [ ] RLS is on the shared model → all 3 reports enforce it automatically (no per-report RLS).

## 6. Power BI App
- [ ] Create App on the workspace; include the model + 3 reports.
- [ ] Define audience(s) (e.g., one "Supply Chain" audience with all 3 reports; or split by team).
- [ ] Set navigation (the 3 reports as sections), publish the App.
- [ ] Grant access to users/groups. App viewers get RLS enforced.

## 7. Post-deploy validation
- [ ] After first refresh, reconcile headline KPI cards to `sql\VALIDATION_REPORT.md`
      (Net Sales 679,119,505.87; Supplier On-Time 87.41%; Delivery On-Time 91.06%; Inventory Value 42,796,631.83).
- [ ] Confirm gateway status green and scheduled refresh succeeds.

## Refresh dependency chain (target production flow)
```
Windows Task Scheduler → main_incremental_update.py → Manufacturing_Source
  → SQL Agent (usp_RunFullETL) → Manufacturing_DW
  → Power BI scheduled refresh (model) → 3 thin reports → App users
```
