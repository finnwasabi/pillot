# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.6] - 2026-11-03

### Fixed
- Notification permission was asked only once, on the first screen, so a dismissed prompt meant no notifications for
  good. The app now asks on launch while the permission was never decided, and Diagnostics shows it, with a button to
  Settings when it was denied.

## [0.5.5] - 2026-11-03

### Changed
- Opening the app no longer reads back every alarm and notification when the planned reminders are the same as last
  time: with a year of history a pass drops from about 26 to 44 ms to about 5 to 9 ms in the Simulator. Several
  changes made at once (a restore, the editor) now run as one rescheduling pass.
- Today and History work out each medication's history once per minute or data change instead of on every redraw. A
  tap, a filter or a month change in History went from about 7 ms to under 0.1 ms with a year of history.
- "Back to the usual time?" on Today and the taken time editor in History now open from the root of the app, like the
  medication editor, so a timeline redraw or a tab change cannot tear them down.

## [0.5.4] - 2026-11-02

### Changed
- Taken on a ringing alarm now silences it and opens the app, which asks "Taken?" before logging. On a locked phone a
  hardware button press once ran Taken on 0.5.3 without the button being touched, so no button on the alarm logs a dose
  by itself any more. Slide to stop and the side button still only silence the ring.
- Diagnostics lists the last alarm buttons in one row.

## [0.5.3] - 2026-11-02

### Changed
- On a ringing alarm, slide to stop and the side button now only silence this ring; the next reminder comes within the
  snooze length, so the side button snoozes as in the Clock app. Only the Taken button logs the dose. In 0.5.1 and 0.5.2
  slide to stop was Taken, and on a phone the side button runs the same action, so a press of the side button logged the
  dose. Alarms set by older versions are replaced on the first launch.

### Fixed
- The test alarm in Settings could be cancelled right after it was set when the app rescheduled at the same moment, and
  Taken on it did not stop the ringing.

## [0.5.2] - 2026-11-02

### Fixed
- 0.5.1 could not set any alarm: iOS refused every one (Diagnostics showed "Failed" and 0 alarms set) because the alarm was
  made without a countdown duration. Alarms are set again, and Diagnostics and the Today banner now show the error iOS
  gave instead of only a count.

## [0.5.1] - 2026-11-02

### Changed
- A dose that is not taken now rings again every snooze length (5 to 15 minutes, 9 by default) instead of three rings
  five minutes apart: for the first three hours after the dose time, around the deadline, and for the first three hours
  after it, then hourly until the dose counts as missed. Four medications still fit five days in the alarm budget.
- The alarm buttons follow the Clock app: sliding to stop is Taken and the button is Snooze, which silences only this ring
  because the next one is already scheduled. On iOS 26.1 and later the side button presses the slide control, so it may
  log Taken; Diagnostics shows the last buttons pressed so this can be checked on a phone. Alarms set by older versions
  are replaced on the first launch.
- The snooze length in Settings starts at 5 minutes (shorter rings would use up the alarm budget).

### Added
- Settings > Diagnostics has a test alarm that rings in a minute with the real buttons and changes no data, and lists the
  last alarm buttons pressed.

### Fixed
- When iOS could not list the alarms, a reschedule added every planned alarm a second time. It now stops and reports the failure.

### Removed
- The snooze countdown alarm the Stop button scheduled, and the unused per-medication snooze setting in the planner.

## [0.5.0] - 2026-10-31

### Fixed
- A quick press of the side button on a ringing alarm logged the dose as taken. Since iOS 26.1 the system draws its own
  Stop button and the side button presses it, and Stop ran "Taken". Stop and the side button now snooze (the lock
  screen shows the countdown and it rings again), and only the Taken button logs the dose. Alarms set by older
  versions are replaced on the first launch.
- The Disconnect and Delete confirmations opened off to the side, and Disconnect only opened after flipping the
  sharing switch. Each confirmation now opens from its own button.
- Changing a medication's time, doses a day, gap, days off or end date no longer re-reads its whole history under the
  new schedule. Before, a month of daily doses turned into a month of misses after switching to twice a day; the past is
  now frozen as it was.
- Deleting a skip or a make-up did nothing when pills were not counted (a regression caught by the tests before release).
- The Settings page could be dragged sideways a little on some phones; it now keeps the screen's width.

