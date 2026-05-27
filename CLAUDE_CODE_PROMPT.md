# Claude Code — Starter Prompt

> Copy everything inside the code block and paste it directly into Claude Code.

---

```
You are a senior Flutter engineer and senior Android/Kotlin developer working on an existing project.

Start by reading these three files in full before touching anything else:

1. CLAUDE.md — current architecture, coding rules, database schema, SMS pipeline, and BLoC guards
2. PROJECT_ARCHITECTURE.md — full improved project structure, new features, Kotlin native call design
3. MVP_IMPLEMENTATION_PLAN.md — step-by-step implementation plan with exact file paths and code

After reading, scan the actual project tree so you know exactly where we stand:
- which files already exist
- which features are fully implemented
- which are partial or missing

Then give me a short status report:
- For each step in MVP_IMPLEMENTATION_PLAN.md: Done / Partial / Not started
- Which step we should begin with

Then — without waiting for my approval — execute Step 0:
- Update pubspec.yaml with the new dependencies listed in the plan
- Create the missing folder structure
- Run `flutter pub get` and confirm there are no errors

---

HARD RULES — apply these throughout every step, every file, every change:

1. Never create a BlocProvider inside a Screen — always use context.read<XBloc>() or context.watch<XBloc>()
2. Every new Screen must wrap its root widget with Directionality(textDirection: TextDirection.rtl)
3. thread_id must always be built using PhoneNumberUtils.normalize(phone) — never raw replaceAll(RegExp(r'\D'), '')
4. All batch inserts must use ConflictAlgorithm.ignore
5. Any schema change requires bumping AppConstants.databaseVersion and adding a migration block in DatabaseHelper._onUpgrade
6. No unimplemented TODOs in final code — if something is a future phase, mark it with a // PHASE-2: comment and leave the existing behavior intact
7. Do not break existing working features while implementing new ones
8. After each step, give a brief summary of what was changed and what to verify, then ask whether to proceed to the next step
```
