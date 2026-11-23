# Post-release design backlog

Deferred design work — intentionally NOT blocking the first App Store release.
Each item is a considered improvement found during testing, to revisit as v1.1+.

---

## 1. Paid-out / Paid-in direction on column-based statements

**Status:** deferred to a post-release design pass (found 2026-07-14 during
curveball import testing).

**What happens today.** Some statements (HSBC/UK current-account and many
credit-card exports) print separate **"Paid out" / "Paid in"** columns — or
"Withdrawal / Deposit", "Money out / Money in" — instead of a signed amount.
When the PDF miner sees that column header but a given row carries no per-row
debit/credit marker (e.g. no `VIS` / `DD` / `CR` / `BGC` token), it defaults
the row to **spend (paid-out)** and emits an *"ambiguous-direction"* warning
(`PDFStatementImporter`, the `balanceHeaderDetected` / `ambiguousDirection`
path).

**The gap.** A row that is genuinely a **credit or refund** sitting in the
Paid-in column, with no marker, would be booked as a **charge** — wrong sign,
which inflates the loss total. Verified in testing: `03_multiline_running_balance`
produced 3 ambiguous-direction warnings; a refund in that layout could be
misread. (Refunds that carry an explicit `CR` marker already book correctly —
see `01_unknown_bank_offtable_refund`, which posted a −HK$ credit correctly.)

**Why it's safe to ship without fixing.** It only affects marker-less rows in
Paid-out/Paid-in *column* layouts, the app **warns** rather than silently
guessing, and the common case (signed single-amount columns, or rows with
markers) is correct today. No fabricated data — worst case is a
mis-signed row the user can see and delete.

**Proposed post-release pass.**
- Infer direction from **column position**: detect which numeric column each
  amount sits under (paid-out vs paid-in) using the header's horizontal
  offsets, and sign accordingly, instead of assuming spend.
- Where position is genuinely unrecoverable from the text layer, surface the
  ambiguous rows in the **import preview** as a quick "is this money out or
  in?" review step before commit — never silently assume.
- Add fixtures from the curveball set (`03_multiline_running_balance`,
  `01_unknown_bank_offtable_refund`) as permanent regression tests once the
  behaviour is defined.

**Touch points.** `Skimmed v3/ImportCore/PDFStatementImporter.swift`
(direction inference), the import preview UI, `AnalyzerCore` sign handling.
