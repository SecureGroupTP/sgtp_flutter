# ARCH

## Цель

Этот документ задает целевую архитектуру Flutter-приложения, которую можно воспроизвести в новом проекте любой тематики: социальная сеть, маркетплейс, CRM, образование, доставка, финтех.

Архитектура должна решать четыре задачи:

1. Изолировать бизнес-логику от UI.
2. Исключить хаотичное смешение `Widget`, API-вызовов, глобального состояния и сокетов.
3. Сделать код масштабируемым по фичам, а не по случайным папкам.
4. Позволить безопасно заменять backend, экран, локальное хранилище или способ state management без каскадной переписки приложения.

Документ описывает не текущую реализацию, а новый целевой подход.

---

## Архитектурный принцип

Основа: `Feature-first modular architecture` с внутренним делением на слои:

- `presentation`
- `application`
- `domain`
- `data`
- `core`

Это не "чистая архитектура" в академическом виде с избытком абстракций, а практическая версия для Flutter-продукта.

Главная единица организации кода: **feature-модуль**, а не экран и не техническая папка вроде `widgets/` или `futures/`.

Каждая feature должна быть самодостаточной и включать:

- экран(ы)
- состояние
- сценарии использования
- доменные сущности
- репозитории
- источники данных
- мапперы

---

## Главные правила

### 1. Зависимости идут только сверху вниз

Разрешенные направления:

- `presentation -> application`
- `application -> domain`
- `application -> data` только через интерфейсы
- `data -> domain`
- `feature -> core`

Запрещено:

- `domain -> Flutter`
- `domain -> Dio`, `Hive`, `SharedPreferences`, Firebase и любой внешний SDK
- `presentation -> data`
- `Widget -> HTTP client`
- `Widget -> SQL/SharedPreferences`
- `feature A -> internal files of feature B`

### 2. Никаких глобальных mutable singletons

Запрещено хранить глобально:

- текущий токен
- текущего пользователя
- API-клиент со скрытым состоянием
- сокет с ручным доступом из любых экранов
- глобальные списки чатов, событий, пользователей

Все такие зависимости должны приходить через DI-контейнер и интерфейсы.

### 3. Один способ управления состоянием на один тип задачи

Рекомендуемый стандарт:

- `Cubit/Bloc` для экранов, форм, списков, потоков событий
- `Repository + stream/use case` для данных
- `ValueNotifier` только для локального чисто UI-состояния внутри одного экрана

Не допускается смешение:

- `Provider + ChangeNotifier + Bloc + globals` для одной и той же сущности

### 4. Сеть, кэш, сокеты и storage не видны из UI

UI работает только с:

- `ViewModel`
- `ViewState`
- `UiModel`
- `UiEffect`

UI не должен знать:

- URL
- JSON
- DTO
- headers
- retry policy
- token refresh
- websocket event names

### 5. Доменные модели не равны API DTO

Нужно разделять:

- `DTO` для wire format
- `Entity` для бизнес-смысла
- `ViewState` и `UiModel` для UI

Одна и та же структура не должна использоваться одновременно как:

- ответ сервера
- внутренняя сущность
- модель виджета

### 6. Все side effects централизуются

К side effects относятся:

- сеть
- локальное хранилище
- push
- аналитика
- логирование
- файловая система
- геолокация
- сокеты
- permissions

Они должны жить в `data` или `core/services`, но не внутри экрана.

---

## MVVM внутри feature

MVVM в этом проекте используется как способ жестко отделить UI от логики, не ломая feature-first и слоистую архитектуру.

Физическая структура проекта остается прежней:

- `presentation`
- `application`
- `domain`
- `data`

Но на уровне ролей действует такая схема:

- `View` = `presentation`
- `ViewModel` = `application`
- `Model` = `domain + data`

### Соответствие терминов

- `Widget`, `Page`, `Screen` = `View`
- `Cubit` или `Bloc` = `ViewModel`
- `State class` = `ViewState`
- `UiModel` = проекция данных для конкретного виджета или экрана
- `Entity`, `Repository`, `UseCase`, `DataSource` = `Model`

