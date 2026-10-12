# Row-Level Security (RLS)

Warehouse-level, dynamic, defined once in the shared semantic model and inherited by all three thin reports.

## How it works
```
SecurityWarehouseAccess (User Email, Warehouse ID)   <- hidden table, sample data
        │  read by the role filter (no relationship needed)
        ▼
role 'Warehouse Manager':  DimWarehouse[Warehouse ID] IN (warehouses listed for USERPRINCIPALNAME())
        ▼
DimWarehouse ──► FactSalesOrder, FactPurchaseOrder, FactShipment, FactInventorySnapshot
```
- `USERPRINCIPALNAME()` returns the signed-in user's email in Power BI Service. The match ignores case.
- The filter sits on `DimWarehouse` only; the existing single-direction relationships carry it to all four fact tables.
- A user with no row in the table sees no data. A user may have several rows (several warehouses).

## Roles
| Role | Filter | Use for |
|---|---|---|
| **Warehouse Manager** | `DimWarehouse` rows whose Warehouse ID is listed for the user's email | Warehouse, regional and procurement managers |
| **All Warehouses** | none | Executives and administrators |

Do not put the same person in both roles: roles combine to the widest access.

## Replace the sample data
The table is a Power Query `#table` in `tables\SecurityWarehouseAccess.tmdl` (Desktop: **Transform data ▸ SecurityWarehouseAccess**, step *Created sample access list*).
Sample emails are placeholders (`@example.com`). One row per user and warehouse; Warehouse ID comes from `bi.DimWarehouse` (e.g. `WH-US-DET-01`).

To move it into the warehouse later: create a table or view in `Manufacturing_DW` (columns `User Email`, `Warehouse ID`), expose it through a `bi` view, and replace the first step of the query with a navigation to it. The role does not change.

## Where it is shown
Report 2 (`02_Inventory_Procurement`) is the RLS showcase. The header of every page carries a line from the measure `RLS Access Text`: *Row-level security | user@company.com | 6 warehouses in scope*. It makes the role visible, and it ignores warehouse slicers so the count shows the user's access, not their selection.

Demo script:
1. **Modeling > View as > Warehouse Manager**, tick **Other user**, enter `europe.manager@example.com`.
2. Open *Inventory Health*: the status chart shows the 6 European warehouses and every KPI card changes; the header line says 6 warehouses.
3. Switch to **All Warehouses**: all 22 warehouses return and the header line says 22.
4. Open *Procurement Performance* and drill through to *Product 360* to show the filter holds on every page.

## Test it
1. Desktop: **Modeling ▸ View as ▸ Warehouse Manager**, tick **Other user**, enter e.g. `europe.manager@example.com`. Check that only the six European warehouses appear and every card changes.
2. Check the date-role measures (`... (by promised date)` etc.) while viewing as the role. They use `USERELATIONSHIP`, and Power BI restricts that function in some RLS setups; if one errors, tell me.
3. Total with **All Warehouses** must still equal the golden totals in `sql\VALIDATION_REPORT.md`.

## After publishing
Members are assigned in Power BI Service: **workspace ▸ semantic model ▸ Security**. Add each user or group to the right role there. Workspace Admin, Member and Contributor roles bypass RLS, so test with a Viewer.

## Limits to know
- Only `DimWarehouse` is secured. Product, Customer, Supplier, Carrier and Date lists still show every member; fact values for other warehouses are simply blank.
- The mapping is data in the model, so anyone with edit rights on the model can read it. The table is hidden from report authors.
- Changing the access list needs a model refresh.
