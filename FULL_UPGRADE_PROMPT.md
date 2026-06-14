# Full Upgrade Prompt — Beyond MVP

> Read CLAUDE.md, PROJECT_ARCHITECTURE.md, and MVP_IMPLEMENTATION_PLAN.md first, then execute this.

---

```
You are a senior Flutter engineer and senior Android/Kotlin mobile developer.

Read these files before doing anything:
- CLAUDE.md
- PROJECT_ARCHITECTURE.md
- MVP_IMPLEMENTATION_PLAN.md

Then implement everything below. Work section by section, run `flutter analyze` after each, fix all issues before moving on.

---

## SECTION 1 — Dialer Bottom Sheet: Full Redesign

Redesign the dialer modal to exactly match the style in the reference screenshot provided:

### Key shape:
- Rounded rectangle (not circle) — borderRadius: 16
- Size: width fills ~28% of screen, height: 64dp
- Background: white in light mode (#FFFFFF), dark gray (#2D2E31) in dark mode
- No border, no shadow on individual keys
- Subtle box shadow on the entire keypad container

### Key content:
- Main digit: English numerals (1-9, *, 0, #) — fontSize: 28sp, fontWeight: w400
- Sub-label (ABC, DEF, etc.): below digit — fontSize: 10sp, letterSpacing: 2.0, color: gray
- Special: "1" shows voicemail icon (small, below 1) instead of letters
- "0" shows "+" below it

### Key press animation:
- Background darkens slightly on press (use InkWell with custom splash color)
- Scale: 0.94 on press, spring back on release
- Haptic: HapticFeedback.lightImpact() on every key press

### Number display field:
- Large centered text, English digits, fontSize: 40sp, fontWeight: w300
- Caret blinking at end
- If number > 11 digits: fontSize shrinks to 28sp
- Backspace icon button — right of field — only visible when digits exist
- Long press backspace: clears entire field with single vibration

### Call button:
- Pill shape (not circle): borderRadius: 32, width: 160dp, height: 56dp
- Background: #34A853 (green)
- Icon: phone icon (white, 24dp) + "Call" text (white, 16sp, w500) side by side
- Disabled state (no digits): opacity 0.45, no onTap
- Enabled state: slight elevation (4dp) + green glow shadow

### Layout of bottom area (below keypad):
```
[Add to contacts icon]   [Call button pill]   [Delete/backspace icon]
```
- Add to contacts: only visible when digits.length > 0
- All three items vertically centered in a row

### Bottom sheet behavior:
- Opens from FAB with slide-up animation (300ms, easeInOut)
- Draggable — user can drag down to dismiss
- Initial snap: 60% of screen height
- Full snap: 90% of screen height (shows keypad + number field fully)
- Drag handle at top center (gray pill, 4×32dp)
- Background behind sheet: contact/recents list stays visible and slightly dimmed

---

## SECTION 2 — Messages Tab: Full Google Messages Style

Completely replace the current messages UI with Google Messages design:

### Conversations List Screen:

AppBar:
- Title: "Messages" (پیام‌ها)
- Right actions: search icon, overflow menu (3 dots)
- Overflow menu items: Archive, Spam & blocked, Scheduled, Manage devices, Settings

Search (inline, expands on tap):
- Full-width search bar replaces AppBar title
- Live filter on name, number, message content
- Shows results in same list format

Conversation thread tile:
- Avatar: circle 48dp — contact photo OR first letter with colored background
  - Unread: avatar has colored ring border (primary color, 2dp)
- Title row: contact name/number (left, bold if unread) + timestamp (right, primary color if unread)
- Preview row: message preview (truncated 1 line) + unread count badge (right, if unread)
- Unread thread: entire tile has slightly elevated surface color (surfaceVariant)
- Read thread: normal background
- Swipe left: archive action (with undo snackbar)
- Swipe right: mark as read/unread action
- Long press: enters multi-select mode (see below)

Multi-select mode:
- AppBar transforms: shows count of selected + X to cancel + action icons (delete, archive, mark read, block)
- Checkboxes appear on left of each tile
- FAB disappears
- Tap tile to toggle selection
- "Select all" option in AppBar overflow

FAB:
- Bottom right, pencil/compose icon
- Opens new conversation screen (contact picker + number input)

### Conversation (Chat) Screen:

AppBar:
- Back arrow (left)
- Contact avatar (small circle, 32dp) + contact name — tappable (opens contact detail)
- Right actions: video call icon, phone call icon, overflow menu
- Overflow: View contact, Add to contacts (if not saved), Block & report spam, Delete conversation

Message bubbles:
- Sent (right side):
  - Bubble color: primary color (#1A73E8 light / #8AB4F8 dark)
  - Text: white
  - Border radius: 20dp, bottom-right corner: 4dp (tail effect)
  - Timestamp: below bubble, right-aligned, gray, 11sp — only shown on last message in group or after 10min gap
- Received (left side):
  - Bubble color: surfaceVariant (#E7E0EC light / #49454F dark)
  - Text: onSurface color
  - Border radius: 20dp, bottom-left corner: 4dp
  - Timestamp: same rules as sent

Message grouping:
- Messages from same sender within 2 minutes: grouped together, no timestamp between them
- First message of group: full bubble with tail
- Middle messages: straight bottom corner (no tail)
- Last message of group: tail + timestamp shown
- Date separator: centered chip ("Today", "Yesterday", "Mon Dec 4") between day groups

Long press on message:
- Bottom action sheet appears with:
  - Copy
  - Forward (placeholder for now)
  - Delete (with confirmation dialog)
  - Info (timestamp + delivery status)
  - Select (enters message multi-select mode)

Message multi-select:
- Checkboxes appear on messages
- AppBar shows count + delete action

Delivery status (sent messages):
- Single check: sent
- Double check: delivered
- Double check (filled/blue): read (for future RCS, show "Sent" for now)
- Error icon: failed — tap to retry

Input composer area:
- Rounded input field (borderRadius: 24)
- Placeholder: "Message" (پیام)
- Left icon: attachment (+ icon, opens bottom sheet: camera, gallery, audio, location)
- Right icon: send button (filled circle, primary color) — only active when text is not empty
- When empty: right icon is mic (voice message placeholder — show snackbar "coming soon")
- Emoji button: left of text field
- Field expands up to 4 lines, then scrolls internally

New Conversation Screen:
- AppBar: "New conversation" (مکالمه جدید)
- "To:" field at top with contact chip autocomplete
  - Type name: shows matching contacts in dropdown
  - Type number: shows "Send to [number]" option
  - Selected contacts appear as chips in the To field
- Below To field: same composer area

---

## SECTION 3 — Bug Fixes (all 6 must be fixed)

### BUG 1: Rejected calls not saved in call log
In CallConnectionService.kt, onReject() must save to call log before disconnecting:

```kotlin
override fun onReject() {
    // Save missed/rejected call to DB BEFORE disconnecting
    val phone = address?.schemeSpecificPart ?: ""
    val timestamp = System.currentTimeMillis()
    CallLogHelper.saveCallLog(
        context = appContext,
        phone = phone,
        type = "rejected",  // new type — show as "رد شده" in UI with orange color
        duration = 0,
        timestamp = timestamp
    )
    setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
    destroy()
    instance = null
    CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
}
```

Add "rejected" as a new call type. In CallLogTile, show it with orange color (#FF6D00) and label "رد شده".

### BUG 2: Delay after tapping end call button
The delay is caused by waiting for the Kotlin side to respond before updating UI.
Fix: emit CallStatus.idle on the Flutter/BLoC side IMMEDIATELY when EndCall event fires, then call native endCall() asynchronously:

```dart
// In DialerBloc:
Future<void> _onEndCall(EndCall e, Emitter<DialerState> emit) async {
  emit(const DialerState()); // immediate UI reset — no waiting
  unawaited(_callService.endCall()); // fire and forget
}
```

Also add `import 'dart:async' show unawaited;`

### BUG 3: Cannot send SMS to unsaved numbers
In the Recents/call history screen, tapping the message icon on an unsaved number must:
1. Navigate directly to the conversation screen with that phone number pre-filled
2. The conversation screen must accept a `phoneNumber` parameter and work without a saved contact

Fix in ConversationScreen:
```dart
class ConversationScreen extends StatelessWidget {
  final String? contactName;  // nullable — unsaved number shows the number itself
  final String phoneNumber;   // always required
  