### Поток данных

```text
View -> user intent -> ViewModel -> domain/data -> ViewState -> View
```

Для одноразовых действий используется отдельный поток:

```text
ViewModel -> UiEffect -> View
```

### Правила MVVM

- `View` не вызывает `Repository`, `UseCase`, `ApiClient`, `Storage` напрямую
- `View` не знает `DTO`, `Entity`, JSON, transport и cache policy
- `ViewModel` не знает `Widget`, `BuildContext`, `Theme`, `TextEditingController`, `ScrollController`
- `ViewModel` принимает user intent, запускает сценарии, собирает `ViewState`
- `ViewState` immutable и хранит только то, что нужно для отображения экрана
- `UiEffect` используется только для одноразовых событий: navigation, snackbar, dialog, copy, share
- `UiModel` не содержит бизнес-логики и не используется как замена `ViewModel`

### Практическое правило

- `Cubit` — ViewModel по умолчанию
- `Bloc` — ViewModel для realtime, сложных форм, большого числа событий и orchestration нескольких источников данных

### Что считается нарушением MVVM

- виджет сам решает, когда грузить, ретраить, пагинировать или синхронизировать данные
- виджет напрямую собирает display-данные из `Entity` по всему дереву
- `Bloc/Cubit` используется только как транспорт куска данных, а реальная логика остается в `Widget`
- в `State` лежат `BuildContext`, контроллеры, DTO или инфраструктурные зависимости

---

## Слои

## 1. `core`

`core` содержит общий код, не относящийся к конкретной бизнес-фиче.

### Что хранится в `core`

- базовые типы ошибок
- result wrapper
- общие value objects
- DI configuration
- router
- theme
- env config
- logger
- auth session manager
- network primitives
- base API client
- interceptors
- websocket base client
- storage adapters
- permission helpers
- base pagination primitives

### Что не хранится в `core`

- экран чатов
- логика профиля
- сущности конкретной предметной области
- use case конкретной feature

### Пример структуры

```text
lib/core/
  app/
    app.dart
    bootstrap.dart
  config/
    env.dart
    feature_flags.dart
  di/
    injector.dart
  error/
    app_exception.dart
    failure.dart
  result/
    result.dart
  network/
    api_client.dart
    auth_interceptor.dart
    retry_policy.dart
    network_exception_mapper.dart
  storage/
    key_value_store.dart
    secure_store.dart
  realtime/
    socket_client.dart
    socket_event.dart
  navigation/
    app_router.dart
    routes.dart
  theme/
    app_theme.dart
  utils/
    date_formatter.dart
    debounce.dart
```

---

## 2. `domain`

`domain` хранит бизнес-смысл без знания о Flutter и инфраструктуре.

### Состав domain-слоя

- `Entity`
- `ValueObject`
- `Repository contract`
- `UseCase contract`, если нужен
- доменные правила и policy

### Требования к `domain`

- без `BuildContext`
- без `Color`, `Widget`, `Theme`
- без JSON
- без `Dio`, `http`, `Hive`
- без `fromJson` и `toJson` в entity

### Пример

```text
domain/
  entities/
    user.dart
    order.dart
  value_objects/
    email.dart
    phone_number.dart
  repositories/
    user_repository.dart
    order_repository.dart
  use_cases/
    get_current_user.dart
    create_order.dart
```

### Правило для entity

Entity отвечает на вопрос: "что это в бизнесе?", а не "как это пришло с сервера?".

Примеры:

- `Chat`
- `Message`
- `Product`
- `Lesson`
- `Invoice`

Не примеры:

- `MessageResponseDto`
- `UserJson`
- `ProfileCardModel`

---

## 3. `data`

`data` реализует доступ к внешним системам и преобразование данных.

### Состав data-слоя

- `Repository implementation`
- `RemoteDataSource`
- `LocalDataSource`
- `DTO`
- `Mapper`
- `Cache policy`

