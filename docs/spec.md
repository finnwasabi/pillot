# Pillot specification

The reference for the reminder logic and the data contract between the app and the sync service.
`Packages/PillotCore` implements everything below and its tests pin it down.

## Fixed Vietnam time

- Every time is computed in `TimeZone(identifier: "Asia/Ho_Chi_Minh")` (UTC+7, no daylight saving), whatever the
  device time zone is. `TimeZone.current` is never used for scheduling.
- Times are stored and sent as absolute moments (`Date`, UTC ISO 8601 in JSON).
- Screens show Vietnam time, plus the local time when the device is in a different time zone.
- Alarms use `Alarm.Schedule.fixed(Date)` (AlarmKit) and notifications use `UNTimeIntervalNotificationTrigger` from an
  absolute moment. `Alarm.Schedule.relative` is never used because it follows the device time zone.
- The app schedules the next H days (14) ahead and refills on every launch, every "Taken", undo, settings change, and
  whenever the network comes back.

## Medications

- The user keeps a list of up to 20 **medications**. Each has a name (up to 40 characters, shown in every reminder), a
  color, an icon, its own schedule, pill count, pauses and history. Everything below applies to each medication on its own.
- A fresh install has no medications. Data from 0.1.x (a single schedule) becomes one medication named "Daily pill".
- Medications reminded at the same moment share one alert: one alarm rings, its title names them all ("Vitamin D,
  Iron"), and "Taken" covers the pending doses in that alert. Taking one medication leaves unrelated alarms active.
  If it silences a shared alarm, future reminders for the remaining medications stay scheduled.

## Schedule and maximum gap

- The user sets a **main time** in Vietnam time (for example 21:00) and **doses per day**: 1, 2, 3, 4 or 6, evenly
  spaced. The **period** is 24 hours divided by the doses per day; with 2 doses from 08:00 they fall at 08:00 and 20:00.
- The first dose is anchored when a medication is added. It stays pending when its scheduled time arrives.
- A course includes its last Vietnam calendar day. Its final dose can still ring until the course ends at midnight.
  If its late window would run past midnight, the pending dose resolves at the end of the course.
- **Maximum gap** between two consecutive doses: one period by default, adjustable from one period up to one and a half
  (24 to 36 hours for a daily medication).
- Next deadline = previous dose + maximum gap.
- A take counts for its nearest dose time; the next dose belongs to the first dose time more than half a period
  later. Next reminder = min(that dose time, the deadline). Taking a dose early pulls the next one earlier too. "Back to
  the main time" is available and warns when that dose would exceed the maximum gap. Changing the main time, the doses
  per day or the maximum gap warns the same way.
- Reminder chain for each dose, all cancelled by "Taken":
  1. The main reminder.
  2. 3 repeats, 5 minutes apart.
  3. Then hourly.
  4. In the last 2 hours before the deadline: every 15 minutes.
  5. At the deadline: a ringing alarm regardless of the phone's mode.
  6. Past the deadline and still not taken: still ringing. 3 repeats 5 minutes apart, then every 15 minutes for the
     first 3 hours, then hourly until the end of the late window (half a period after the deadline: 12 hours for a
     daily medication, 6 hours for one taken twice a day).
  Taking the pill at the main time every day puts the deadline on the next main time, so the part after the deadline
  is what keeps reminding until the pill is taken.
- Snooze follows the iPhone Clock app: 9 minutes by default, adjustable from 1 to 15 in Settings. It can be used as
  often as needed and never moves the deadline. Only "Taken" stops an alarm.
- "Taken" can be undone for 10 minutes. Taken times can be edited in History.
- "Pause reminders for N days": no reminders and no misses during the pause. Afterwards the next dose starts from the
  main time.
- Everything must hold across time zone changes, midnight, early doses, late doses and skipped days.
- Invariant: two consecutive ringing alarms are never further apart than the maximum gap, and after a dose there is
  always a ringing alarm at or before its deadline.

## Skipping, days off, backups

- **Skip this dose** resolves the pending dose without taking it: no miss, no pill, and its alarms stop. The next dose
  starts fresh at the next dose time after the skip, as if the skipped one had been taken on time, so skipping never
  makes the next reminder ring harder. A skip can be undone for 10 minutes on Today, or deleted later in History, which
  brings the dose back as not taken.
- **Days off in a cycle** (`DoseCycle`: days on, days off, first day on): a dose time that falls on a day off moves to
  the first dose time of the next day on, which starts fresh like after a pause. Nothing rings and nothing counts as
  missed meanwhile, and days off show as paused in History. A dose still due on the last day on keeps its late window.
- **Backup** is a JSON file (`format: "pillot-backup"`, `version: 1`; files saved as `"medly-backup"` still restore) with every medication and its history plus the
  app preferences. The connection code is left out. Restoring replaces everything on the phone after a confirmation.
  The app's own data file is accepted too.
- **Widget and Shortcut:** the data file lives in an App Group so the widget can read it (SideStore renames the group
  and lists the real name in `ALTAppGroups`). A widget or alert's "Taken" action applies to the dose it was created for.
  The "I took my meds" App Shortcut marks every medication due now. Both save and reschedule in the app's process.

## Statuses

| Status | Meaning | Color |
|---|---|---|
| Taken | Confirmed at or before the deadline, with a 15-minute tolerance so seconds or minutes do not count as late. | Green |
| Due | The dose time has come and the deadline has not. Shown on Today only. | Yellow |
| Late | Taken after the deadline plus tolerance, but within the late window. The next dose counts from it. | Yellow |
| Missed | No confirmation by the end of the late window. | Red |
| Made up | A missed dose for which an extra pill was taken later. | Blue |
| Skipped | Skipped on purpose. Not a miss. | Lavender |
| Paused | The dose fell inside a pause or on a day off. | Grey |

Statuses always come with a label and an icon, never color alone.

## Make-up doses

- The Today screen lists missed doses of every medication from the last 7 days with a "Mark made up" button.
- Marking one stores a make-up record linked to that miss. It subtracts a pill when counting and does not change the
  schedule. Each miss can be made up once.
- A mistaken make-up is deleted in History and the pill is given back.
- While misses are not made up, every alert of that medication carries the line "N missed doses not made up".
- The app never advises whether or how to make up a pill. It points to the leaflet, a doctor or a pharmacist.

## Pills

- Counting is optional. Without it the app only reminds.
- With it, every "Taken" and every make-up subtracts a pill. Each medication has a pack size (the first count entered,
  28 when unknown); "Add a pack" adds one pack. Raising the remaining count adds to both the remaining count and the
  total; lowering it is a correction and leaves the total alone. The editor applies the difference on Save, so a dose
  taken from an alarm while the editor is open is not undone.
- "Refill reminder": on or off, with a threshold (7 by default). At or below the threshold, every alert carries
  "N pills left, time to buy more".
- `takenCount` = doses taken since pills were last entered or added (since the start when not counting).

## Sync (offline first)

- All reminders and calculations run on the device. When online, the app sends the latest snapshot; offline, it waits.
- The service never infers anything. It reports the latest data it received, with its update time.

### Data contract

`POST /v1/snapshot` with `Authorization: Bearer <token>` and a JSON body. The server keeps only the snapshot with the
newest `updatedAt` and answers older ones with 200 and `"stale": true`. Every response carries the current
`message` (set by the bot's `/msg`).

```json
{
  "schemaVersion": 2,
  "name": "Mai",
  "updatedAt": "2026-10-27T14:03:00Z",
  "medications": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Daily pill",
      "dosesPerDay": 1,
      "lastTakenAt": "2026-10-27T14:03:00Z",
      "nextDueAt": "2026-10-28T14:00:00Z",
      "deadlineAt": "2026-10-28T14:03:00Z",
      "takenCount": 12,
      "missedCount": 1,
      "lateCount": 0,
      "madeUpCount": 0,
      "pillsTotal": 28,
      "pillsRemaining": 16,
      "refillReminder": { "enabled": true, "daysBefore": 7 },
      "pausedUntil": null
    }
  ]
}
```

- Times are UTC ISO 8601 without fractional seconds. `pillsTotal` and `pillsRemaining` are `null` when not counting.
  `lastTakenAt`, `pausedUntil` and `name` may be `null`. `name` is the user's name from the app, so the bot can use it.
- `missedCount` counts every miss, including made-up ones. `madeUpCount` counts the made-up ones.
- At most 30 medications per snapshot. `skippedCount` was added in 0.3.0 and may be missing. The server ignores `nextDueAt`
  and `deadlineAt` for `asNeeded` medications and when `courseEnded` is true. A course ends after its last day or when it
  runs out of scheduled doses. `pausedUntil` is then null. `asNeeded`, `courseEnded`, `pillsPerDose` and `takenToday`
  were added in 0.5.0 and may be missing. `pausedUntil` also covers days off in a cycle.
- Version 1 (0.1.x: the fields of one medication at the top level, with `daysTaken` instead of `takenCount` and no `id`,
  `name` or `dosesPerDay`) is still accepted and stored as version 2 with one medication.
- `GET /v1/snapshot` (same token) returns the latest snapshot as version 2, or 404 when there is none.

## Telegram bot

- A dedicated bot that answers a single configured chat ID only.
- Messages on real changes, per medication: taken, undo, a new late, missed or skipped dose, a make-up, a pause, low
  pills, a medication added or removed.
- A nudge when a medication is more than 15 minutes past the `deadlineAt` of the latest snapshot and that snapshot has no
  dose since `nextDueAt`, unless paused. Once per deadline, worded as "no dose has come in yet" since the phone may be
  offline. This compares the snapshot's own times; the server still decides nothing about the schedule.
- A 09:00 Vietnam time report every day with one block per medication: last dose, next dose, taken, late, missed, made
  up, pills left, and the last sync. Snapshots older than 24 hours are flagged as not synced since then.
- Status reports paginate when the medication list exceeds Telegram's message limit. Reports and deadline nudges retry
  on the next tick if sending fails.
- Commands: `/check` (latest status, with a Refresh button), `/msg <text>` (the note shown in the app; without text it
  shows the current note), `/clearmsg`, `/link` (the connection code, with a Copy button), `/help`, `/start`.
- Bot texts are English, sent as Telegram HTML with names escaped.
- All times are shown in Vietnam time. The bot token, API token and chat ID come from environment variables, never the repo.
