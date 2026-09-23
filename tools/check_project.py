#!/usr/bin/env python3
"""Быстрые проверки проекта без запуска Godot (первый job в CI).

Проверяется то, что обычно всплывает только на устройстве или в конце сборки:

  1. главная сцена и все autoload-скрипты из project.godot существуют;
  2. ориентация проекта — портретная (жёсткое требование ТЗ), viewport 720x1280;
  3. каждый путь `res://...`, упомянутый в сценах, ресурсах и скриптах,
     действительно существует в проекте (нет битых ссылок на текстуры/сцены);
  4. export_presets.cfg: заполнено уникальное имя пакета, включена только
     arm64-v8a, формат APK, разрешения не выставлены;
  5. у каждого теста есть метод test_* (пустой файл теста не пройдёт незаметно).

Код выхода 0 — всё в порядке, 1 — найдены проблемы.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "project.godot"
PRESET = ROOT / "export_presets.cfg"

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)
    print(f"ОШИБКА: {message}")


def project_settings(text: str, section: str) -> dict[str, str]:
    values: dict[str, str] = {}
    current = ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            continue
        if current != section or not line or line.startswith(";") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def check_project() -> None:
    text = PROJECT.read_text(encoding="utf-8")
    application = project_settings(text, "application")
    display = project_settings(text, "display")
    autoload = project_settings(text, "autoload")

    main_scene = application.get("run/main_scene", "").strip('"')
    if not main_scene:
        fail("в project.godot не задана главная сцена")
    elif not (ROOT / main_scene.replace("res://", "")).exists():
        fail(f"главная сцена не найдена: {main_scene}")

    for name, value in autoload.items():
        path = value.strip('"').lstrip("*")
        if path.startswith("res://") and not (ROOT / path.replace("res://", "")).exists():
            fail(f"autoload {name} указывает на несуществующий скрипт: {path}")
    if "Game" not in autoload:
        fail("нет autoload Game — состояние игры не сохранится между сценами")

    orientation = display.get("window/handheld/orientation", "")
    if orientation != "1":
        fail(f"ориентация {orientation or 'не задана'} — по ТЗ игра вертикальная (портрет, значение 1)")
    width = display.get("window/size/viewport_width", "")
    height = display.get("window/size/viewport_height", "")
    if (width, height) != ("720", "1280"):
        fail(f"разрешение viewport {width}x{height}: для телефона 720p нужен портретный 720x1280")

    renderer = project_settings(text, "rendering").get("renderer/rendering_method", "")
    if renderer != "gl_compatibility":
        print(f"  примечание: рендерер {renderer} (по умолчанию ожидается gl_compatibility)")


def strip_comments(text: str, prefix: str) -> str:
    """Убирает комментарии, чтобы ссылки в них не считались ссылками кода."""
    lines = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(prefix):
            continue
        in_string = False
        quote = ""
        out = []
        for index, char in enumerate(line):
            if in_string:
                if char == quote and line[index - 1] != "\\":
                    in_string = False
            elif char in "\"'":
                in_string = True
                quote = char
            elif char == prefix:
                break
            out.append(char)
        lines.append("".join(out))
    return "\n".join(lines)


def check_resource_paths() -> None:
    """Ищет статические ссылки на несуществующие ресурсы в коде и сценах.

    Комментарии и «мягкие» ссылки в строках вида `res://data/resources/x.tres`
    без файла на диске не считаются ошибкой: часть ресурсов (пресеты графики)
    подгружается через `ResourceLoader.exists()` и имеет значение по умолчанию,
    если файла нет.
    """
    pattern = re.compile(r'res://([A-Za-z0-9_./\-]+\.(?:tscn|tres|gd|png|svg|json|ogg|wav|ttf))')
    checked = 0
    missing = 0
    skip_dirs = {".godot", ".git", "build", "art_source"}
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or path.suffix not in {".tscn", ".tres", ".gd", ".cfg", ".godot"}:
            continue
        if any(part in skip_dirs for part in path.parts):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        text = strip_comments(text, ";" if path.suffix in {".tscn", ".tres", ".cfg", ".godot"} else "#")
        for match in pattern.finditer(text):
            checked += 1
            if (ROOT / match.group(1)).exists():
                continue
            # Ссылки на сгенерированные во время импорта файлы (.import) тоже валидны.
            if (ROOT / f"{match.group(1)}.import").exists():
                continue
            missing += 1
            fail(f"{path.relative_to(ROOT)} ссылается на отсутствующий ресурс res://{match.group(1)}")
    print(f"  статических ссылок на ресурсы: {checked}, отсутствующих: {missing}")


def check_export_preset() -> None:
    if not PRESET.exists():
        fail("нет export_presets.cfg — APK нельзя собрать из командной строки")
        return
    text = PRESET.read_text(encoding="utf-8")
    values = dict(re.findall(r'^([A-Za-z0-9_/.-]+)=(.*)$', text, re.MULTILINE))

    package = values.get("package/unique_name", "").strip('"')
    if not package or "$genname" in package or package == "com.example":
        fail(f"не задано уникальное имя пакета: {package!r}")
    elif not re.fullmatch(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+", package):
        fail(f"имя пакета {package} не похоже на корректный applicationId")

    if values.get("architectures/arm64-v8a", "false") != "true":
        fail("в пресете не включена архитектура arm64-v8a (её требует телефон игрока)")
    for abi in ("armeabi-v7a", "x86", "x86_64"):
        if values.get(f"architectures/{abi}", "false") == "true":
            fail(f"лишняя архитектура {abi}: APK станет больше без пользы")
    if values.get("gradle_build/export_format", "0") != "0":
        fail("формат экспорта не APK (ТЗ: основной артефакт — APK)")
    if values.get("screen/immersive_mode", "true") != "true":
        fail("не включён immersive mode — на телефоне останутся системные панели")
    for key, value in values.items():
        if key.startswith("permissions/") and key != "permissions/custom_permissions" and value == "true":
            fail(f"выставлено разрешение {key}: игра работает без разрешений")


def check_tests_have_cases() -> None:
    for directory in ("tests/unit", "tests/integration"):
        for path in sorted((ROOT / directory).glob("test_*.gd")):
            text = path.read_text(encoding="utf-8")
            if not re.search(r"^func test_[a-z0-9_]+\(", text, re.MULTILINE):
                fail(f"{path.relative_to(ROOT)} не содержит ни одного метода test_*")
            # Тест обязан проверять конкретное свойство, а не «истинность истины»:
            # в файле должен быть хотя бы один сравнивающий assert.
            if not re.search(r"assert_(gt|ge|lt|le|eq|ne|almost_eq|between|vector_almost_eq)\(", text):
                fail(f"{path.relative_to(ROOT)} не сравнивает значения (только assert_true/false)")


def main() -> int:
    print("=== Проверка проекта ===")
    check_project()
    check_resource_paths()
    check_export_preset()
    check_tests_have_cases()
    if problems:
        print(f"ПРОБЛЕМ: {len(problems)}")
        return 1
    print("все проверки пройдены")
    return 0


if __name__ == "__main__":
    sys.exit(main())
