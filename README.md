# Chase: Open World — 3D-игра на Godot 4.7.2 (Android, вертикальный экран)

Одиночная мобильная игра: **свободная езда по большому открытому миру + погони с полицией**.
Один проект Godot, никаких внешних плагинов и сетевых зависимостей во время игры.

* Движок: **Godot 4.7.2 stable** (GL Compatibility / OpenGL ES 3.0).
* Платформа: **Android**, ABI **arm64-v8a**, портретная ориентация, immersive mode.
* Целевое устройство: Infinix HOT 40i (X6528B) — Unisoc T606, Mali-G57 MC1, 720×1280, 90 Гц.
* Мир: 4096 × 4096 м, детерминированная процедурная генерация (seed **20260923**),
  чанки 192 м со стримингом, LOD0–LOD3, MultiMesh для растительности, пулы объектов.
* Полиция: до 6 машин, уровни ИИ 1–4, роли CHASE / INTERCEPT / BLOCK / PIN / SUPPORT / REGROUP.

---

## 1. Как запустить

### 1.1. Из редактора Godot

1. Скачать Godot 4.7.2 (https://godotengine.org/download/archive/4.7.2-stable/).
2. `Project → Import…` → выбрать `project.godot` из этого репозитория.
3. Нажать ▶. Главная сцена — `scenes/main/main.tscn`.

### 1.2. Из командной строки (head-less машина, без GPU)

```bash
GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64

# импорт ресурсов (без графического окна)
$GODOT --headless --path . --import

# запуск самой игры (нужен GPU/дисплей; на сервере используйте смоук-тест)
$GODOT --path . res://scenes/main/main.tscn

# смоук-тест: поднимает игру целиком и играет за игрока (работает head-less)
$GODOT --headless --path . res://tools/smoke_run.tscn
```

Кнопки на клавиатуре (для отладки на ПК): `W/S` — газ/тормоз, `A/D` — руль,
`Space` — ручник, `N` — нитро, `R` — сброс машины на дорогу, `C` — смена камеры,
`F` — отладочная информация, `P`/`Esc` — пауза, `Enter` — начать погоню.

---

## 2. Управление на телефоне

Экран вертикальный. Сенсорное управление рисуется кодом (`scripts/input/mobile_controls.gd`),
поэтому оно одинаково работает на любом разрешении:

| Элемент | Расположение | Назначение |
|---|---|---|
| Руль-стик (или кнопки ◀ ▶) | слева внизу | поворот колёс |
| ГАЗ | справа внизу | тяга |
| ТОРМОЗ / ЗАДНИЙ ХОД | справа, ниже | торможение, на месте — задний ход |
| РУЧНИК | справа, слева от педалей | срыв задней оси в занос |
| NITRO | справа, над педалями | физический буст |
| «ПОГОНЯ» / «СБРОС» | сверху | старт погони, возврат машины на дорогу |
| Камера | свайп по экрану | свободный обзор вокруг машины |

Переключение «кнопки ↔ стик» — в настройках (`Settings.steering_mode`).

---

## 3. Проверка проекта head-less (то же, что делает CI)

```bash
# 1. линтер и парсер GDScript
pip install "gdtoolkit==4.*"
gdlint scripts tests tools
find scripts tests -name '*.gd' -print0 | xargs -0 -n1 gdparse > /dev/null

# 2. согласованность ресурсов и проекта (без запуска Godot)
python3 tools/check_assets.py     # текстуры/материалы: библиотека ↔ файлы ↔ генератор
python3 tools/check_project.py    # сцены, autoloads, портрет, пресет Android, тесты

# 3. тесты (без графики)
$GODOT --headless --path . res://tests/test_runner.tscn

# 4. смоук-тест настоящей игры
$GODOT --headless --path . res://tools/smoke_run.tscn
```

Тестовый раннер печатает `Файлов тестов: N проверок: M неудачных тестов: K` и
`TESTS PASSED` / `TESTS FAILED`. Важно: при нуле загруженных файлов он тоже
печатает «TESTS PASSED», поэтому CI дополнительно проверяет число файлов и
отсутствие `SCRIPT ERROR` в логе запуска игры.

---

## 4. Сборка APK

### 4.1. Что нужно

* Godot 4.7.2 (редактор) — переменная `GODOT_BIN`;
* шаблоны экспорта 4.7.2 (`Godot_v4.7.2-stable_export_templates.tpz` →
  `~/.local/share/godot/export_templates/4.7.2.stable/`);
* Android SDK с `build-tools` (нужны `apksigner`, `zipalign`) — `ANDROID_HOME`;
* JDK 17 — `JAVA_HOME`;
* ключ подписи (для release): переменные
  `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`, `GODOT_ANDROID_KEYSTORE_RELEASE_USER`,
  `GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD`.

### 4.2. Команда

```bash
export ANDROID_HOME=~/Android/Sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export GODOT_BIN=~/godot/Godot_v4.7.2-stable_linux.x86_64

tools/build_android.sh release apk     # -> build/android/chase-open-world-release.apk
tools/build_android.sh release aab     # Android App Bundle
tools/build_android.sh debug apk       # debug-подпись редактора
```

Скрипт делает всё по порядку: импорт → экспорт → проверка подписи и состава
пакета. Отдельно можно проверить уже собранный APK:

```bash
python3 tools/verify_apk.py build/android/chase-open-world-release.apk
python3 tools/verify_apk.py --selftest     # проверка самого разборщика манифеста
```

Проверяются: имя пакета и версия (совпадают с `export_presets.cfg`), **portrait**
в манифесте, наличие `lib/arm64-v8a/libgodot_android.so`, отсутствие лишних ABI
и разрешений, подпись (через `apksigner`, если он есть в SDK).

### 4.3. Только в CI и почему

Локальная сборка APK в этой среде невозможна: нет Android SDK, JDK, Gradle и
эмулятора, а `dl.google.com` (откуда их берут) заблокирован сетевой политикой
песочницы. Поэтому сборка APK выполняется в GitHub Actions (job `Android export
(APK)`), а локально проверяется всё, что можно проверить без Android-тулчейна:
импорт без ошибок, тесты, смоук-тест игры, корректность пресета экспорта и
разбор собранного пакета (`tools/verify_apk.py`, включая самотест разборщика).

---

## 5. Замена машины игрока или модели

Физика полностью отделена от внешнего вида:

* `scripts/vehicle/vehicle_config.gd` — масса, мотор, коробка, подвеска, шины,
  руль, тормоза, аэродинамика, нитро. Это единственное место, где «настраивается
  машина».
* `scripts/core/config_db.gd` — какие конфиги используются в игре
  (`Config.vehicle_player`, `Config.vehicle_police`); значения по умолчанию можно
  переопределить файлами в `data/resources/*.tres` (если файла нет — берутся
  значения из скрипта).
* `scripts/vehicle/vehicle_model_factory.gd` — **внешний вид**: собирает кузов и
  колёса процедурно (`build_car`). Чтобы вставить свою модель, достаточно в
  `PlayerCar`/`PoliceCarFactory` вызвать `set_visual_scene(scene)` и передать
  готовую сцену — физика, колёса-рейкасты и звук останутся теми же.
  Колёса ищутся по именам узлов `Wheel_*` (см. `VehicleModelFactory.build_wheel`).
* Цвет кузова: `paint_override` / `VehicleModelFactory` (палитра в
  `paint_palette`), переключается в меню (`Settings.cycle_player_paint`).

## 6. Физика автомобиля

`VehicleController` — это `RigidBody3D` с четырьмя рейкаст-колёсами
(`WheelSystem`), без «перемещения через `Transform.position`»: положение меняют
только силы.

* подвеска: пружина + демпфер (сжатие/отбой), ограничение хода и максимальной силы;
* шина: продольное скольжение из собственной угловой скорости колеса (wheelspin и
  блокировка возникают физически), боковая сила по упрощённой Magic Formula,
  эллипс трения, падение сцепления с ростом нагрузки (load sensitivity);
* ABS/TCS — необязательные помощники (`abs_enabled`, `tcs_enabled`);
* руль: ограничение угла на скорости, возврат, контрруль, распределение Аккермана;
* тормоз и ручник действуют раздельно (ручник срывает только заднюю ось);
* NITRO — только дополнительная тяга на ведущих колёсах и повышенный предел
  скорости (никаких телепортов и подмены позиции).

Проверки: `tests/unit/test_tyre_model.gd`, `tests/unit/test_nitro_system.gd`,
`tests/unit/test_pursuit_balance.gd`.

## 7. Полиция и баланс погони

* `PoliceManager` — спавн, обслуживание, арест; первая волна — не больше двух
  машин, дальше подкрепление по уровню розыска.
* `SpawnManager` — валидация точек появления: дорога, свободное место, не в
  кадре, дистанция 165–520 м, ровная земля; причина отказа всегда сохраняется в
  `last_rejection`.
* `PoliceAI` — уровни 1–4 меняют только **решения** (горизонт предсказания,
  задержку реакции, вероятность ошибки, набор ролей), не физику.
* `TrajectoryPredictor` — предсказание траектории игрока (велосипедная модель с
  ограничением по сцеплению) и точка перехвата.
* `RoutePlanner` — маршрут по графу дорог (A*) + чистый pursuit и перестроение.
* `ArrestSystem` — арест только при реальном обездвиживании в кольце машин.

Баланс скорости (проверяется тестами):

| Кто | Относительно игрока | Абсолютно |
|---|---|---|
| Игрок (ограничитель) | 1.00 | 158 км/ч |
| Полиция, любой уровень | ×1.01 | ≈159.6 км/ч |
| Игрок с нитро | ×1.2625 | ≈199.5 км/ч (≈1.25 от полиции) |

## 8. Сколько полиции

`Config.gameplay`: `min_police_count` = 1, `max_police_count` = 6
(`spawn_min_distance_m` 165, `spawn_max_distance_m` 520, `spawn_min_separation_m` 16).
Количество машин в погоне задаёт меню или `Game.start_pursuit(count, level)`;
уровень ИИ — 1..4 (`Config.police.level_count()`).

## 9. Размер мира и регионы

`Config.world` (`WorldConfig`): размер 4096 × 4096 м, чанк 192 м, seed 20260923,
уровень воды −5.5 м. Регионы связаны дорогами в одно целое (телепортов между
сценами нет): CITY (сетка улиц и проспектов, шаг квартала 145 м), SUBURBS,
HIGHWAYS, INTERCHANGES (развязки с эстакадами), COUNTRYSIDE, FIELDS, RURAL ROADS,
DESERT, OPEN TERRAIN. Город и трассы соединяются графом дорог: перекрёстки
свариваются во время генерации (`RoadNetworkBuilder._weld_network`), поэтому
маршрут полиции всегда проходит по асфальту.

## 10. Графика и качество

Пресеты LOW / MEDIUM / HIGH (`scripts/core/graphics_quality.gd`) управляют
тенями, их дальностью и размером карты, дальностью стриминга, бюджетом генерации
чанков, плотностью растительности и мелких объектов, LOD-смещением, SSAO,
свечением и пост-обработкой. Пресет применяется из меню
(`Settings.set_quality_index`) и может быть переопределён файлами
`data/resources/graphics_*.tres`.

Что уже есть для производительности на слабом телефоне:

* стриминг чанков вокруг камеры с бюджетом времени на кадр;
* LOD0–LOD1–LOD2–LOD3 (ближний, средний, дальний и «силуэт» с упрощённой
  геометрией, без мелких объектов и без теней);
* MultiMesh для массовых объектов, пул объектов (`ObjectPool`);
* отключены тени у растительности и дальних чанков, MSAA выключен;
* GL Compatibility как рендерер по умолчанию, ETC2/ASTC для текстур.

## 11. Nitro

`NitroSystem`: заряд (секунды), расход, автоматическая перезарядка, пауза после
опустошения, тяга (`nitro_thrust_n`), повышение предела скорости
(`SPEED_FACTOR`), индикатор в HUD. Отпускание кнопки гасит тягу в том же кадре.
Параметры — в `VehicleConfig` (группа «Nitro»).

## 12. LOD, стриминг и структура кода

```
scripts/
  core/      Config, Assets, Save, Settings, Perf, Game (автолоады), утилиты
  world/     TerrainField, RegionMap, RoadNetwork(+Builder), CityBuilder,
             SceneryBuilder, LandmarkBuilder, MeshBuilder, WorldGenerator,
             WorldStreamer, WorldChunk, BackgroundBuilder, RoadBuilder
  vehicle/   VehicleController, WheelSystem, NitroSystem, VehicleConfig,
             VehicleModelFactory, PlayerCar, ChaseCamera, PursuitBalance
  police/    PoliceManager, PoliceAI, PoliceCarFactory, PoliceConfig,
             TrajectoryPredictor, RoutePlanner, ArrestSystem, SpawnManager, PoliceRole
  ui/        MainMenu, Hud, Minimap
  input/     MobileControls (тач)
  main/      main.gd (сборка сцены)
tests/       unit + integration (head-less раннер, без внешних зависимостей)
tools/       генераторы текстур, проверки проекта и APK, смоук-тест
```

Дальность стриминга и радиусы LOD берутся из пресета качества
(`view_distance_m`, `near/mid/far_lod_distance_m`) — менять мир целиком
достаточно в одном месте (`WorldConfig`).

---

## 13. Честный статус проверок

* Проект импортируется без ошибок скриптов: `--import` → 0 строк `SCRIPT ERROR`.
* Тесты: 11 файлов, 618 проверок, 0 неудачных (`res://tests/test_runner.tscn`).
* Смоук-тест игры (сборка мира, разгон, нитро, погоня, качество графики,
  миникарта) — результат в логе CI-шага `Headless tests`.
* **BUILD VERIFIED / DEVICE RUNTIME NOT VERIFIED**: APK собирается и проверяется
  в CI (манифест, ABI, подпись), но запуск на реальном телефоне Infinix HOT 40i
  в этой среде выполнить нельзя — нет устройства и доступа к Android SDK/эмулятору.
  Всё, что можно измерить без устройства, измерено и приведено выше.

## 14. Лицензии ассетов

Все текстуры и иконки сгенерированы в этом репозитории
(`tools/generate_textures.py`, `art_source/icon_1024.png`) и не требуют
лицензионных отчислений.
