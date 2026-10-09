# S6 findings

Old-format migration findings S6-01/S6-02 and their gates were retired by the owner-approved 2026-10-09 format-zero removal.

Fixture development corrections: disk tests must use PersistenceController's configured filename (Local uses `development.store`), and an unmounted editor does not send native delegate notifications; recovery fixtures use the existing `performEdit` helper. These were test setup errors, not product findings.

- S6-03 · table/empty-line hint · P3 · insert table from Aa with the caret on a blank body line · expected no body hint during table-cell editing · actual hint remains and overlaps Add Row · `.build/evidence/s6-03-table-hint.png` · hint ignores live or remembered table focus. The insertion and page-return routes each failed a focused red test; the final guard suppresses the hint while a table owns selection/chrome and restores it after table deactivation.
