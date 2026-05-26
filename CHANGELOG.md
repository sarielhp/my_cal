# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2026-05-26
### Added
- Added `default <calendar-name>` command to persistently configure a default calendar in `~/.config/my_cal/config.json`.
- Added natural language quick-add command (`add "<text>"`) calling Google Calendar API's `quickAdd` endpoint to easily append events to the default calendar (falling back to primary).
- Added `add-full <cal> <summary> <start> <end> [desc] [loc]` command to create a custom timed/all-day event in the specified calendar.
- Integrated a comprehensive command-specific help system: appending `?` to any CLI command (e.g. `./my_cal add "?"`) prints premium cyan headers, detailed usage descriptions, flags, arguments, and CLI examples.
- Enhanced test coverage by adding robust unit test suites (`test_set_default_calendar_success`, `test_quick_add_event_success`, `test_add_full_event_success`, `test_show_detailed_help`) with Net::HTTP stubbing.
- Added off-line test execution command `./my_cal test` which runs the complete Minitest suite instantly.

### Changed
- Replaced all standard red (`.red`) colors across warnings, errors, and high-priority rating highlights with bright bold red (`.red.bright`) to optimize readability on dark backgrounds.
- Suppressed constant re-initialization warnings when double-loading files by wrapping all top constants in `unless defined?` guards.

## [0.2.0] - 2026-05-26
### Added
- Initialized native Ruby Google Calendar CLI tool, renamed to `my_cal` (executable `my_cal`).
- Implemented `gcalcli` OAuth2 credentials pickle parsing via system `python3` subprocess.
- Created robust `/tmp` JSON access token caching to reuse valid tokens and minimize endpoint requests.
- Created automatic config folder initialization at `~/.config/my_cal/` for persistent settings.
- Implemented persistent credentials storage in `~/.config/my_cal/credentials.json` loaded from the local `gcalcli` pickle file on the first run, allowing complete independence from `gcalcli` on subsequent executions.
- Added custom calendar shortcuts/aliasing via `./my_cal alias <calendar-name> <shortcut>`, stored persistently in `aliases.json`.
- Added `list` command to display accessible Google Calendars, their roles, selection status, and configured aliases in optimized columns to prevent wrapping.
- Added `week` command to display the current week's schedule grouped by day, omitting empty days, with calendar-specific colors (using aliases where configured).
- Added `month <calendar>` command to show the next calendar month's schedule.
- Added `add_priority <calendar>` command to automatically scan future events and remotely update descriptions to append priority levels (with safety rescue blocks for special calendars).
- Implemented `-i` flag to output a unique 8-character event ID prefix next to summaries.
- Implemented `del_event <id>` command to remotely delete events using prefix-matched short IDs.
- Appended `sendUpdates=none` to remote event PATCH and DELETE API queries, preventing automatic attendee email notifications.
- Implemented sequential case-insensitive search (`search <word>`) and scoped search (`search_week`, `search_month`, `search_year`) commands.
- Implemented a local JSON-based calendar events caching layer (`calendar_cache.json`) for instant search command lookup.
- Added automatic 24-hour cache expiration and reload logic, and a manual `reload` command to explicitly refresh the cache.
- Implemented automated cache invalidation on remote event modifications/deletions.
- Expanded `test_my_cal.rb` unit test suite to cover credentials initialization, cache control, event displaying configurations, remote deletion, sequential/scoped searches, and cache expiration logic.

## [0.2.0] - 2026-05-26
### Added
- Implemented concurrent fetching and local caching of parent master recurrence rules (`RRULE`) during reload/cache update.
- Implemented in-memory recurrence frequency parsing (`Daily`, `Weekly`, `Monthly`, `Yearly`) and colorized `(⟲ Frequency)` display via a new `-r` flag.
- Created chronological sequential integer `_friendly_id` mappings (e.g. `[12]`) when rendering schedule lists with the `-i` flag.
- Added `web <friendly_id>` command, opening the event's remote edit link (`htmlLink`) in a cross-platform default internet browser.
- Added `merge <friendly_id1> <friendly_id2>` command to combine duplicate events taking place at the exact same time and sharing the same recurrence frequency pattern. Deduplicates attendee lists, merges descriptions with custom divider lines, combines locations, patches the master event, deletes the duplicate event, and updates the local cache in-place.
- Designed a side-by-side terminal interactive Month Grid and Event Schedule TUI, supporting arrow-key date navigation and auto-scaling to console height.
- Added `year [calendar]` command to show all events in the specified calendar (or all selected calendars) for the current calendar year in a compact, single-line format aligned exactly to 80 characters.
- Refactored `week` and `month` schedule commands to support an optional `[calendar]` argument for strict single-calendar filtering.
- Expanded the unit test suite (`test_my_cal.rb`) with comprehensive test methods for web opening, event merging logic, recurrence pattern checks, TUI calendar rendering, yearly compact layouts, and optional calendar filtering on week and month schedules.

### Fixed
- Fixed a Rainbow gem bug where calling `.reverse` instead of `.inverse` crashed string highlighting on selected TUI dates.
- Removed the heavy bottom horizontal border lines (`└────...`) separating consecutive days in today, week, and month schedule list prints for a lighter, cleaner visual design.