### Обязанности

- отправить запрос
- принять ответ
- десериализовать JSON в DTO
- преобразовать DTO в domain entity
- положить и забрать кэш
- объединить remote и local источники
- обработать инфраструктурные ошибки

### Запрещено в `data`

- держать `BuildContext`
- строить UI state
- писать логику показа snackbar или navigation

### Пример структуры

```text
data/
  repositories/
    user_repository_impl.dart
  sources/
    remote/
      user_remote_data_source.dart
    local/
      user_local_data_source.dart
  dto/
    user_dto.dart
  mappers/
    user_mapper.dart
```

### Правило репозитория

Интерфейс репозитория живет в `domain`, реализация живет в `data`.

Пример:

```dart
abstract class UserRepository {
  Future<User> getMe();
}
```

```dart
class UserRepositoryImpl implements UserRepository {
  final UserRemoteDataSource remote;
  final UserLocalDataSource local;
  final UserMapper mapper;
}
```

---

## 4. `application`

`application` orchestrates use cases и управляет состоянием feature.

Это слой координации между UI и domain/data.
В терминах MVVM именно `application` играет роль `ViewModel`-слоя.

### Что хранится в `application`

- `Cubit`
- `Bloc`
- `ViewState`
- `UiEffect`
- `Event`
- `UseCase implementation`
- coordinators
- form controllers в архитектурном смысле

### Что делает `application`

- запускает use case
- объединяет несколько use case
- принимает user intent из `presentation`
- преобразует domain entity в `ViewState` и `UiModel`
- управляет загрузкой, refresh, pagination, optimistic update
- подписывается на streams/realtime
- решает, когда обновлять экран
- выпускает одноразовые `UiEffect`

### Что не делает `application`

- не рисует UI
- не отправляет HTTP напрямую
- не знает о JSON
- не знает о `BuildContext` и widget lifecycle

### Пример структуры

```text
application/
  cubit/
    profile_cubit.dart
    profile_view_state.dart
    profile_ui_effect.dart
  models/
    profile_header_ui_model.dart
  use_cases/
    load_profile_use_case.dart
    update_profile_use_case.dart
  coordinators/
    profile_realtime_coordinator.dart
```

### Когда использовать `Cubit`, а когда `Bloc`

Использовать `Cubit`, если:

- набор действий небольшой
- экран простой
- события линейные

Использовать `Bloc`, если:

- много разных внешних событий
- нужен realtime
- есть сложная форма
- есть orchestration нескольких источников данных
- важна явная модель событий

Практическое правило:

- по умолчанию `Cubit`
- `Bloc` только там, где он реально упрощает сложность

---

## 5. `presentation`

`presentation` содержит только UI и bind к application-слою.
В терминах MVVM это `View`-слой.

### Что хранится в `presentation`

- pages
- screens
- widgets
- dialogs
- bottom sheets
- formatters, если они чисто визуальные
- adapters из `ViewState` и `UiModel` в виджеты

### Что делает `presentation`

- подписывается на `ViewModel` (`Cubit/Bloc`)
- отображает `ViewState`
- отправляет user intent
- слушает `UiEffect`
- показывает loading/error/empty/content

### Что запрещено в `presentation`

- делать HTTP запросы
- работать с токеном
- парсить JSON
- напрямую читать `SharedPreferences`
- вручную держать бизнес-состояние коллекций, которые уже есть в Bloc/Cubit
- вызывать `UseCase` и `Repository` напрямую

---

## Организация по feature

Рекомендуемая основная структура:

```text
lib/
  core/
  features/
    auth/
      domain/
      data/
      application/
      presentation/
    profile/
      domain/
      data/
      application/
      presentation/
    messaging/
      domain/
      data/
      application/
      presentation/
    events/
      domain/
      data/
      application/
      presentation/
```

### Почему feature-first

Такой подход:

- уменьшает связанность
- упрощает навигацию по коду
- позволяет переносить модуль в другой проект
- делает ownership очевидным
- уменьшает риск "общей свалки" в `widgets/`, `models/`, `services/`

