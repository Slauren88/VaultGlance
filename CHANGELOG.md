# Changelog

## [0.1.1] - 2026-04-20

### Added
- Account-wide character vault snapshots for future alt overview feature
- Reward ilvl display at vault slot thresholds (overlay panels + minimap hover)
- Automatic item cache retry when ilvl data isn't immediately available
- Full vault summary in minimap hover tooltip (all 3 rows with entries, ilvl, locked slots)
- Prey tier support (Normal=T1, Hard=T5, Nightmare=T8) with labeled unnamed entries
- Chat notifications on dungeon/raid/delve completion
- Vault upgrade notifications with ilvl when a slot tier improves
- "Color Full Line" setting toggle
- "Locked" indicator at threshold positions in minimap hover
- Word-boundary name truncation (max 25 chars)
- LibDBIcon minimap button with drag repositioning
- Bundled LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0

### Changed
- Renamed addon from VaultProgress to VaultGlance
- Slash command changed to `/vg` (removed `/vp`)
- LFR renamed to RF in all displays
- Removed parentheses around difficulty indicators
- Dungeon level 0 entries show as "H" (Heroic) instead of "M0"
- Unnamed entries show "Dungeon M0 / HC", "Delve Tx", or "Delve Tx / Prey N/H/NM"
- Delve tiers read from vault API instead of guessing from difficultyID
- Dungeon names sourced from API + GetRunHistory + local tracking (same pattern as delves)
- Color scheme: White (Explorer) → Green (Veteran) → Blue (Champion) → Purple (Hero) → Orange (Myth)
- Delve T8+ capped at purple (same reward tier)
- Brightened blue (#3399FF) and purple (#CC66FF) for dark background readability

### Fixed
- Delve tier detection (difficultyID doesn't map linearly to tier)
- Info tooltip formatting (replaced SetText with AddLine calls)
- Singleton frame guards using _G references
