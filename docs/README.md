# هم‌رسان — documentation

Start with **[DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)**: the commands, the rules
that apply everywhere, and a table of which area note to read before touching
what.

## Overview

| Document | What it covers |
|---|---|
| [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) | Commands, rules that hold everywhere, architecture, the Kotlin/Dart mirrors |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The big picture: start-up, layers, editions, native bridges |
| [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) | Where things are: folders, features, native modules, tables |
| [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) | BLoC conventions, the registered BLoCs, the state guards |
| [NETWORK_LAYER.md](NETWORK_LAYER.md) | The data boundaries: SQLite, platform channels, plugins |
| [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) | The non-obvious decisions and what each one trades |
| [PERFORMANCE_NOTES.md](PERFORMANCE_NOTES.md) | What keeps it fast, and what must not regress |
| [KNOWN_ISSUES.md](KNOWN_ISSUES.md) | What is open, accepted or not yet verified |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Setup, commands, conventions, definition of done |

## Area notes — `architecture/`

Read the matching note before changing an area; each carries invariants that
are not obvious from the code.

| Note | Area |
|---|---|
| [dialer-and-calls.md](architecture/dialer-and-calls.md) | Keypad, «اخیر», the default-dialer path, call screens, USSD, speed dial, auto redial |
| [sms-role-and-sync.md](architecture/sms-role-and-sync.md) | SMS send/receive, the default-SMS role, the device mirror-sync, notifications |
| [contacts.md](architecture/contacts.md) | Contact extras, merging, labels, photos, name format |
| [inbox-search-and-groups.md](architecture/inbox-search-and-groups.md) | Search, blocking and spam, new conversation, group conversations |
| [conversation-and-composer.md](architecture/conversation-and-composer.md) | The bubble, the composer, text size, links, delivery ticks, text direction |
| [scheduled-messages.md](architecture/scheduled-messages.md) | Scheduled SMS |
| [dual-sim.md](architecture/dual-sim.md) | Everything that names a SIM |
| [drafts-and-templates.md](architecture/drafts-and-templates.md) | Drafts, categories, «قالب آماده» |
| [settings.md](architecture/settings.md) | The settings pages |
| [editions.md](architecture/editions.md) | The three editions, activation, the secure section, SMS encryption, the key bank, encrypted SMS and groups, the hidden phonebook, cover text, release builds |

## Other folders

| Folder | Contents |
|---|---|
| `publishing/` | The store launch (بازار / مایکت): status, permission review, listing |
| `mentor/` | The user manual, the secure-editions report and the issuance-panel guide (HTML + PDF) |
| `privacy/` | The privacy policy page |
| `archive/` | Finished planning documents, kept for history |
| `پیوست فنی.docx` | The mentor's feature matrix per edition (priorities are the cell colours) |
| `SMS_Android_App_Technical_Document.*`, `Hamrasan_Technical_Document_FA.*` | Feasibility and technical documents |

The Windows key-bank tool and its panel have their own guide:
[`tools/keybank/README.md`](../tools/keybank/README.md).