---

## Стандарт feature-модуля

Каждая feature должна строиться по одному шаблону.

### Минимальный состав feature

```text
features/messaging/
  domain/
    entities/
      chat.dart
      message.dart
    repositories/
      messaging_repository.dart
  data/
    dto/
      message_dto.dart
    mappers/
      message_mapper.dart
    sources/
      remote/
        messaging_remote_data_source.dart
      local/
        messaging_local_data_source.dart
    repositories/
      messaging_repository_impl.dart
  application/
    cubit/
      chat_list_cubit.dart
      chat_list_state.dart
      chat_details_cubit.dart
      chat_details_state.dart
    use_cases/
      get_chat_list.dart
      get_chat_messages.dart
      send_message.dart
  presentation/
    pages/
      chat_list_page.dart
      chat_page.dart
    widgets/
      chat_tile.dart
      message_bubble.dart
```

### Обязательные правила для feature

- feature не импортирует файлы из внутренностей другой feature
- общение между feature идет только через public contracts
- если логика реально общая, она переносится в `core`
- если логика специфична для одной feature, она остается внутри feature

---

## Репозитории

Репозиторий нужен как boundary между domain/application и data.

### Репозиторий обязан

- отдавать domain entities
- скрывать источник данных
- скрывать детали пагинации и кэша
- иметь бизнес-осмысленные методы

### Репозиторий не должен

- называться как API endpoint
- возвращать `Map<String, dynamic>`
- возвращать raw `Response`
- содержать UI state

### Хорошие примеры методов

- `getCurrentUser()`
- `getOrdersPage(cursor)`
- `watchChat(chatId)`
- `markMessageAsRead(messageId)`

### Плохие примеры методов

- `fetchUsersJson()`
- `postRequestToOrders()`
- `getMapData()`

---

## Use Cases

Use case нужен там, где есть законченное действие пользователя или бизнес-сценарий.

### Примеры use case

- `SignIn`
- `RestorePassword`
- `LoadFeed`
- `CreateEvent`
- `SendMessage`
- `JoinClub`

### Правила

- один use case = один завершенный сценарий
- имя через глагол
- не смешивать несколько несвязанных сценариев
- use case возвращает `Result<T, Failure>` или аналог

### Когда можно обойтись без отдельного use case

Если feature очень простая и действие тривиально, допустимо вызывать репозиторий из Cubit напрямую. Но это исключение, а не базовый стандарт.

Для нового масштабируемого проекта лучше использовать явные use case.

---

## State management

Базовый стандарт: `flutter_bloc`.

### Причины

- явный поток состояния
- легко тестировать
- удобно описывать loading/error/success
- хорошо подходит для realtime и сложных форм

### Структура состояния

Состояние должно быть:

- явным
- immutable
- сериализуемым при необходимости
- без логики побочных эффектов

### Рекомендуемый паттерн состояния

```dart
class ChatState {
  final bool isLoading;
  final bool isRefreshing;
  final List<MessageItemVm> items;
  final String? errorMessage;
  final bool canSend;
}
```

### Правила

- не хранить в state `TextEditingController`
- не хранить `BuildContext`
- не хранить `ScrollController`
- не хранить DTO
- не мутировать список на месте

### UI-only state

Локальные штуки вроде:

- открыт ли emoji panel
- выбран ли tab в локальном подвиджете
- фокус в поле

могут оставаться внутри `StatefulWidget`, если они не являются бизнес-состоянием.

---

## Realtime и сокеты

Realtime не должен жить как свободный глобальный объект.

### Правильный подход

1. В `core/realtime` есть единый `SocketClient`.
2. Он умеет:
   - connect
   - disconnect
   - subscribe
   - unsubscribe
   - send
   - reconnect
   - auth refresh
3. Feature работает не с raw socket, а с feature-specific gateway/repository.

### Слои

- `SocketClient` в `core`
- `MessagingRemoteDataSource` в `data`
- `WatchMessagesUseCase` в `application/domain`
- `ChatCubit/Bloc` в `application`

