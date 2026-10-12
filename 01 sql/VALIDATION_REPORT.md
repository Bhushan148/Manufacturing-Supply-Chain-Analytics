# Validation Report

Queries: `sql\07_validation.sql`. Run after every ETL and before/after any model or
report change: `sqlcmd -S localhost -d Manufacturing_DW -E -C -i sql\07_validation.sql`

---

## 2026-10-12 — Post narrative-retune baseline (CURRENT)

Retune applied in the source: **Supplier On-Time ~87%** (was ~43%) and a healthy
inventory **movement mix (~50% Active / ~30% Slow / ~21% Dead)** (was ~78% Dead).
Source reloaded + DW clean-rebuilt. All validation sections pass.

### Section 0 — Data quality — ✅ PASS
0 violations; mart counts = source; latest ETL batch 0 failed steps, 0 rejected rows.

### Section 1 — View ↔ base — ✅ PASS
All 10 views row-count + measure Diff = 0.

### Section 2 — Independent source reconciliation — ✅ PASS (not circular)
| Measure | DW | Source | Diff |
|---|--:|--:|--:|
| Net Sales | 679,119,505.87 | 679,119,505.87 | 0 |
| Shipped Qty | 6,188,758 | 6,188,758 | 0 |
| SalesOrderLine rows | 26,866 | 26,866 | 0 |
| PurchaseOrderLine rows | 11,097 | 11,097 | 0 |
| ShipmentLine rows | 25,413 | 25,413 | 0 |
| Shipment On-Time % | 91.1 (DW) | 91.2 (source dates) | ✓ |
| Supplier On-Time % | 87.41 (DW) | 87.4 (source dates) | ✓ |

### Section 3 — Golden KPI totals (expected values for Power BI DAX)
| KPI | Expected |
|---|--:|
| Net Sales | 679,119,505.87 |
| Gross Sales | 711,069,535.98 |
| Discount Amount | 31,950,030.11 |
| Order Quantity | 6,828,033 |
| Fulfilled Quantity | 6,188,758 |
| Backorder Quantity | 487,525 |
| Fill Rate % | 90.64 |
| Sales Orders | 12,000 |
| PO Value | 275,621,035.00 |
| Open PO Value | 26,448,715.20 |
| Rejected Quantity | 115,257 |
| Supplier On-Time % | 87.41 |
| Shipping Cost | 45,408,816.21 |
| Shipped Quantity | 6,188,758 |
| Delivery On-Time % | 91.06 |
| Return % | 1.61 |
| Inventory Value (latest snap) | 42,796,631.83 |
| On Hand Quantity (latest snap) | 2,076,884 |
| Stockout Bins (latest snap) | 59 |

### Sections 4 & 5 — Sliced checks & date roles — ✅ PASS
Date-order violations = 0. Pending (NULL actual-date) rows: 166 shipments, 653 PO lines.
Use the sliced subtotals to reconcile Power BI visuals once the model refresh is done.

---

## DAX Measure ↔ SQL control checklist (fill during model reconciliation)
Drop each measure on a card (no filters), compare to the golden total above.
Tolerance: exact for counts/amounts; ±0.1 for percentages.

| DAX Measure | Expected | Power BI | Match? |
|---|--:|--:|:--:|
| Net Sales | 679,119,505.87 | | ⬜ |
| Fill Rate % | 90.64 | | ⬜ |
| PO Value | 275,621,035.00 | | ⬜ |
| Open PO Value | 26,448,715.20 | | ⬜ |
| Supplier On-Time % | 87.41 | | ⬜ |
| Delivery On-Time % | 91.06 | | ⬜ |
| Return % | 1.61 | | ⬜ |
| Shipping Cost | 45,408,816.21 | | ⬜ |
| Inventory Value | 42,796,631.83 | | ⬜ |
| Stockout Bins | 59 | | ⬜ |

**Sliced check:** Net Sales by Year & Region, Supplier On-Time % by Risk, Delivery On-Time % by Carrier, Inventory Value by Warehouse — reconcile to Section 4.

---

> **Note:** these golden totals changed from the pre-retune baseline because the source was
> regenerated (RNG shift + healthier supplier delays). After you refresh the Power BI model,
> reconcile its measures to THIS table.

**Status:** Warehouse + `bi` contract validated. Golden totals re-baselined post-retune. Ready for model refresh + report reconciliation.
