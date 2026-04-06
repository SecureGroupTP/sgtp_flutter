# Architecture Rules

This project follows the architecture defined in `ARCH.MD`. All code you write **must** comply with the rules below. No exceptions unless explicitly requested.

---

## Layer Structure

Every feature is organized as:

```
features/<name>/
  domain/        ← business logic, no Flutter, no SDKs
  data/          ← network, storage, serialization
  application/   ← blocs, cubits, services, coordinators
  presentation/  ← widgets, pages, screens only
```

Shared infrastructure lives in `lib/core/`.

---

## Dependency Rules

**Allowed:**
- `presentation` → `application`
- `application` → `domain`
- `data` → `domain`
- anything → `core`
- `application` → `data` **only through domain interfaces**

**Forbidden — never write this:**
- `presentation` imports from `data` (any feature)
- `presentation` imports a concrete repository, HTTP client, socket, or storage class
- `application` (Bloc/Cubit/Service) imports a concrete data class directly — use an interface
- `domain` imports Flutter, Dio, Hive, SharedPreferences, or any external SDK
- Feature A imports internal files of Feature B

If you need to access data from the application layer, define an abstract interface in `domain/repositories/` and implement it in `data/`.

---

## DI and Composition Root

All dependencies are wired **only** in `lib/core/di/injector.dart` (`AppInjector.build()`).

- Never instantiate a repository, API client, socket, or transport inside a Widget, Bloc, or Service.
- Blocs and services receive dependencies through their constructors.
- Widgets obtain app-level dependencies via `context.read<T>()` — only types that are registered in `app.dart` via `RepositoryProvider`.
- Factory functions (e.g. `SgtpSessionFactory`, `UserDirClientFactory`) are defined as typedefs in `domain/repositories/` and wired in the injector with concrete implementations.

---

## Domain Layer Rules

Domain files must have **zero** imports of:
- `package:flutter/...`
- `package:dio/...`, `package:http/...`
- `package:hive/...`, `package:shared_preferences/...`
- Any data-layer file from this project

Domain contains:
- Entities (plain Dart classes representing business concepts)
- Repository/client interfaces (`abstract class`)
- Domain events/models used across layers
- Factory typedefs for injectable factories

---

## Data Layer Rules

- Repository **interfaces** live in `domain/repositories/`.
- Repository **implementations** live in `data/repositories/`.
- Concrete network clients (e.g. `SgtpClient`, `UserDirClient`) live in `data/services/` and implement domain interfaces.
- DTOs and serialization stay inside `data/`.
- Data classes must never contain `BuildContext`, UI state, or navigation logic.

---

## Application Layer Rules

- Blocs and Cubits depend only on domain interfaces, never on concrete data classes.
- Application services (e.g. `SettingsManagementService`) may wrap data-layer classes, but must expose a domain-friendly API surface.
- When a Bloc needs to create a data object (e.g. open a socket session), inject a factory typedef rather than importing the concrete class.
- No `import 'package:.../data/...'` in Bloc, Cubit, or Service files — route through interfaces.

---

## Presentation Layer Rules

- Pages and screens interact only with Blocs/Cubits via `context.read<T>()` / `BlocBuilder` / `BlocListener`.
- No HTTP calls, no JSON parsing, no direct storage reads in widgets.
- No `context.read<SettingsRepository>()` or any other concrete data/repository type — only application-layer services and domain types.
- UI state (scroll position, focus, animation) may live in `StatefulWidget`; business state must live in a Bloc/Cubit.

---

## Naming Conventions

| Thing | Name |
|---|---|
| Domain entity | `User`, `Chat`, `Message` |
| Domain interface | `IUserDirClient`, `ISgtpSession`, `ChatStorageGateway` |
| Factory typedef | `SgtpSessionFactory`, `UserDirClientFactory` |
| Data implementation | `UserDirClient`, `SgtpClient`, `SettingsRepository` |
| Application service | `SettingsManagementService`, `HomePersistenceService` |
| Bloc/Cubit state | `ChatState`, `RoomsState` |
| DTO | `UserDto`, `MessageDto` |

---

## State Management

- Use `Bloc` for complex flows with many event types, realtime, or multiple data sources.
- Use `Cubit` for simple screens with linear state.
- Never store `TextEditingController`, `BuildContext`, `ScrollController`, or DTOs in Bloc/Cubit state.
- Do not mix multiple state management approaches for the same data flow.

---

## Adding a New Feature

1. Create `features/<name>/domain/entities/` — define business entities.
2. Create `features/<name>/domain/repositories/` — define abstract interfaces.
3. Create `features/<name>/data/repositories/` — implement the interfaces.
4. Create `features/<name>/application/` — Bloc/Cubit + services.
5. Create `features/<name>/presentation/` — pages + widgets.
6. Register everything in `lib/core/di/injector.dart`.
7. Expose via `RepositoryProvider` in `lib/core/app/app.dart` if needed by the widget tree.

---

## Quick Decision Guide

When you're not sure where code belongs:

- Business concept with no Flutter? → `domain/entities/`
- Contract for accessing data? → `domain/repositories/` (abstract)
- Network/storage/serialization? → `data/`
- State orchestration, use case, realtime subscription? → `application/`
- Widget, screen, dialog? → `presentation/`
- Shared infrastructure (logger, crypto utils, transport base)? → `core/`

---

## What to Check Before Committing

Run `dart analyze lib/` and confirm:
- Zero `error` lines.
- Zero `warning` lines.
- No `import '...data/...'` in any `application/`, `presentation/`, or `domain/` file (except `SettingsManagementService` and `AppInjector`, which are the designated facade and composition root).