### Правила

- event names не должны быть размазаны по UI
- reconnect policy централизована
- deduplication событий централизована
- временные подписки снимаются автоматически
- auth в сокете использует тот же session provider, что и REST

---

## Сетевой слой

Нужен один стандартизованный API client.

### Базовые компоненты

- `ApiClient`
- `AuthInterceptor`
- `RetryPolicy`
- `ErrorMapper`
- `RequestOptions`

### Правила

- один HTTP client на приложение
- токен подмешивается interceptor-ом
- refresh токена централизован
- DTO и endpoint logic живут в `data`
- UI не знает о кодах ответа

### Ошибки

Сетевые ошибки должны преобразовываться в понятные типы:

- `UnauthorizedFailure`
- `ForbiddenFailure`
- `ValidationFailure`
- `NetworkFailure`
- `ServerFailure`
- `UnknownFailure`

UI не должен разбирать `DioException` напрямую.

---

## Локальное хранилище и сессия

### Разделение ответственности

- `SecureStore` для токенов
- `KeyValueStore` для флагов и простых настроек
- локальная БД для кэшируемых коллекций и offline-поддержки

### Session manager

Нужен отдельный компонент:

- `SessionRepository` или `AuthSessionManager`

Он отвечает за:

- current auth state
- access token
- refresh token
- logout cleanup
- bootstrap after app launch

Экран не должен сам читать токен из `SharedPreferences`.

---

## Навигация

Навигация должна быть централизована.

### Правила

- все route names и deep links объявлены в одном месте
- feature предоставляет свои route builders
- навигация по результату бизнес-сценария инициируется из `presentation`, но условия перехода определяются состоянием `application`

### Пример

- `AuthCubit` эмитит `authenticated`
- `presentation` слушает это состояние и переводит пользователя на main shell

Не нужно делать навигацию внутри repository или data source.

---

## Ошибки и Result

Нужен единый стандарт возврата результата.

### Рекомендуемый вариант

- `Result<SuccessType, Failure>`

или

- `Either<Failure, SuccessType>`

### Зачем это нужно

- не размазывать `try/catch` по каждому экрану
- иметь типизированные ошибки
- держать единый подход для UI

### Правило

Infrastructure exception преобразуется в `Failure` в `data`, а не пробрасывается вверх как raw exception.

---

## Маппинг моделей

Мапперы обязательны между слоями.

### Цепочка преобразования

```text
JSON <-> DTO <-> Entity <-> UiModel/ViewState
```

### Правила

- `DTO` знает JSON
- `Entity` не знает JSON
- `ViewModel` управляет состоянием и сценарием экрана
- `ViewState` знает только то, что нужно экрану
- `UiModel` знает только то, что нужно конкретному виджету или section
- преобразование не выполняется внутри виджета

### Зачем нужны `ViewState` и `UiModel`

Чтобы экран не зависел от формы domain entity и не собирал display-данные на лету по всему дереву.

---

## UI composition

### Деление UI

- `Page`: точка входа экрана, DI и provider binding
- `Screen`: основная композиция состояния
- `Section widget`: крупный кусок экрана
- `Reusable widget`: переиспользуемый визуальный компонент

### Правила

- `Page` знает, какой `ViewModel` (`Cubit/Bloc`) создать
- `Screen` знает, как читать `ViewState`
- мелкие виджеты не должны тянуть зависимости из DI напрямую без причины

### Пример

`ProductPage`:

- создает `ProductCubit`
- передает `productId`

`ProductScreen`:

- рендерит loading/content/error

`ProductPriceBlock`:

- получает уже готовые данные через параметры

---

## Формы

Форма должна иметь отдельную application-логику.

### Правила

- поля формы хранятся в form state
- валидация выполняется централизованно
- submit flow описан явно
- серверные validation errors маппятся в state

### Не допускается

- размазывать валидацию по `onChanged` разных виджетов без общего state
- отправлять форму напрямую из кнопки в API client

