# Ad-hoc Analysis — Findings (updated 2026-10-12, post narrative-retune)

Source: `bi.*` views on `Manufacturing_DW`. Queries: `sql\06_analysis.sql`.
These findings drive what each of the three thin reports shows, and feed the golden
totals in `sql\VALIDATION_REPORT.md`.

## Headline KPIs (grand total)
| KPI | Value |
|---|---|
| Net Sales | **$679.1M** |
| Gross Sales / Discount | $711.1M / $32.0M (4.5%) |
| Fill Rate % | **90.6%** |
| Backorder Qty | 487,525 |
| Sales Orders | 12,000 |
| PO Value / Open PO Value | $275.6M / $26.4M |
| Rejected Qty | 115,257 |
| **Supplier On-Time %** | **87.4%** ✅ |
| **Delivery On-Time %** | **91.1%** ✅ |
| Return % | 1.61% |
| Shipping Cost | $45.4M |
| Inventory Value | $42.8M |
| Stockout bins | 59 |
| Inventory movement | ~50% Active / ~30% Slow / ~21% Dead ✅ |

## The data story (what's real and explainable)
1. **Growth trend is clear.** Net Sales by year: 2021 $67.3M → 2022 $81.6M (+21%) → 2023 $93.3M (+14%) → **2024 $135.0M (+45%, APAC/export expansion event)** → 2025 $147.3M (+9%) → 2026 $100.8M (partial year, Jan–Aug).
2. **ABC is value-correct.** A = 77.1% of sales, B = 18.0%, C = 4.8% (textbook Pareto).
3. **Top categories:** Steering ($210M), Braking ($104M), Suspension ($97M).
4. **Customer delivery is healthy (91.3% on-time)**; **fill rate 90.5%** with a visible backorder tail.

## Narrative decisions — RESOLVED (retuned 2026-10-12)
1. **Supplier On-Time retuned to 87.4%** (Low 91.4% > Med 87.6% > High 75.7% — gradient preserved), via healthier `SUPPLIER_DELAY_PROFILE` + centred per-supplier offset. Was 42.9%.
2. **Inventory movement retuned to a healthy mix** (~50% Active / ~30% Slow / ~21% Dead) via realistic `LastMovementDateTime` seeding. Was ~78% Dead.
3. Source reloaded + DW clean-rebuilt; all validation passes and reconciles to source. The story now reads as a well-run operation end to end.

## Suggested mapping → 3 thin reports
- **01 Executive Overview:** Net Sales + YoY, Fill Rate %, Delivery On-Time %, Inventory Value, Supplier On-Time %, Return %.
- **02 Inventory & Procurement:** inventory value/stockouts/excess by warehouse & category; PO value, open-PO, supplier on-time by risk, rejections; **Product 360 drill-through**.
- **03 Fulfillment & Logistics:** order value, fill rate, backorders by customer type; delivery on-time, delay, shipping cost, returns by carrier/mode/region.

## Reproduce
`sqlcmd -S localhost -d Manufacturing_DW -E -C -i sql\06_analysis.sql`