### Added
- Medications taken only when needed: no schedule, no alarms, nothing missed. Today shows how many today, the last one,
  and warns when it is sooner than the minimum gap or more than the daily maximum you set.
- Courses with an end date, like 7 days of antibiotics: nothing rings after the last day and Today says the course is done.
- Several pills per dose: the count goes down and back up by that many.
- A faint pill pattern behind every screen.

### Changed
- The maximum gap can go up to twice the time between doses (48 h for a daily dose). It still cannot go below that
  time, and the editor says to choose more doses a day for a shorter one.
- The bot shows medications taken when needed, finished courses and pills per dose, and never nudges about them.

## [0.4.1] - 2026-10-30

### Changed
- The medium widget is its own widget without a medication to pick: it lists the next three doses. Picking a medication
  stays on the small and lock screen widgets. A medium widget placed with 0.4.0 disappears; add it again.
- "Taken" on the small and medium widgets also shows before dose time, like the button in the app, so it is there
  whenever the next dose is coming up. The lock screen widget is still a button only once the dose is due.

## [0.4.0] - 2026-10-30

### Added
- Delete a dose tapped as Taken by mistake, from History, after the undo window: the dose comes back (still due if
  there is time, missed if not) and the pill is given back.
- Tap a day on the History calendar to list only that day's doses; tap it again or "Show recent" to go back. The recent
  list has "Show more" after the first 20.
- "Taken" right on the widget: on the small and medium widgets for each dose that is due or late, and on the lock screen
  widget, which becomes the button while the first dose is due. It runs in the app, so alarms are rescheduled too.
- Pick the medication a widget shows: touch and hold the widget, Edit Widget, Medication. The small and lock screen
  widgets show only that one; the medium widget lists it first. Left empty, it follows the next due dose as before.
- The Meds tab explains the three steps until the first medication is added, and a new medication starts with the
  cursor in its name.

## [0.3.6] - 2026-10-30

### Changed
- Only the dose coming up gets the whole reminder chain (repeats, hourly, final stretch, overdue). Later doses get
  their main reminder and the ringing deadline, and get the whole chain once they are next. Four medications at 1, 2, 3
  and 6 doses a day now fit 14 days in the alarm budget instead of 57 hours.
- Rescheduling touches only what changed. Each alarm and notification remembers what it was made from, and a pass
  leaves the matching ones alone. In the Simulator with the sample data: reopening the app went from 1,998 ms to 74 ms
  with nothing changed; tapping Taken on one of four medications changed 102 alarms instead of replacing all of them.
- The app asks iOS for a background refresh every few hours to top the alarms up when it is not opened for days.
  iOS decides whether it runs; Diagnostics shows the last run.

### Added
- Diagnostics shows how many alarms and notifications the last pass changed, and the last background run.

## [0.3.5] - 2026-10-30

### Changed
- Today, History and the widget stay fast as history grows. Planning used to slow down with the square of the number
  of records (one year of a 6-a-day dose took 7 ms per query on a Mac, three years 34 ms); it is now linear and each
  screen walks every history once per redraw instead of about ten times. Measured on a Mac with four medications, the
  planning work of one Today redraw went from 93 ms to 2 ms after one year of data, and from 608 ms to 6 ms after three.
- The History counts follow the month shown in the calendar, and sit under it.
- Holding the snooze stepper reschedules once after you let go instead of on every step.
- Settings has a Diagnostics section: alarm permission, how many alarms and notifications are set, the last reminder
  they reach, how long the last scheduling took, and whether the widget can read the data.

### Fixed
- "Taken" in History no longer drops to 0 when you add a pack of pills.
- The widget showed "Next" in the evening for a daily dose taken that morning, while the app showed "Taken". Both use one rule now.
- Missed doses kept getting a new identity every minute, and two medications missed at the same moment could share
  one row.
- The "Back to the usual time" question is presented by the Today screen, not by a card that redraws every minute.

## [0.3.4] - 2026-10-30

### Added
- A small burst of confetti when you tap Taken or Took all. Reduce Motion turns it off; the haptic still plays.

### Fixed
- Taking a dose no longer crossfades the old and new card contents on top of each other on Today.

## [0.3.3] - 2026-10-30