  // If contactName is null, use phoneNumber as the display title
}
```

Fix in ThreadsScreen: the "new message" FAB and any message action from recents must pass just the phone number if contact is not found.

### BUG 4: No bulk select/delete for conversation threads
Already covered in Section 2 (multi-select mode). Implement it there.
Additional requirement: add "Delete conversation" to the single thread long-press bottom sheet.
Confirmation dialog required: "Delete this conversation? This cannot be undone."

### BUG 5: No message select/delete inside conversation
Already covered in Section 2 (long press on message → multi-select). Implement it.
For single delete: show dialog "Delete message?" with Cancel / Delete buttons.
Deleting from UI must also delete from SQLite (MessageRepository.deleteMessage(id)).

### BUG 6: Cannot add unknown number to contacts from call log
In CallLogTile, for calls with no contactName (unsaved number):
- Show "Add to contacts" option in the call detail bottom sheet
- Tapping it: navigates to AddContactScreen with phone field pre-filled with that number
- After saving: refresh CallHistoryBloc so the name appears in the log

Also add this flow from:
- Conversation screen AppBar overflow: "Add to contacts" (when contactName is null)
- Incoming call screen: "Add to contacts" option after call ends

---

## SECTION 4 — Complete Feature Audit: Add All Missing Features

Search for and implement every standard feature a phone + SMS app should have:

### CALL FEATURES:

**Call log:**
- [ ] Filter tabs in recents: All / Missed (tap to filter)
- [ ] Group repeated calls (same number, same day) with "(3×)" count
- [ ] Delete individual call log entry (swipe or long press → delete)
- [ ] Clear all call history (Settings → Clear call history, with confirmation)
- [ ] Call back from notification (missed call notification with callback action)

**In-call:**
- [ ] DTMF keypad overlay (tap "Keypad" button in InCallScreen → shows numpad overlay)
- [ ] Bluetooth audio routing (show in speaker picker: Earpiece / Speaker / Bluetooth)
- [ ] Call duration saved to DB when call ends (calculate from ACTIVE event to DISCONNECTED)
- [ ] Conference call UI placeholder (Add call button — show "coming soon" for now)

**Missed call notification:**
- [ ] Persistent notification for missed calls
- [ ] Actions on notification: Call back / Message
- [ ] Notification dismisses when user opens the app

**Voicemail:**
- [ ] Long press "1" on keypad → show "Calling voicemail..." snackbar (no actual implementation needed)

### SMS FEATURES:

**Conversation:**
- [ ] Character counter (appears when message > 140 chars: "145 / 1 SMS")
- [ ] MMS indicator (when message > 160 chars or has attachment: "MMS")
- [ ] Delivery report toggle (in conversation overflow menu)
- [ ] Message search within conversation (search icon in conversation AppBar)
- [ ] Scroll to bottom FAB (appears when user scrolls up far enough)
- [ ] Copy phone number from received message (tap on number in bubble → chip appears)

**Thread management:**
- [ ] Archive thread (swipe left or long press → archive)
- [ ] Unarchive (from archived view)
- [ ] Archived conversations screen (accessible from main overflow menu)
- [ ] Mark thread as read / unread
- [ ] Pin conversation to top (long press → pin, pinned threads show at top with pin icon)
- [ ] Spam / block from thread (overflow menu → Block & report spam)

**Notifications:**
- [ ] SMS notification with sender name/number
- [ ] Quick reply from notification (inline reply action)
- [ ] Mark as read from notification
- [ ] Notification channels: one per conversation (for per-conversation notification settings)

### CONTACTS FEATURES:

**Import / sync:**
- [ ] Import from device contacts button (Settings → Import contacts)
- [ ] Sync indicator showing last sync time
- [ ] Merge duplicate contacts (basic: same name → suggest merge)

**Contact detail:**
- [ ] Copy phone number on long press
- [ ] Share contact (vCard export)
- [ ] Add to home screen shortcut (show snackbar "Added to home screen")
- [ ] Assign ringtone to contact (opens ringtone picker, stored in DB)
- [ ] Contact notes field (already in DB, must show in detail screen)

**Favorites:**
- [ ] Star/unstar from contact detail AppBar
- [ ] Favorites appear at top of contacts list (before alphabetical)
- [ ] Favorites grid in the Favorites tab

### SETTINGS FEATURES:

Add these settings (stored in SharedPreferences via SettingsBloc):

**Display:**
- Sort contacts by: First name / Last name
- Display name format: First Last / Last First
- Show dialpad on app start: toggle (if on, open dialer sheet immediately)

**Calls:**
- Vibrate on answer/end: toggle
- Flip to silence: toggle (placeholder, show "coming soon")
- Pocket mode: toggle (placeholder)
- Default country code: picker

**Messages:**
- Delivery reports: toggle
- Auto-download MMS: toggle (placeholder)
- Group messaging: MMS / individual SMS / off
- Blocked numbers: link to blocked numbers screen

**Notifications:**
- Incoming calls: toggle + ringtone picker
- New messages: toggle + notification sound picker
- Vibrate: toggle

**Privacy & security:**
- App lock: link to auth setup (PIN / Pattern)
- Lock timing: immediately / 30s / 1min / 5min / never
- Incognito keyboard: toggle (tell system keyboard not to learn from input)

**About:**
- App version
- Open source licenses
- Send feedback (opens email composer)

### APP-WIDE FEATURES:

**Search (unified, from any tab):**
- Searches: contacts, call log, conversations simultaneously
- Results grouped by section: Contacts / Calls / Messages
- Tap contact result: open contact detail
- Tap call result: call that number
- Tap message result: open conversation (scroll to matching message)

**Blocked numbers:**
- Block from: call log, contact detail, conversation, incoming call
- Blocked calls: silenced + saved in log as "Blocked"
- Blocked SMS: silenced + moved to spam folder
- Unblock from: blocked numbers screen in settings

**Deep links:**
- Handle tel: URIs (other apps can open dialer with pre-filled number)
- Handle sms: URIs (other apps can open new SMS with pre-filled number)
- Declare in AndroidManifest.xml intent filters

**Widget (home screen):**
- Simple 1x1 widget: tap to open dialer
- Simple 4x1 widget: recent calls list (placeholder — show "coming soon" for now)

---

## SECTION 5 — Database Migrations Required

All schema changes need a version bump and migration in DatabaseHelper._onUpgrade:

```
Current version: 3

