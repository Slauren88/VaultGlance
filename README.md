# VaultGlance

A World of Warcraft addon for **The War Within (Midnight)** that provides a quick overview of your Great Vault progress — as overlay panels on the vault window, a minimap button with full hover summary, and chat notifications on completion.

## Background

I had the idea for this addon back during The War Within, but never had the coding skills to build it myself. With the rise of AI coding assistants, I decided to give it a shot — feeding my vision to Claude and iterating on the result through a (very) tedious back-and-forth conversation. Every feature, color choice, and layout decision was directed by me; the AI handled the Lua. What you see here is the result of that experiment — a fully functional addon born from human design intent and AI implementation.

If you find bugs or rough edges, that's the nature of the process. Pull requests and issue reports are welcome.

## Features

### Vault Overlay Panels
Three panels anchored to the left of the Great Vault window, showing your completed activities for each vault row:

- **Dungeons** — Keystones sorted by level, heroic/M0 runs. Names from M+ run history and local tracking.
- **Raids** — Killed bosses with difficulty (RF/N/H/M), sorted by difficulty descending.
- **World/Delves** — Delve tiers and Prey completions from the vault API, merged with locally tracked names.

Each panel includes:
- Gold separator lines at vault slot thresholds (1/4/8 dungeons, 2/4/6 raids, 2/4/8 delves)
- Reward item level displayed at each threshold
- Color-coded difficulty indicators matching gear track colors

### Minimap Button (LibDBIcon)
- **Left-click** to open/close the Great Vault
- **Hover** for a full vault summary showing all three rows with entries, locked slots, and reward ilvls
- **Drag** to reposition around the minimap

### Chat Notifications
- Completion messages when you finish a dungeon, kill a raid boss, or complete a delve
- Vault upgrade notifications when a slot's reward tier improves, including the new ilvl

### Settings Panel
Accessible via the vault overlay, with toggles for:
- **Minimap Button** — show/hide
- **Hover Summary** — enable/disable the full tooltip on minimap hover
- **Color Full Line** — color the entire entry line vs just the difficulty indicator

## Color Scheme

Difficulty indicators are colored by gear reward track:

| Content | White | Green | Blue | Purple | Orange |
|---------|-------|-------|------|--------|--------|
| Dungeons | Heroic | M0 | +2 to +5 | +6 to +9 | +10+ |
| Raids | — | RF | N | H | M |
| Delves | T1 | T2-4 | T5-7 | T8+ | — |

## Slash Commands

- `/vg` — Open/close the Great Vault
- `/vg refresh` — Force data refresh
- `/vg list` — Print full vault summary to chat
- `/vg help` — Show command list

## API Notes

The addon reads vault data directly from the `C_WeeklyRewards` API:

- **Activity slots**: `C_WeeklyRewards.GetActivities(type)` — type 1 = Dungeons, 3 = Raids, 6 = World/Delves
- **Per-run breakdowns**: `C_WeeklyRewards.GetSortedProgressForActivity(type, activityID)` — returns difficulty and count per tier
- **Reward ilvl**: `C_WeeklyRewards.GetExampleRewardItemHyperlinks(activityID)` — parsed via `GetItemInfo`
- **Dungeon names**: `C_MythicPlus.GetRunHistory()` + `C_ChallengeMode.GetMapUIInfo()` for M+ runs; local tracking via `CHALLENGE_MODE_COMPLETED` for keystones
- **Delve names**: Local tracking via `SCENARIO_COMPLETED` event
- **Raid data**: `GetSavedInstanceEncounterInfo()` for boss kill lists

### Known API Limitations

The WoW API has several gaps that affect what the addon can display:

- **Heroic vs M0 dungeons are indistinguishable.** The vault API (`GetSortedProgressForActivity`) reports both heroic and Mythic 0 dungeon completions as `difficulty=0` with `activityTierID=101`. While the vault UI itself shows "Heroic" vs "Mythic 0" labels per slot (using the per-slot `activityTierID` field — 101 for Heroic, 102 for M0), the per-run breakdown doesn't split them. On top of that, the `LFG_COMPLETION_REWARD` event doesn't fire for heroic dungeon completions in Midnight, so local tracking can't distinguish them either. Unnamed level-0 dungeon entries are shown as "Dungeon M0 / HC".

- **Delve names require local tracking.** The vault API provides accurate tier data for delves via `GetSortedProgressForActivity(6, id)`, but no delve names. Names are captured locally when `SCENARIO_COMPLETED` fires at the end of a delve. If the addon wasn't installed when you ran a delve, that entry will show as "Delve Tx" without a name. Names don't transfer between computers.

- **Delve tiers can't be read from instance data.** `GetInstanceInfo()` returns a `difficultyID` for delves (e.g. 208 for a T6 delve), but this doesn't map linearly to the actual tier. The addon reads tiers exclusively from the vault API instead.

- **Prey completions are invisible to the addon.** Prey is open-world content with no instance, so no completion event fires. Prey completions do appear in the vault API at their corresponding tier (Normal Prey = T1, Hard Prey = T5, Nightmare Prey = T8), but they're indistinguishable from delve runs at the same tier. Unnamed entries at T1, T5, and T8 are labeled "Delve Tx / Prey N/H/NM" to indicate the ambiguity.

- **Reward ilvl may lag on first open.** `GetExampleRewardItemHyperlinks` returns an item link, but `GetItemInfo` often returns nil until the item is cached by the client. The addon requests item data and retries after 0.5 seconds automatically.

## Data Storage

- **VaultGlanceDB** (account-wide) — settings, minimap position, per-character vault snapshots
- **VaultGlanceCharDB** (per-character) — locally tracked dungeon/delve names, weekly reset timer

Character vault snapshots are saved to `VaultGlanceDB.characters["Name-Realm"]` on login and after every completion, containing the full vault state for future alt overview features.

## Installation

1. Download or clone this repository
2. Copy the `VaultGlance` folder into your `World of Warcraft/_retail_/Interface/AddOns/` directory
3. Restart WoW or `/reload`

## Planned Features

- [ ] Alt overview — view all characters' vault progress from minimap hover or a dedicated window
- [x] Prune stale alt data after 2 weeks of inactivity
- [ ] Track `activityTierID` to distinguish Heroic vs M0 dungeon runs per vault slot
- [ ] Detect dungeon completions via `ENCOUNTER_END` for local name tracking of heroic dungeons
- [ ] Option to show/hide individual panels (dungeons/raids/delves)
- [ ] Panel positioning options (left/right of vault, stacking order)
- [ ] Export/share vault status (e.g. copy to clipboard for Discord)
- [ ] Integration with other tooltip addons
- [ ] Replace bundled libs with official versions (LibStub, CallbackHandler, LibDataBroker, LibDBIcon)

## Requirements

- World of Warcraft: The War Within — Midnight (Interface 120001)
- No external dependencies (libs are bundled)

## License

MIT