### Fixed
- The whole tab bar flashed on every tab change: each screen carried its own copy of the bar. There is one bar again, and the highlight slides under the labels instead of fading over them. The same fix keeps the medication editor and the segmented choices on a single sheet and a single highlight.

## [0.3.2] - 2026-10-30

### Fixed
- Add medication sometimes opened nothing on the Meds tab, and from then on no screen could open the editor until the app was restarted. Adding and editing now share one editor sheet at the root of the app.

### Changed
- Smoother navigation: the tab bar highlight slides between tabs, the tapped icon bounces and the new screen fades in. Segmented choices slide too, stepper numbers roll, and medication cards animate when added, removed, taken or skipped. Reduce Motion turns the movement off.

## [0.3.1] - 2026-10-30

### Changed
- The app is now called Pillot, and the repository is `finnwasabi/pillot`. Installed copies update in place and keep their data, and the old SideStore source addresses keep working through GitHub's redirect.
- Backups are saved as `Pillot-backup-YYYY-MM-DD.json`. Backups saved by Medly still restore.
- The Telegram bot is named Pillot.

## [0.3.0] - 2026-10-30

### Added
- Backup and restore: save a file with every medication, its history and your preferences wherever you like (iCloud Drive, Google Drive, a chat), and restore it after a confirmation. Settings reminds you when there is no recent backup.
- Skip this dose: stops the reminders for one dose without counting it as missed or using a pill. It can be undone for 10 minutes on Today, or deleted in History.
- Days off in a cycle, such as 21 days on and 7 off: nothing rings and nothing counts as missed on days off.
- Home screen and lock screen widgets with the next doses.
- An App Shortcut, "I took my meds", for Siri, Shortcuts and Spotlight.
- A first launch step to pick light, dark or the phone's appearance, before the language.
- Bot: a nudge when a deadline passes with no dose reported, skipped doses, and the bot is named Medly.

### Changed
- The app is now called Medly, and the repository is `finnwasabi/medly`. Installed copies update in place and keep their data.
- The data file moves into an App Group shared with the widget.

## [0.2.1] - 2026-10-29

### Added
- Appearance in Settings: follow the phone, light or dark.
- Pills per pack for each medication. "Add a pack" adds that many, and starting to count suggests one pack.
- Number steppers repeat while held, and pill counts can be typed. The remaining count can be corrected down as well as up.

### Changed
- Outlines are slightly thinner, and small elements (chips, pills, calendar days) use a thinner line than cards.
- The maximum gap row shows its range, and the footer explains why it cannot be shorter than the time between doses.
- Pausing a medication also stops its ringing or snoozed alarm.

### Fixed
- Tapping the snooze stepper crashed the app.
- The end of every screen stayed hidden under the tab bar on 6.1 inch iPhones.
- A medication deleted while its editor was open came back on Save.
- Server: calls to Telegram no longer fail about half the time on hosts without IPv6, and setting the command menu is retried.

## [0.2.0] - 2026-10-29

### Added
- A Meds tab: keep several medications, each with its own name, color, icon, dose time, doses per day (1, 2, 3, 4 or 6), maximum gap, pill count, refill reminder and pause.
- Reminders name the medication. Medications due at the same moment share one alarm, and one "Taken" covers them all; a "Took all" button appears on Today when several are due.
- The maximum gap between doses can be changed, from one period up to one and a half (24 to 36 hours for a daily medication).
- Snooze length in Settings, 1 to 15 minutes. Snooze as often as needed; only "Taken" stops an alarm.
- History filters by medication.
- Bot: `/start`, `/help`, `/clearmsg`, a Copy button on `/link`, a Refresh button on `/check` and the morning report, messages when a medication is added or removed, and a command menu and profile descriptions.

### Changed
- A brand new look: cute neubrutalism with pastel fills, ink outlines and hard shadows, a custom tab bar and a new icon.
- Snooze defaults to 9 minutes, like the iPhone Clock app.
- A dose that is due but not past its deadline shows as "Due now" instead of "Late".
- Taking one medication no longer stops another medication's ringing or snoozed alarm.
- Snapshots are version 2 with one entry per medication. The server still accepts version 1 from older apps.
- Bot texts are English only, with HTML formatting. `BOT_LANGUAGE` is gone.

