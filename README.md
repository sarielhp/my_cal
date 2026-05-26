# my_cal

A native Ruby command-line client for Google Calendar. It operates independently of external Python scripts, using its own locally managed credentials and local caching strategies to achieve fast, responsive interaction.

## Features

- **Offline Caching Layer**: Caches calendars and events locally, using parallel threaded reloading and background validation to reduce load times to under 150 milliseconds.
- **Interactive Side-by-Side TUI**: Provides a terminal month grid and schedule explorer with responsive arrow-key navigation and automatic terminal resizing support.
- **Natural Language Quick-Add**: Support for adding events using natural text descriptions, automatically matching a persistently configured default calendar.
- **Full Custom Additions**: Supports creating custom timed or all-day events with options for summary, description, and location.
- **Chronological Friendly IDs**: Sequential event numbering (`[1]`, `[2]`, `[3]`) mapped chronologically for concise identification in console printouts.
- **Event Merging**: Safe combining of duplicate events occurring at identical times with matching recurrence rules.
- **Recurrence Support**: Visual tracking of parent recurrence frequencies (Daily, Weekly, Monthly, Yearly).
- **Suppressed Email Updates**: Prevents unwanted guest notification emails when making mutations on the API.
- **Aliasing & Customization**: Persistently configure short custom aliases for complex calendar IDs.
- **Sequential Search**: Comprehensive multi-scoped calendar keyword searching (Week, Month, Year).
- **High-Visibility Console Styling**: Clean layout formatted to an 80-character boundary using high-contrast terminal styling.

## Installation

### Prerequisites
- Ruby 2.7 or higher
- The `rainbow` gem (`gem install rainbow`)
- Existing `gcalcli` OAuth credentials (only required on the first execution to automatically initialize credentials)

### Setup
1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/my_cal.git
   cd my_cal
   ```
2. Make `my_cal` executable:
   ```bash
   chmod +x my_cal
   ```
3. Run the list command to initialize credentials from `gcalcli` and verify the setup:
   ```bash
   ./my_cal list
   ```

## Usage

```
Usage:
  ./my_cal [interactive] [-i] [-r] - Show interactive side-by-side month/schedule TUI (default)
  ./my_cal list                    - Show all calendars and status
  ./my_cal today [-i] [-r]         - Show schedule for today and tomorrow
  ./my_cal next [-i]               - Show the next upcoming/active event with countdown
  ./my_cal week [cal-name] [-i][-r]- Show this week's events
  ./my_cal month [cal-name] [-i][-r]- Show next month's events
  ./my_cal year [cal-name] [-i][-r]- Show all events in calendar for a year in compact single-line layout
  ./my_cal alias <name> <alias>    - Set an alias/shortcut for a calendar
  ./my_cal alias <name> ""         - Remove an alias/shortcut for a calendar
  ./my_cal default <cal-name>      - Set the default calendar persistently
  ./my_cal add "<text>"             - Quick-add an event to the default calendar
  ./my_cal add-full <cal> <sum> <start> <end> [desc] [loc] - Create a full event in a calendar
  ./my_cal del_event <id>          - Delete an event by friendly ID
  ./my_cal web <id>                - Open event in web browser
  ./my_cal merge <id1> <id2>       - Merge two events with identical times and rules
  ./my_cal search <word> [-i] [-r] - Search all calendars sequentially
  ./my_cal reload                  - Explicitly reload local calendar cache
```

*Note: Append `?` to any command (e.g. `./my_cal add "?"`) to show detailed argument and usage help.*

## Running Tests
Run the built-in unit test suite offline:
```bash
./my_cal test
```

## License
MIT License.