---

## Пагинация

Пагинация должна быть стандартизована.

### Базовые компоненты

- `PageCursor`
- `PaginatedResult<T>`
- `PaginationController` или встроенная логика в Cubit

### Правила

- экран не должен сам считать offset вручную по месту
- правила `refresh`, `loadMore`, `hasMore`, `dedupe`, `inFlight protection` едины

---

## Кэширование

Кэш нужен только там, где он дает продуктовую ценность.

### Политики кэша

- `networkOnly`
- `cacheFirst`
- `networkFirst`
- `staleWhileRevalidate`

У каждой feature политика задается явно.

### Правила

- политика не выбирается случайно внутри экрана
- срок жизни кэша централизован
- invalidation описан отдельно

---

## Тестируемость

Архитектура должна быть рассчитана на тесты.

### Обязательные уровни

- unit tests для use cases
- unit tests для mappers
- bloc/cubit tests для state transitions
- widget tests для ключевых экранов

### Что должно мокаться легко

- repository
- data source
- socket client
- storage
- analytics

Если компонент невозможно изолированно протестировать, значит зависимость проведена неправильно.

---

## Именование

Нужен жесткий стиль именования.

### Сущности

- `User`
- `Chat`
- `Message`

### DTO

- `UserDto`
- `ChatMessageDto`

### Репозитории

- `UserRepository`
- `UserRepositoryImpl`

### Источники данных

- `UserRemoteDataSource`
- `UserLocalDataSource`

### Состояние

- `ProfileCubit`
- `ProfileState`
- `ProfileStatus`

### Use case

- `LoadProfile`
- `UpdateProfile`
- `SendMessage`

Не использовать названия:

- `api2`
- `futures`
- `helpers` как свалка
- `utils` как место для бизнес-логики
- `manager` без точной ответственности

---

## DI и композиция приложения

Все зависимости собираются в одном месте.

### Пример composition root

```text
lib/core/di/injector.dart
```

### В composition root регистрируются

- API client
- storage
- session manager
- repositories
- data sources
- use cases
- cubits/blocs factories

### Правила

- никакого `new Api()` внутри экрана
- никакого создания репозитория внутри виджета
- `BlocProvider` может создавать Cubit через DI, но не собирать вручную всю инфраструктуру экрана

### Где создаются инфраструктурные зависимости

Сетевые и инфраструктурные зависимости создаются только на уровне корня приложения, а не внутри экранов. В этой схеме роль composition root выполняет корневой слой приложения: именно там через `MultiProvider` и `MultiBlocProvider` собираются долгоживущие app-level зависимости, например API client, repositories, section managers, session-related сервисы и app-wide blocs. Экран не создает `Api` самостоятельно; вместо этого screen-level `Bloc` или `Cubit` получает уже готовые зависимости через `context.read<T>()` и передает их в свой конструктор. Создание `Api`, repository или transport-объектов внутри `Widget`, `Page`, `Bloc` или `Cubit` запрещено, потому что это ломает единый граф зависимостей и скрывает lifecycle инфраструктуры.

### Пример регистрации в composition root

```dart
void main() {
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiRepository>(
          create: (_) => ApiRepository(
            api: Api(),
          ),
        ),
        Provider<ApiSectionManager>(
          create: (_) => ApiSectionManager(
            messaging: ApiMessagingSection(
              apiCaller: DioApiCaller(
                baseUrl: "http://example.com/messaging",
              ),
            ),
          ),
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (_) => MessagesStateCubit({}, {}),
          ),
          BlocProvider(
            create: (_) => SioBloc("ws://example.com"),
          ),
        ],
        child: const MyApp(),
      ),
    ),
  );
}
```

### Пример использования на уровне экрана

```dart
class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => ChatBloc(
        id: chatId,
        apiRepository: context.read<ApiRepository>(),
        apiSectionManager: context.read<ApiSectionManager>(),
      ),
      child: const ChatScreen(),
    );
  }
}
```

---

## Shell и app-level composition

