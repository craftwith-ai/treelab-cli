# {{PROJECT}} — lane `{{LANE}}`

**Intent** : <!-- what this lane delivers, in one line: `lab plan {{PROJECT}}` shows it -->

This file belongs to the lane `{{LANE}}` only: no other lane writes here, and it writes in no other.
It holds the order and intent of the batches. A batch's state lives in its batch file (`docs/lots/{{LANE}}/`) and
`lab plan {{PROJECT}}` recomputes progress on display: no progress marker here.

## Batches

<!-- one line per batch, in order: - [lot-NN-slug](../lots/{{LANE}}/lot-NN-slug.md) — intent and announced exit criterion -->