## [0.1.7] - 2026-10-29

### Fixed
- A late dose taken more than 12 hours after its main time now shows on the day of the dose it was late for, in the week strip and the calendar.
- Changing the main time no longer unlinks earlier make-ups, so a made-up miss does not come back as "not made up".

### Changed
- The release workflow refuses a tag that is not the tip of `main`, misses commits from `develop` or has no changelog section.

## [0.1.6] - 2026-10-29

### Fixed
- 0.1.4 and 0.1.5 were built from an outdated commit and did not contain their fixes. This release ships both: the level History stats and the "no data" days in the week strip.

## [0.1.5] - 2026-10-29

### Fixed
- The week strip no longer shows past days as late on a fresh install. Days before the first dose show "No data"; only an overdue dose shows as late.

## [0.1.4] - 2026-10-29

### Fixed
- History stats stay level: the first label is shorter ("taken") and numbers align at the top when a label wraps.

## [0.1.3] - 2026-10-29

### Added
- "Back to the main time" on the Today screen after an early dose pulled the schedule earlier, with a warning when the next dose would exceed 24 hours.
- The bot speaks English with `BOT_LANGUAGE=en`.
- A randomized test that runs 12,000 user actions against the scheduling invariants.

### Fixed
- Changing the pill time in Settings now takes effect. Moving it earlier applies from the next day; moving it later asks for confirmation because the gap exceeds 24 hours. Before, the 24-hour rule kept reminding at the old time.
- Layouts no longer overflow at the largest accessibility text sizes; the first-launch screens scroll when needed.
- Long names wrap cleanly and are capped at 40 characters.
- An overdue dose from yesterday shows as late in the week strip instead of upcoming, and its time says "yesterday".

### Changed
- Code comments, the specification and the server docs are in English.

## [0.1.2] - 2026-10-29

### Added
- First launch asks for your name and, optionally, a partner's name and connection code. Both can be edited in Settings.
- The sync snapshot carries an optional `name`, so the bot addresses the right person.
- Bilingual README, contributing guide, security policy, issue and pull request templates.

### Changed
- No hardcoded names in the app. Without a partner name, texts say "your partner".
- Disabled buttons now look disabled, and non-editable History rows are no longer greyed out.

## [0.1.1] - 2026-10-29

### Added
- Vietnamese and English, chosen on first launch and changeable in Settings.
- Make-up doses: mark a missed pill as made up from the Today screen. Alerts mention outstanding missed pills.

### Removed
- The signature expiry warning. SideStore handles refreshing.

## [0.1.0] - 2026-10-29

### Added
- Reminders on Vietnam time with AlarmKit alarms that ring on silent and in Focus, or notifications that follow the phone's mode.
- A reminder chain up to the 24-hour deadline, which keeps ringing for 12 hours after it. Late and missed doses are tracked.
- Undo, editing the taken time, pausing reminders, pill counting and a refill reminder.
- History calendar, a lock screen countdown while snoozed, and light and dark mode.
- Optional sync to a self-hosted service with a private Telegram bot.
- Release builds and a SideStore source published from GitHub Actions.

[Unreleased]: https://github.com/finnwasabi/pillot/compare/v0.5.6...HEAD
[0.5.6]: https://github.com/finnwasabi/pillot/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/finnwasabi/pillot/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/finnwasabi/pillot/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/finnwasabi/pillot/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/finnwasabi/pillot/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/finnwasabi/pillot/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/finnwasabi/pillot/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/finnwasabi/pillot/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/finnwasabi/pillot/compare/v0.3.6...v0.4.0
[0.3.6]: https://github.com/finnwasabi/pillot/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/finnwasabi/pillot/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/finnwasabi/pillot/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/finnwasabi/pillot/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/finnwasabi/pillot/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/finnwasabi/pillot/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/finnwasabi/pillot/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/finnwasabi/pillot/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/finnwasabi/pillot/compare/v0.1.7...v0.2.0
[0.1.7]: https://github.com/finnwasabi/pillot/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/finnwasabi/pillot/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/finnwasabi/pillot/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/finnwasabi/pillot/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/finnwasabi/pillot/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/finnwasabi/pillot/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/finnwasabi/pillot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/finnwasabi/pillot/releases/tag/v0.1.0