Version 4:
- contacts: ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0
- contacts: ADD COLUMN ringtone_uri TEXT
- call_logs: ALTER COLUMN type to support new value 'rejected' and 'blocked'
- CREATE TABLE blocked_numbers (id INTEGER PRIMARY KEY AUTOINCREMENT, phone TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL)
- CREATE TABLE archived_threads (thread_id TEXT PRIMARY KEY, archived_at INTEGER NOT NULL)
- CREATE TABLE pinned_threads (thread_id TEXT PRIMARY KEY, pinned_at INTEGER NOT NULL)
- messages: ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0  (soft delete)
- messages: ADD COLUMN delivery_status TEXT DEFAULT 'sent'  ('sent'|'delivered'|'read'|'failed')
```

Update AppConstants.databaseVersion to 4.
Add all migration SQL in the `case 3:` block of _onUpgrade.

---

## EXECUTION ORDER

Do these one at a time. Stop and run `flutter analyze` after each. Report result before proceeding.

1. Database migrations (Section 5) — foundation for everything else
2. Bug Fix 1: rejected calls in log (Section 3, BUG 1)
3. Bug Fix 2: end call delay (Section 3, BUG 2)
4. Bug Fix 3: SMS to unsaved numbers (Section 3, BUG 3)
5. Bug Fix 6: add to contacts from call log (Section 3, BUG 6)
6. Dialer bottom sheet redesign (Section 1)
7. Messages tab full redesign — list screen (Section 2)
8. Messages tab — conversation screen (Section 2)
9. Bug Fix 4+5: multi-select threads + messages (Section 3, BUG 4+5)
10. Call features (Section 4, CALL FEATURES)
11. SMS features (Section 4, SMS FEATURES)
12. Contacts features (Section 4, CONTACTS FEATURES)
13. Settings — full expansion (Section 4, SETTINGS FEATURES)
14. App-wide features: search, blocked numbers, deep links (Section 4, APP-WIDE)
15. Final pass: flutter analyze + fix all warnings

Start with step 1 now.
```
