# Figma Sync + UI/UX Audit Prompt

> You have the Figma plugin connected in Claude Code. Read CLAUDE.md, PROJECT_ARCHITECTURE.md, and the existing prompts first, then execute this.

---

```
You are a senior Flutter engineer and senior mobile UI/UX designer.

The Figma plugin is connected. The project design file is:
https://www.figma.com/design/OwJb4OMJrdZ1r91b2JX5iO/Ghasem

GOAL: Sync the app with Figma while PRESERVING the current Google Phone app flow and structure that is already implemented. Do NOT restructure navigation or rewrite working features. Only bring the visual design in line with Figma and add any screens/features present in Figma but missing from the app.

---

## STEP 1 — Pull and map the Figma file

Using the Figma plugin:
1. List every frame/screen in the Figma file with its name
2. For each frame, extract: layout, components, colors, typography, spacing, icons, and any interactive states
3. Build a mapping table:

   | Figma Frame | App Screen (file path) | Status |
   |-------------|------------------------|--------|
   | ...         | ...                    | Exists / Missing / Partial |

4. Extract the Figma design tokens:
   - Color styles (light + dark) → map to AppColors
   - Text styles → map to AppTheme TextTheme
   - Spacing/corner-radius/elevation values → note them
   - Component variants (buttons, chips, list items, etc.)

Report this mapping table and token list before changing any code.

---

## STEP 2 — Sync existing screens to Figma

For every screen that already exists in the app AND has a Figma frame:
- Compare the current implementation against the Figma frame
- Update colors, spacing, typography, corner radius, icon choices, and component styling to match Figma exactly
- Do NOT change the screen's logic, BLoC wiring, or navigation flow — visual layer only
- Keep all existing functionality intact

Preserve these non-negotiable rules from CLAUDE.md:
- No BlocProvider inside screens
- Directionality(textDirection: TextDirection.rtl) on every screen
- thread_id via PhoneNumberUtils.normalize()
- Batch inserts with ConflictAlgorithm.ignore
- Schema changes require databaseVersion bump + migration

---

## STEP 3 — Build missing screens and features from Figma

For every Figma frame that has NO matching app screen:
- Build it as a new Flutter screen following the existing feature folder pattern
  (bloc / models / repositories / screens / services)
- Wire it into the existing navigation flow at the logically correct entry point
  (do not invent new top-level tabs unless Figma explicitly shows them)
- If the screen needs new state, add a BLoC in AppBlocProviders following existing patterns
- If it needs new data, add the table/columns with a proper migration

For every feature shown in Figma but not implemented:
- Implement the full behavior, not just the static UI
- Match the interaction design shown in Figma (states, transitions, empty states)

---

## STEP 4 — Centralize design tokens

To keep the app in sync with Figma going forward:
1. Update lib/core/theme/app_colors.dart with the EXACT Figma color values (light + dark variants)
2. Update lib/core/theme/app_theme.dart TextTheme to match Figma text styles
3. Create lib/core/theme/app_dimensions.dart with Figma spacing/radius/elevation constants:
   ```dart
   abstract class AppDimensions {
     static const double paddingXs = 4;
     static const double paddingSm = 8;
     static const double paddingMd = 16;
     static const double paddingLg = 24;
     static const double radiusSm = 8;
     static const double radiusMd = 12;
     static const double radiusLg = 16;
     static const double radiusPill = 32;
     // ... derive actual values from Figma
   }
   ```
4. Replace hardcoded padding/radius/color values across the app with these constants

---

## STEP 5 — Full UI/UX audit and fix pass

Go through every screen and fix these systematically. Report each fix.

### Alignment:
- All icons in list tiles vertically centered with their text
- Leading icons / avatars aligned consistently across all list screens
- Trailing actions (call icon, info icon, chevron) right-aligned and consistent
- AppBar title alignment correct for RTL
- FAB position consistent across screens (bottom-end with correct margin)
- Text baseline alignment in rows containing icon + text

### Padding & margins:
- Consistent horizontal screen padding (use AppDimensions.paddingMd = 16 everywhere)
- Consistent vertical spacing between list items
- Consistent internal padding inside cards, bottom sheets, dialogs
- Safe area respected on all screens (top notch + bottom nav bar)
- No content touching screen edges
- Keypad keys evenly spaced with equal gaps
- Message bubbles have correct internal padding and inter-bubble spacing

### Dark / Light mode correctness:
- Every color must reference Theme.of(context).colorScheme or AppColors — NO hardcoded Colors.black / Colors.white that break in dark mode
- Check all screens in BOTH modes:
  - Text is readable (sufficient contrast) in both
  - Dividers visible but subtle in both
  - Card/surface colors differ correctly from background in both
  - Icons use onSurface color, not fixed black
  - Status bar icons (SystemUiOverlayStyle) flip correctly: dark icons on light, light icons on dark
  - Bottom sheets, dialogs, snackbars themed correctly in both
  - In-call / incoming-call screens (dark backgrounds) consistent in both modes
- Selection highlight, ripple, and focus colors correct in both modes

### RTL correctness:
- All screens render right-to-left
- Icons that imply direction (back arrow, send, chevron) point the correct way for RTL
- Text alignment correct (start = right for Persian)
- Swipe gestures work in the correct RTL direction
- Number fields and phone numbers display LTR even inside RTL layout (use Directionality override locally where needed for phone numbers)

### Touch targets & accessibility:
- All tappable elements at least 48×48dp
- Sufficient spacing between adjacent tap targets
- InkWell/ripple on every interactive element

### Empty states & loading:
- Every list screen has a proper empty state (illustration + text + optional action) matching Figma
- Loading states use shimmer/skeleton, not blank screens or raw spinners (unless Figma shows spinner)

### Animations & transitions:
- Match Figma's specified transitions where defined
- Consistent page transition style across the app
- Dialer key press, FAB, bottom sheet animations smooth

---

## STEP 6 — Verification

After all changes:
1. Run `flutter analyze` — zero warnings
2. Run `flutter test` — all pass
3. Manually verify (or describe how to verify) each synced screen against its Figma frame in BOTH light and dark mode
4. Produce a final report:
   - Screens synced
   - Screens/features newly added
   - UI/UX issues fixed (grouped by category)
   - Any Figma frames that could not be mapped and why

---

## EXECUTION ORDER

1. Step 1 — Figma mapping + token extraction (report before proceeding)
2. Step 4 — Centralize design tokens (colors, typography, dimensions)
3. Step 2 — Sync existing screens (one feature at a time: dialer, recents, contacts, messages, settings...)
4. Step 3 — Build missing screens/features from Figma
5. Step 5 — Full UI/UX audit pass (alignment, padding, dark/light, RTL)
6. Step 6 — Verification + final report

Stop after Step 1 and show me the mapping table before writing any code.
Then proceed step by step, running `flutter analyze` after each and reporting results.

Begin with Step 1 now.
```