Если приложение многовкладочное, нужен `AppShell`.

### Пример

```text
core/app/
  app.dart
  app_shell.dart
```

`AppShell` отвечает за:

- нижнюю навигацию
- root tabs
- app-level listeners
- auth gate

Feature-экраны не должны сами реализовывать глобальную композицию приложения.

---

## Стандарт жизненного цикла запуска

### Шаги bootstrap

1. Инициализация env
2. Инициализация DI
3. Инициализация storage
4. Восстановление session
5. Инициализация analytics/crash reporting
6. Запуск `App`

### Правило

Логика bootstrap не должна быть размазана между случайными экранами.

---

## Что запрещено в новом проекте

- глобальные переменные состояния в `globals.dart`
- несколько параллельных API-слоев без стратегии миграции
- хранение токена в UI-слое
- вызовы REST и сокетов прямо из виджетов
- общие папки-свалки `helpers`, `futures`, `misc`
- смешение DTO, domain entity и UI model
- несколько state management подходов для одного и того же потока
- закомментированные старые реализации вместо удаления и миграции
- прямые импорты между внутренностями разных feature

---

## Что обязательно в новом проекте

- feature-first структура
- единый DI
- единый сетевой клиент
- единый session manager
- явные repository interfaces
- domain entities отдельно от DTO
- один базовый state management стандарт
- use case для важных бизнес-сценариев
- typed failures
- отдельный realtime слой

---

## Рекомендуемая итоговая структура проекта

```text
lib/
  core/
    app/
    config/
    di/
    error/
    navigation/
    network/
    realtime/
    result/
    storage/
    theme/
    utils/
  features/
    auth/
      domain/
      data/
      application/
      presentation/
    home/
      domain/
      data/
      application/
      presentation/
    profile/
      domain/
      data/
      application/
      presentation/
    messaging/
      domain/
      data/
      application/
      presentation/
    notifications/
      domain/
      data/
      application/
      presentation/
```

---

## Правило принятия архитектурного решения

Если возникает вопрос "куда положить код?", проверка идет в таком порядке:

1. Это конкретная бизнес-фича?
   Если да, код идет внутрь feature.
2. Это общий инфраструктурный механизм?
   Если да, код идет в `core`.
3. Это бизнес-смысл?
   Если да, это `domain`.
4. Это интеграция с внешней системой?
   Если да, это `data`.
5. Это orchestration и state?
   Если да, это `application`.
6. Это отображение?
   Если да, это `presentation`.

Если код не проходит такую классификацию, его место выбрано неправильно.

---

## Правило миграции и поддержки

Даже при рефакторинге нельзя оставлять архитектуру в гибридном состоянии надолго.

### Если начинается миграция

- назначается целевой стандарт
- фиксируется список legacy-модулей
- новые фичи пишутся только по новой схеме
- старые куски переносятся по feature целиком
- после переноса legacy-ветка удаляется, а не комментируется

---

## Краткий шаблон для создания новой feature

1. Создать папку `features/<feature_name>/`.
2. Добавить `domain/entities`.
3. Добавить `domain/repositories`.
4. Добавить `data/dto`, `data/mappers`, `data/sources`, `data/repositories`.
5. Добавить `application/use_cases`.
6. Добавить `application/cubit` или `application/bloc`.
7. Добавить `presentation/pages` и `presentation/widgets`.
8. Зарегистрировать зависимости в DI.
9. Подключить routes.
10. Написать unit tests для use case и state.

---

## Итог

Целевой стандарт для нового проекта:

- строим приложение по `features`
- внутри каждой feature соблюдаем слои `presentation -> application -> domain <- data`
- инфраструктуру держим в `core`
- UI не знает о сети и storage
- состояние централизовано через `Cubit/Bloc`
- репозитории возвращают domain entities
- DTO, entity и UI model разделены
- realtime, auth, session и navigation централизованы

Если этот документ соблюдается, новый проект на другой тематике можно собирать предсказуемо, без повторения текущих проблем смешанной архитектуры.
