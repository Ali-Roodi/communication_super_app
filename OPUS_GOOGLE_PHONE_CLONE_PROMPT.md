# Opus Prompt — Google Phone UI/UX Full Clone

> Paste this directly into Claude Opus.

---

```
You are a senior software engineer and a senior Flutter/Android mobile developer with deep expertise in Material Design 3 and pixel-perfect UI replication.

Your task: make this Flutter app visually and functionally identical to the Google Phone app (Pixel dialer) — every screen, every setting, every interaction, every animation.

---

## STEP 1 — Read everything first

Read these files before writing a single line of code:
- CLAUDE.md
- PROJECT_ARCHITECTURE.md
- MVP_IMPLEMENTATION_PLAN.md

Then scan the full project tree. Do not proceed until you have a complete picture of the existing codebase.

---

## STEP 2 — Google Phone reference: every screen you must replicate

Below is the complete screen inventory of Google Phone. For each screen, I describe the exact layout, components, and behavior. Your job is to implement all of them in Flutter with RTL support and Persian labels.

---

### A. MAIN TABS (Bottom Navigation)

Google Phone has 3 bottom tabs:
- Favorites (ستاره‌ها)
- Recents (اخیر)
- Contacts (مخاطبین)

Plus a persistent search icon (top right) and a 3-dot overflow menu (top right).

The dialer is NOT a tab — it opens via a FAB (floating action button) at the bottom right of the Recents and Favorites tabs.

Implement this exact structure. Replace the current 4-tab layout.

---

### B. RECENTS SCREEN (اخیر)

Layout:
- AppBar: title "Phone" (فارسی: «تلفن»), search icon, overflow menu icon
- Body: grouped list of recent calls
- Each call log item:
  - Left: contact avatar (circle, first letter, colored) OR caller ID photo
  - Center-top: contact name (bold) or phone number
  - Center-bottom: row of [ call type icon (incoming/outgoing/missed arrow) + call type label + " · " + relative time (e.g. "دیروز", "۳ دقیقه پیش") ]
  - Right: info icon (ⓘ) that opens the call detail bottom sheet
- Missed calls: name shown in RED
- Grouping: calls to/from the same number within the same day are collapsed into one row showing "(3x)" count
- Long press on item: bottom sheet with options (Copy number, Block, Delete)

FAB:
- Position: bottom right
- Icon: dialpad icon
- Color: Google Green (#34A853)
- Opens the dialer screen as a bottom sheet (not a new route)

---

### C. DIALER (bottom sheet, opens from FAB)

Layout (bottom sheet, draggable, starts at half height):
- Top: number display field
  - RTL text, large font (36sp), centered
  - Backspace button (right side of field) — appears only when digits are present
  - Long press backspace: clears entire field
- Below number field: contact name suggestion (if number matches a contact)
- Keypad grid (3×4):
  ```
  1        2 ABC    3 DEF
  4 GHI    5 JKL    6 MNO
  7 PQRS   8 TUV    9 WXYZ
  *        0 +      #
  ```
  - Each key: large digit, small letter label below
  - Key shape: circle, 56dp diameter
  - Key background: surface variant color (changes in dark mode)
  - Press animation: scale down to 0.88 + ripple
  - Long press "0": inserts "+"
  - Long press "1": calls voicemail (show snackbar for now)
- Below keypad: three items in a row:
  - Left: "Add to contacts" icon button (person+ icon) — only visible when digits present
  - Center: Call FAB (72dp, green circle, phone icon)
  - Right: Video call icon button (for future use, show "not supported" snackbar)
- If no digits: only the call FAB is centered and grayed out

---

### D. CALL DETAIL BOTTOM SHEET

Opens when user taps the ⓘ icon on a recent call item.

Layout (modal bottom sheet):
- Drag handle at top
- Contact avatar (80dp circle)
- Contact name or number (large)
- Phone number (medium, gray)
- Row of action chips: [Call] [Message] [Add contact / View contact]
- Divider
- List of all individual calls with this contact (in this session):
  - Each row: type icon + label + date + duration
- Bottom: [Block number] in red text

---

### E. FAVORITES SCREEN (ستاره‌ها)

Layout:
- AppBar: title "Favorites" (فارسی: «موردعلاقه‌ها»)
- If empty: illustration + "Your favorite contacts will appear here" + "Add a favorite" button
- If populated: grid of contact cards (2 columns)
  - Each card: avatar (large circle) + name below + call button overlay
  - Tap card: calls immediately
  - Long press: remove from favorites option

---

### F. CONTACTS SCREEN (مخاطبین)

Layout:
- AppBar with search bar (inline, not separate screen)
- Sort/filter options: All contacts / Phone contacts
- Alphabetical section headers (sticky) — A, B, C... / ا, ب, پ... for Persian names
- Fast scroll index bar on the right edge (alphabet letters, tap to jump)
- Each contact row:
  - Avatar (circle, colored, first letter)
  - Name (bold)
  - Phone label (mobile, home, work — in gray below name)
- FAB: + icon (add new contact)

---

### G. ADD / EDIT CONTACT SCREEN

This is a full-screen modal (not bottom sheet).

Layout:
- AppBar: "Cancel" (لغو) left, "Save" (ذخیره) right (text buttons, not icons)
- Top section (gray background):
  - Large avatar circle (120dp) with camera icon overlay
  - Tap avatar: photo picker (camera / gallery)
- Form fields (each with a leading icon):
  - 👤 First name field + Last name field (two separate fields)
  - 📞 Phone number field + dropdown label (Mobile / Home / Work / Other) + [ + ] to add more numbers
  - 📧 Email field + dropdown label + [ + ] to add more
  - 🏠 Address field (multiline)
  - 🏢 Company field
  - 📝 Notes field
- "More fields" expandable section:
  - Nickname
  - Website
  - Birthday (date picker)
  - Relationship
- Bottom: "Delete contact" button (red, only on edit mode)
- All fields: underline style (not outlined), no border box
- RTL layout: icons on the right side, text on the left (or reverse for Persian)

---

### H. CONTACT DETAIL SCREEN

Layout:
- Collapsing toolbar with contact avatar (large, fills top)
- Name overlaid on bottom of avatar area
- Below toolbar:
  - Row of action buttons: [Call] [Message] [Video] [More]
  - Each action: icon + label below, in a card chip style
- Sections:
  - PHONE: each number with label + call icon + message icon
  - EMAIL: each email with label + compose icon
  - ADDRESS: with map preview thumbnail
  - NOTES
  - GROUPS / LABELS
- Bottom: [Edit] FAB (pencil icon)
- Starred toggle in AppBar (star icon)

---

### I. IN-CALL SCREEN

Layout (full screen, dark background #1C1B1F):
- Top section:
  - SIM/carrier name (small, gray)
  - Contact name (large, white, 30sp)
  - Call duration timer (white, counting up MM:SS)
  - "On hold" label when on hold (pulsing)
- Middle: contact avatar (if available) or animated waveform
- Control grid (3×2):
  ```
  [ Mute ]    [ Keypad ]   [ Speaker ]
  [ Add call] [ Hold   ]   [ End     ]
  ```
  - Mute: mic icon, toggles to mic-off + blue tint when active
  - Keypad: opens DTMF keypad overlay
  - Speaker: speaker icon, toggles + blue tint when active, long press shows audio output picker (earpiece / speaker / bluetooth)
  - Add call: opens dialer to add a second call
  - Hold: pause icon, toggles
  - End call: red circle (72dp), phone-end icon

---

### J. INCOMING CALL SCREEN

Two variants:

**Locked screen style (full screen):**
- Dark gradient background
- Contact avatar (center, 100dp circle)
- "Incoming call" label (small, gray)
- Contact name (large, white)
- Phone number or label (medium, gray)
- Bottom: two large buttons side by side
  - Left: Decline (red circle, phone-end icon) + "Decline" label
  - Right: Answer (green circle, phone icon) + "Answer" label
- Swipe up on Answer button: slide to answer animation
- Additional options row (above main buttons): Remind me / Reply with message

**Reply with SMS options (expandable):**
- "Can't talk right now"
- "I'll call you back"
- "I'm on my way"
- Custom message

---

### K. SEARCH SCREEN

Opens from the search icon in AppBar (shared across all tabs).

Layout:
- Full-width search bar at top (auto-focused)
- Below: live results as user types
  - Contacts matching name or number
  - Recent calls matching
  - Each result: avatar + name + number + call icon
- Empty state: "No results for [query]"
- Tap result: opens contact detail or calls directly (based on result type)

---

### L. SETTINGS SCREEN

Opens from overflow menu (3 dots) → Settings.

Sections (match Google Phone settings exactly):

**Display options:**
- [ ] Show dialpad on start — toggle
- Sort by: First name / Last name — radio
- Name format: First name first / Last name first — radio
- Theme: Light / Dark / System default — radio group

**Sounds and vibration:**
- Phone ringtone — taps to ringtone picker
- Also vibrate for calls — toggle
- Keypad tones — toggle
- Dialpad tones — toggle

**Quick responses (Reply with SMS):**
- Editable list of 4 default SMS replies for incoming calls
- Tap each to edit

**Accessibility:**
- TTY mode: Off / Full / HCO / VCO
- Hearing aids — toggle
- Noise reduction — toggle

**Caller ID & spam:**
- See caller & spam ID — toggle
- Filter spam calls — toggle (requires caller ID enabled)

**Blocked numbers:**
- List of blocked numbers
- Add a number: text field + block button
- Each blocked number: number + unblock button

**About:**
- App version
- Open source licenses

Each settings item uses standard ListTile with trailing widget (Switch, Radio, or chevron).
Group headers use a colored text style (primary color, 13sp, semibold).

---

### M. BLOCKED NUMBERS SCREEN

Full sub-screen (not inline in settings).

Layout:
- AppBar: "Blocked numbers" (فارسی: «شماره‌های مسدود»)
- Info banner: "Calls and texts from blocked numbers will be declined"
- Add number section: text field + "Block" button
- Blocked list: phone number + "Unblock" button per row
- Empty state: "No blocked numbers"

---

## STEP 3 — Implementation rules

### Architecture (non-negotiable — from CLAUDE.md):
- All state via BLoC — no BlocProvider inside screens
- No direct DB access from screens — always through Repository → BLoC
- All new screens: Directionality(textDirection: TextDirection.rtl)
- thread_id: always PhoneNumberUtils.normalize(phone)
- Batch inserts: always ConflictAlgorithm.ignore
- DB schema changes: always bump AppConstants.databaseVersion + migration

### Material Design 3 (match Google Phone):
- Use NavigationBar (Material 3) not BottomNavigationBar
- Use FilledButton, OutlinedButton — not ElevatedButton
- Cards: no elevation, use surfaceVariant color
- AppBar: no shadow, scrolledUnderElevation: 1
- All transitions: use predictive back gesture support
- Ripple on every tappable element
- All icons: Material Symbols (outlined by default, filled when active)

### Colors (exact Google Phone values):
- Call answer green:   #34A853
- Call decline red:    #EA4335
- Missed call red:     #EA4335
- Primary blue:        #1A73E8  (light) / #8AB4F8 (dark)
- Background light:    #FFFFFF
- Background dark:     #1C1B1F
- Surface variant:     #E7E0EC (light) / #49454F (dark)
- On surface dim:      #49454E (light) / #CAC4D0 (dark)

### Typography (match Google Phone):
- Contact name in recents:  16sp, weight 500
- Phone number / subtext:   14sp, weight 400, onSurfaceVariant color
- Section headers:          13sp, weight 600, primary color
- Dialer digits:            36sp, weight 300
- Dialer sub-letters:       10sp, weight 400, letterSpacing 1.5
- In-call name:             30sp, weight 300, white

### Animations:
- Dialer key press:         scale 1.0 → 0.88, 80ms ease-out
- FAB open dialer:          bottom sheet slide-up, 300ms, easeInOut curve
- Incoming call buttons:    pulse animation on green answer button
- Tab switch:               fade transition, 150ms
- Collapsing toolbar:       contact detail header parallax scroll

---

## STEP 4 — New BLoCs and features to add

Add these new BLoCs (follow existing patterns in AppBlocProviders):

1. **FavoritesBloc** — manages starred contacts
   - Events: LoadFavorites, AddFavorite, RemoveFavorite
   - State: FavoritesLoaded(contacts), FavoritesLoading, FavoritesError
   - Repository: add `is_favorite` column to contacts table (migration!)

2. **SearchBloc** — unified search across contacts + call logs
   - Events: SearchQueryChanged(query), ClearSearch
   - State: SearchIdle, SearchResults(contacts, callLogs)

3. **BlockedNumbersBloc** — manage blocked numbers
   - Events: LoadBlocked, BlockNumber(phone), UnblockNumber(phone)
   - State: BlockedLoaded(numbers)
   - Storage: new `blocked_numbers` table (migration!)

4. **SettingsBloc** (expand existing or create new):
   - Events: ToggleTheme, SetSortOrder, SetNameFormat, ToggleKeypadTones, ToggleSpamFilter, UpdateQuickReply(index, text)
   - State: SettingsState with all settings fields
   - Storage: SharedPreferences

---

## STEP 5 — Execution plan

Do NOT implement everything at once. Work in this order and stop after each to confirm:

1. Restructure navigation (3 tabs + FAB dialer)
2. Recents screen (full layout, grouping, long press)
3. Dialer as bottom sheet (full keypad, animations)
4. Call detail bottom sheet
5. Favorites screen
6. Contacts screen (search bar, sticky headers, fast scroll)
7. Add/Edit contact screen (full form, all fields)
8. Contact detail screen (collapsing toolbar, action buttons)
9. In-call screen (full controls grid)
10. Incoming call screen (both variants + reply with SMS)
11. Search screen (unified)
12. Settings screen (all sections)
13. Blocked numbers screen
14. New BLoCs (Favorites, Search, BlockedNumbers, expanded Settings)
15. Animations and polish pass

After each item: run `flutter analyze`, fix all warnings, then report done.

Start with item 1 now.
```
