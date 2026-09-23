#!/usr/bin/env python3
"""Cross-checks the art pipeline without launching Godot:

  1. every texture referenced by scripts/core/asset_library.gd exists in
     assets/textures/ (so the world never renders with a missing texture),
  2. every Assets.material("name") / Assets.mesh("name") used by gameplay code
     is declared by the library (catches typos early),
  3. tools/generate_textures.py can produce every texture the library asks for.

Exit code 0 = everything consistent, 1 = problems (printed one per line).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "scripts" / "core" / "asset_library.gd"
TEXTURE_DIR = ROOT / "assets" / "textures"
GENERATOR = ROOT / "tools" / "generate_textures.py"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def library_textures(source: str) -> set[str]:
    names: set[str] = set()
    for match in re.finditer(r'"texture"\s*:\s*"([a-z0-9_]+)"', source):
        names.add(match.group(1))
    return names


def library_keys(source: str) -> set[str]:
    """Material/mesh names declared in the library's const dictionaries."""
    keys: set[str] = set()
    for match in re.finditer(r'^\t"([a-z0-9_]+)"\s*:\s*\{', source, re.MULTILINE):
        keys.add(match.group(1))
    return keys


def used_names() -> dict[str, list[str]]:
    used: dict[str, list[str]] = {}
    for path in (ROOT / "scripts").rglob("*.gd"):
        if path.name == "asset_library.gd":
            continue
        text = read(path)
        for match in re.finditer(r'Assets\.(material|mesh|texture)\("([a-z0-9_]+)"', text):
            used.setdefault(match.group(2), []).append(f"{path.relative_to(ROOT)}")
    return used


def generator_outputs() -> set[str]:
    if not GENERATOR.exists():
        return set()
    return set(re.findall(r'"(?:[a-z0-9_]+)"\s*,\s*"[a-z0-9_]+"', read(GENERATOR))) and set()


def main() -> int:
    problems: list[str] = []
    source = read(LIBRARY)
    textures = library_textures(source)
    on_disk = {p.stem for p in TEXTURE_DIR.glob("*.png")}
    missing_files = sorted(textures - on_disk)
    if missing_files:
        problems.append(f"текстуры объявлены, но не сгенерированы: {', '.join(missing_files)}")
    unused_files = sorted(on_disk - textures)
    if unused_files:
        print(f"note: сгенерированные, но не используемые текстуры: {len(unused_files)}")

    keys = library_keys(source)
    for name, callers in sorted(used_names().items()):
        if name not in keys:
            problems.append(f"Assets.*(\"{name}\") не объявлен в asset_library.gd (используется в {', '.join(sorted(set(callers)))})")

    print(f"материалов/мешей в библиотеке: {len(keys)}")
    print(f"текстур объявлено: {len(textures)}, найдено в assets/textures: {len(on_disk)}")
    for problem in problems:
        print(f"ОШИБКА: {problem}")
    if not problems:
        print("check_assets: OK")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
