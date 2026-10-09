# S6 findings

- S6-01 · migration inverse · P2 · construct a plan with two tray images, swap the trailing blocks, verify · expected refusal · actual success · `.build/evidence/tray-red.log` · inverse projection omitted tray-order comparison. Fixed with a separate expected-tray order check.
- S6-02 · migration Unicode fidelity · P2 · construct decomposed accent text, supply a canonically equal composed title/body through the inverse/round-trip seam · expected refusal · canonical `String` equality can mask code-unit changes · `.build/evidence/unicode-red.log` · exact UTF-16 title and deterministic encoded-document checks added after the red test.

Fixture development corrections: disk tests must use PersistenceController's configured filename (Local uses `development.store`), and an unmounted editor does not send native delegate notifications; recovery fixtures use the existing `performEdit` helper. These were test setup errors, not product findings.
