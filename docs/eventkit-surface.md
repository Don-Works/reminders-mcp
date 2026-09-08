# EventKit surface on this Mac (verified 2026-09-08)

Probed against `$(xcrun --show-sdk-path)/System/Library/Frameworks/EventKit.framework/Headers`
with the throwaway compile probes now in `salvage/eventkit-probes/`. Second pass
(2026-09-08, during `main.swift` implementation) verified the actual **Swift** names —
several differ from the ObjC header. The Swift names are what you must use.

## Missing from this SDK

- No `createCalendar` of any form on `EKEventStore`. A new reminder list can only be
  made through AppleScript: `tell application "Reminders" to make new list with properties {name:"…"}`.
- No `EKPredicate` type (predicates are plain `NSPredicate`).
- No sub-reminders.
- No `createReminder` factory on `EKEventStore` — use `EKReminder(eventStore: store)`
  then `reminder.calendar = cal`. A bare `EKReminder()` raises an uncatchable ObjC
  exception ("You must use [EKReminder reminderWithEventStore:] to create a reminder").

## Swift names (as compiled in `main.swift`)

| ObjC-ish name | Swift (this SDK) |
|---|---|
| `calendarsForEntityType:` | `calendars(for: .reminder)` |
| `defaultCalendarForNewReminders` (property) | `defaultCalendarForNewReminders()` (method, non-optional) |
| `fetchRemindersMatchingPredicate:completion:` | `fetchReminders(matching:completion:)` (single completion arg) |
| `predicateForRemindersInCalendars:` | `predicateForReminders(in:)` |
| `predicateForIncompleteRemindersWithDueDateStarting:ending:calendars:` | `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)` |
| `predicateForCompletedRemindersWithCompletionDateStarting:ending:calendars:` | `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)` |
| `calendarItemWithIdentifier:` | `calendarItem(withIdentifier:)` |
| `saveReminder:commit:error:` / `removeReminder:commit:error:` | `save(_:commit:)` / `remove(_:commit:)` — **throwing**, no error param |
| `requestFullAccessToRemindersWithCompletion:` | `requestFullAccessToReminders(completionHandler:)` |
| `NSCompoundPredicate.andPredicate(withSubpredicates:)` | `NSCompoundPredicate(andPredicateWithSubpredicates:)` |
| `EKRecurrenceRule(recurrenceEnd:frequency:interval:…)` | `EKRecurrenceRule(recurrenceWith:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:)` |
| `EKRecurrenceEnd(endDate:)` | `EKRecurrenceEnd(end:)`; `occurrenceCount` is non-optional Int, `end` is optional Date |
| `EKCalendar.subscribed` / `.immutable` | `isSubscribed` / `isImmutable` |
| `EKReminder.URL` / `.completed` | `url` / `isCompleted` |

`EKRecurrenceRule` day arrays are `[NSNumber]`-typed (convert from `[Int]`).
`EKRecurrenceDayOfWeek` has a plain init `EKRecurrenceDayOfWeek(_ weekday: EKWeekday)` —
no `dayOfWeek:` label; `dayOfTheWeek` remains the getter.
`EKReminder.title` is `String?` in Swift; `EKCalendar.title` is a non-optional `String`.
`EKReminder.alarms` is optional (`[EKAlarm]?`).

## Present

`EKReminder`: `calendar`, `calendarItemIdentifier`, `title`, `location`, `notes`, `URL`,
`creationDate`, `lastModifiedDate`, `timeZone`, `hasAlarms`, `hasRecurrenceRules`,
`alarms: [EKAlarm]`, `recurrenceRules: [EKRecurrenceRule]`, `startDateComponents`,
`dueDateComponents`, `completed`, `completionDate`, `priority`.

`EKEventStore`: `requestFullAccessToRemindersWithCompletion` (macOS 14+),
`calendarsForEntityType(.reminders)`, `defaultCalendarForNewReminders`,
`calendarWithIdentifier`, `saveCalendar:commit:error:`, `removeCalendar:commit:error:`,
`calendarItemWithIdentifier`, `saveReminder:commit:error:`, `removeReminder:commit:error:`,
`fetchRemindersMatchingPredicate:completion:`, `predicateForRemindersInCalendars`,
`predicateForIncompleteRemindersWithDueDateStarting:ending:calendars:`,
`predicateForCompletedRemindersWithCompletionDateStarting:ending:calendars:`.

`EKAlarm`: `alarmWithAbsoluteDate:`, `alarmWithRelativeOffset:`, `relativeOffset`,
`absoluteDate`, `type`, `emailAddress`, `soundName`.

`EKRecurrenceRule`: `initRecurrenceWithFrequency:interval:end:` plus the designated
initializer; `frequency`, `interval`, `recurrenceEnd`, `daysOfTheWeek`, `daysOfTheMonth`,
`monthsOfTheYear`, `weeksOfTheYear`, `daysOfTheYear`, `setPositions`, `firstDayOfTheWeek`.

`EKRecurrenceEnd`: `recurrenceEndWithEndDate:`, `recurrenceEndWithOccurrenceCount:`,
`endDate`, `occurrenceCount`.

`EKRecurrenceDayOfWeek`: `dayOfWeek:`, `dayOfWeek:weekNumber:`, `dayOfTheWeek`, `weekNumber`.

`EKCalendar`: `calendarIdentifier`, `title`, `type`, `allowsContentModifications`,
`subscribed`, `immutable`, `color` (NSColor, settable), `source`.

`EKWeekday`: 1 = Sunday … 7 = Saturday.
`EKRecurrenceFrequency` raw values: daily 1, weekly 2, monthly 3, yearly 4, workdays 5,
months 6, weeks 7, days 8.

## Implementation constraints found during the probe

- `fetchRemindersMatchingPredicate` is async-with-completion; block on a `DispatchSemaphore`
  with a timeout (10s) to keep the stdio loop synchronous.
- `dueDateComponents` is `NSDateComponents`; build it with `Calendar(identifier: .gregorian)`.
  Setting only year/month/day makes the reminder all-day.
- Sorting by due date must happen in Swift after the fetch — KVC cannot order `NSDateComponents`.
- `priority` accepts 0, 1, 5, 9 only; other values fail the save.
- Setting `completed = true` sets `completionDate` automatically; assigning `completionDate`
  implies completed.
- **Predicate gotcha (verified by crash):** `fetchReminders(matching:)` rejects any predicate
  not created by the store's own factory methods — it raises
  `"predicate is not a reminder predicate created through EKEventStore"`. Wrapping a factory
  predicate in `NSCompoundPredicate(andPredicateWithSubpredicates:)` with KVC clauses
  (`completed == false`, `title ==[cd] %@`, …) is therefore **not** a workable narrowing
  strategy.
- **Second predicate gotcha (verified by crash, deterministic):**
  `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)` kills the process
  (Trace/BPT trap) on this machine's store. Do not use it. The
  `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)` variant
  worked once but is equally suspect.
- The one reliable factory: `predicateForReminders(in:)` (nil = all lists). The pattern used
  in `main.swift`: fetch with that, then narrow in Swift (completed state, completion-date
  range, due-date range, has-due, exact/case-diacritic-insensitive title match, notes/location
  contains).
- MCP stdio framing is newline-delimited JSON, no `Content-Length` header.
