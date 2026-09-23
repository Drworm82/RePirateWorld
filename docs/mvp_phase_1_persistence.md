# MVP Phase 1 — Death Bag persistence validation

## Final persistence contract

Death Bags are persistent world entities stored in the server SQLite database.

- A Death Bag is created when a player dies with loot.
- The database row survives server restart.
- A newly created bag starts in state `floating`.
- After the MVP floating period of 60 seconds, the bag changes to `sunk`.
- The `floating -> sunk` transition changes state only. It does not delete the database row.
- A `sunk` bag remains persisted until its contents are fully looted.
- Access to a sunk bag currently uses the simulated rewarded-ad flow.
- The database row is deleted only when the bag becomes empty through looting, including the sunk loot paths.
- The client receives a remove event when the bag is deleted.
- Automatic age-based deletion is not part of this MVP.
- Persistence and visibility are separate systems: database existence is not determined by whether a bag is currently visible to a player.

## Validation matrix

| Test | Expected result | Status |
|---|---|---|
| Create Death Bag | Row is inserted and inventory is transferred to the bag | Validated |
| Restart server before sinking | Bag remains available | Validated |
| Floating -> sunk after 60 s | State changes to `sunk`, row remains | Validated |
| Restart server after sinking | Sunk bag remains available | Validated |
| Access sunk bag | Simulated ad flow grants access | Validated |
| Loot sunk bag | Contents transfer to player | Validated |
| Empty bag | DB row is deleted and client receives remove event | Functionally validated; diagnostic confirmation added |
| Restart after emptying | Bag does not reappear | Validated |
| Instance unload/reload | In-memory unloading does not delete the persistent row | Code-validated |

## Development diagnostics

The `[DEATH_BAG_DIAG]` log entries are intentionally retained for the MVP validation phase.

Important events include:

- `before_insert`
- `after_insert`
- `list_request`
- `list_result`
- `after_sink`
- `delete reason=emptied`
- `after_delete_emptied`
- `load_not_found`

The `after_delete_emptied` diagnostic queries the database immediately after the DELETE and records the remaining Death Bag count for the affected instance.

## Closure criteria

Phase 1 Death Bag persistence is considered complete when the final end-to-end test confirms:

1. A bag is created.
2. It persists across a server restart.
3. It becomes `sunk` without being deleted.
4. It remains recoverable after another restart.
5. A different character can recover and loot it through the sunk-access flow.
6. Emptying it produces `delete` and `after_delete_emptied ... db_count=0` diagnostics.
7. A subsequent instance listing/restart does not return the emptied bag.

The remaining manual step is the final test of the new explicit DELETE diagnostics in the running server.
