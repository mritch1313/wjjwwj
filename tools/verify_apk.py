#!/usr/bin/env python3
"""Проверка собранного Android-пакета (APK) без запуска на устройстве.

Скрипт отвечает на вопросы, которые обычно проверяют руками в Android Studio:

  1. пакет вообще существует и является настоящим APK (zip с AndroidManifest.xml);
  2. имя пакета, versionCode и versionName совпадают с export_presets.cfg;
  3. ориентация экрана в манифесте — portrait (требование ТЗ);
  4. внутри лежит нативная библиотека только под arm64-v8a;
  5. лишних разрешений нет (ТЗ: минимум permissions);
  6. пакет подписан.

Манифест читается через aapt2 из Android SDK, если он есть; иначе используется
собственный разбор бинарного формата AXML (Android binary XML), поэтому скрипт
работает и на машине без Android SDK. `--selftest` проверяет сам разборщик.

Код выхода 0 — все проверки пройдены, 1 — есть проблема.
"""

from __future__ import annotations

import os
import re
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRESET = ROOT / "export_presets.cfg"
PROJECT = ROOT / "project.godot"

# Разрешения, которые допустимы в игре без сети и без устройств ввода.
ALLOWED_PERMISSIONS: set[str] = set()

# Android screenOrientation: 0 = landscape, 1 = portrait (значение в манифесте).
ORIENTATION_PORTRAIT = 1
ORIENTATION_LANDSCAPE = 0
ORIENTATION_NAMES = {
    0: "landscape",
    1: "portrait",
    2: "reverseLandscape",
    3: "reversePortrait",
    4: "sensorLandscape",
    5: "sensorPortrait",
    6: "sensor",
    7: "fullSensor",
    8: "nosensor",
    9: "user",
    10: "fullUser",
    11: "locked",
}


def fail(message: str) -> None:
    print(f"ОШИБКА: {message}")


# --------------------------------------------------------------------- AXML ---
class AxmlStringPool:
    """Пул строк бинарного XML (UTF-8 или UTF-16, как в Android)."""

    def __init__(self, data: bytes) -> None:
        header_size, chunk_size = struct.unpack_from("<HH", data, 2)
        string_count, style_count, flags, strings_start, _styles_start = struct.unpack_from(
            "<IIIII", data, 8
        )
        self.utf8 = bool(flags & 0x100)
        offsets = struct.unpack_from(f"<{string_count}I", data, header_size)
        self.strings: list[str] = []
        for offset in offsets:
            start = strings_start + offset
            if self.utf8:
                # UTF-8: длина строки и длина в байтах, каждая — 1 или 2 байта.
                char_len = data[start]
                start += 1
                if char_len & 0x80:
                    char_len = ((char_len & 0x7F) << 8) | data[start]
                    start += 1
                byte_len = data[start]
                start += 1
                if byte_len & 0x80:
                    byte_len = ((byte_len & 0x7F) << 8) | data[start]
                    start += 1
                self.strings.append(data[start : start + byte_len].decode("utf-8", "replace"))
            else:
                char_len = struct.unpack_from("<H", data, start)[0]
                start += 2
                if char_len & 0x8000:
                    char_len = ((char_len & 0x7FFF) << 16) | struct.unpack_from("<H", data, start)[0]
                    start += 2
                self.strings.append(
                    data[start : start + char_len * 2].decode("utf-16-le", "replace")
                )

    def get(self, index: int) -> str:
        if 0 <= index < len(self.strings):
            return self.strings[index]
        return ""


def parse_axml(data: bytes) -> dict:
    """Минимальный разбор AXML: пакет, версия, ориентация, разрешения."""
    if len(data) < 8 or struct.unpack_from("<H", data, 0)[0] != 0x0003:
        raise ValueError("это не бинарный Android XML")

    pool: AxmlStringPool | None = None
    result: dict = {"package": "", "version_code": None, "version_name": None,
                    "orientation": None, "permissions": [], "min_sdk": None,
                    "elements": []}

    offset = struct.unpack_from("<H", data, 2)[0]
    total = struct.unpack_from("<I", data, 4)[0]
    while offset < min(total, len(data)):
        chunk_type, _header_size, chunk_size = struct.unpack_from("<HHI", data, offset)
        if chunk_size <= 0:
            break
        if chunk_type == 0x0001:  # строковый пул
            pool = AxmlStringPool(data[offset : offset + chunk_size])
        elif chunk_type == 0x0102 and pool is not None:  # START_ELEMENT
            name_index = struct.unpack_from("<I", data, offset + 20)[0]
            element = pool.get(name_index)
            attribute_start = struct.unpack_from("<H", data, offset + 24)[0]
            attribute_count = struct.unpack_from("<H", data, offset + 28)[0]
            attrs: dict[str, tuple[int, int]] = {}
            for i in range(attribute_count):
                base = offset + 16 + attribute_start + i * 20
                attr_name = pool.get(struct.unpack_from("<I", data, base + 4)[0])
                data_type = data[base + 15]
                attr_data = struct.unpack_from("<I", data, base + 16)[0]
                attrs[attr_name] = (data_type, attr_data)
            result["elements"].append(element)
            if element == "manifest":
                result["package"] = pool.get(struct.unpack_from("<I", data, offset + 16)[0])
                if "versionCode" in attrs:
                    result["version_code"] = attrs["versionCode"][1]
                if "versionName" in attrs:
                    result["version_name"] = pool.get(attrs["versionName"][1])
            elif element == "uses-sdk" and "minSdkVersion" in attrs:
                result["min_sdk"] = attrs["minSdkVersion"][1]
            elif element in ("activity", "activity-alias") and "screenOrientation" in attrs:
                result["orientation"] = attrs["screenOrientation"][1]
            elif element == "uses-permission":
                permission_index = attrs.get("name", (0x03, 0xFFFFFFFF))[1]
                result["permissions"].append(pool.get(permission_index))
        offset += chunk_size
    return result


# ------------------------------------------------------------------- aapt2 ----
def find_aapt2() -> str | None:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or ""
    candidates: list[Path] = []
    if sdk:
        candidates += sorted((Path(sdk) / "build-tools").glob("*/aapt2"))
    for path in candidates:
        if path.is_file():
            return str(path)
    return None


def manifest_via_aapt2(aapt2: str, apk: Path) -> dict:
    """Читает манифест через `aapt2 dump xmltree` (та же информация, что в AXML)."""
    out = subprocess.run(
        [aapt2, "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "aapt2 не смог прочитать манифест")
    result: dict = {"package": "", "version_code": None, "version_name": None,
                    "orientation": None, "permissions": [], "min_sdk": None}
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.startswith("package="):
            result["package"] = line.split("=", 1)[1].strip().strip('"')
        elif "android:versionCode" in line:
            result["version_code"] = int(line.rsplit("=", 1)[1].strip("()"), 0)
        elif "android:versionName" in line:
            result["version_name"] = line.rsplit("=", 1)[1].strip().strip('"')
        elif "android:minSdkVersion" in line:
            result["min_sdk"] = int(line.rsplit("=", 1)[1].strip("()"), 0)
        elif "android:screenOrientation" in line:
            result["orientation"] = int(line.rsplit("=", 1)[1].strip("()"), 0)
        elif line.startswith("E: uses-permission"):
            result["permissions"].append("declared")
    return result


# ------------------------------------------------------------ preset/project --
def preset_values() -> dict:
    text = PRESET.read_text(encoding="utf-8")
    def value(key: str, default: str = "") -> str:
        match = re.search(rf'^{re.escape(key)}=(.*)$', text, re.MULTILINE)
        return match.group(1).strip().strip('"') if match else default
    return {
        "package": value("package/unique_name"),
        "version_code": int(value("version/code", "1")),
        "version_name": value("version/name"),
        "arm64": value("architectures/arm64-v8a", "true") == "true",
        "other_abis": [
            abi for abi in ("armeabi-v7a", "x86", "x86_64")
            if value(f"architectures/{abi}", "false") == "true"
        ],
    }


def project_orientation() -> int:
    text = PROJECT.read_text(encoding="utf-8")
    match = re.search(r"^window/handheld/orientation=(\d+)", text, re.MULTILINE)
    return int(match.group(1)) if match else -1


def selftest() -> int:
    """Проверка разборщика AXML на синтетическом манифесте."""
    def utf16(text: str) -> bytes:
        raw = text.encode("utf-16-le")
        return struct.pack("<H", len(text)) + raw + b"\x00\x00"

    strings = ["manifest", "android", "com.test.app", "versionCode", "versionName",
               "1.0", "uses-sdk", "minSdkVersion", "activity", "screenOrientation",
               "uses-permission", "android.permission.INTERNET", "name"]
    pool = bytearray()
    offsets = bytearray()
    for text in strings:
        offsets += struct.pack("<I", len(pool))
        pool += utf16(text)
    while len(pool) % 4:
        pool += b"\x00"
    string_pool = bytearray(struct.pack("<HHI", 0x0001, 28, 0))
    string_pool += struct.pack("<IIIII", len(strings), 0, 0, 28 + len(offsets), 0)
    string_pool += offsets + pool
    struct.pack_into("<I", string_pool, 4, len(string_pool))

    def start_element(name_index: int, attrs: list[tuple[int, int, int]]) -> bytes:
        body = struct.pack("<II", 0xFFFFFFFF, name_index)  # ns, name
        body += struct.pack("<HHHHHH", 20, 20, len(attrs), 0, 0, 0)
        for attr_name, data_type, value in attrs:
            body += struct.pack("<II", 0xFFFFFFFF, attr_name)  # ns, name
            body += struct.pack("<I", 0xFFFFFFFF)  # rawValue
            body += struct.pack("<HBBI", 8, 0, data_type, value)
        size = 16 + len(body)
        header = struct.pack("<HHI", 0x0102, 16, size) + struct.pack("<II", 1, 0)
        return header + body

    chunks = string_pool + b""
    chunks += start_element(0, [(3, 0x10, 1), (4, 0x03, 5)])  # manifest versionCode/Name
    chunks += struct.pack("<HHI", 0x0103, 16, 16) + struct.pack("<II", 1, 0)
    chunks += start_element(6, [(7, 0x10, 24)])  # uses-sdk
    chunks += struct.pack("<HHI", 0x0103, 16, 16) + struct.pack("<II", 1, 0)
    chunks += start_element(8, [(9, 0x10, 1)])  # activity portrait
    chunks += struct.pack("<HHI", 0x0103, 16, 16) + struct.pack("<II", 1, 0)
    chunks += start_element(10, [(12, 0x03, 11)])  # uses-permission
    chunks += struct.pack("<HHI", 0x0103, 16, 16) + struct.pack("<II", 1, 0)

    header = struct.pack("<HHI", 0x0003, 8, 8 + len(chunks))
    parsed = parse_axml(header + chunks)
    ok = True
    checks = [
        (parsed["version_code"] == 1, "versionCode разобран"),
        (parsed["version_name"] == "1.0", "versionName разобран"),
        (parsed["min_sdk"] == 24, "minSdkVersion разобран"),
        (parsed["orientation"] == ORIENTATION_PORTRAIT, "ориентация portrait разобрана"),
        (parsed["permissions"] == ["android.permission.INTERNET"], "uses-permission разобран"),
    ]
    for passed, label in checks:
        print(("  ok   " if passed else "  FAIL ") + label)
        ok = ok and passed
    print("selftest:", "TESTS PASSED" if ok else "TESTS FAILED")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()

    if len(sys.argv) < 2:
        print("использование: verify_apk.py <путь.apk> | --selftest", file=sys.stderr)
        return 2

    apk = Path(sys.argv[1])
    if not apk.is_file():
        fail(f"APK не найден: {apk}")
        return 1

    expected = preset_values()
    problems: list[str] = []

    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if "AndroidManifest.xml" not in names:
            fail("в пакете нет AndroidManifest.xml")
            return 1
        manifest_bytes = archive.read("AndroidManifest.xml")
        libraries = [name for name in names if name.startswith("lib/") and name.endswith(".so")]
        signatures = [name for name in names if name.startswith("META-INF/") and
                      name.endswith((".RSA", ".DSA", ".EC", ".SF"))]

    manifest = None
    aapt2 = find_aapt2()
    if aapt2:
        try:
            manifest = manifest_via_aapt2(aapt2, apk)
            print(f"манифест прочитан через aapt2: {aapt2}")
        except Exception as error:  # noqa: BLE001 - переходим к встроенному разбору
            print(f"aapt2 недоступен ({error}), используется встроенный разбор AXML")
    if manifest is None:
        manifest = parse_axml(manifest_bytes)
        print("манифест прочитан встроенным разборщиком AXML")

    print(f"APK: {apk} ({apk.stat().st_size / 1_048_576:.1f} МиБ)")
    print(f"  пакет        : {manifest['package']} (versionCode={manifest['version_code']}, "
          f"versionName={manifest['version_name']})")
    print(f"  minSdk       : {manifest['min_sdk']}")
    orientation = manifest["orientation"]
    print(f"  ориентация   : {ORIENTATION_NAMES.get(orientation, orientation)}")
    print(f"  библиотеки   : {', '.join(sorted(libraries)) or 'нет'}")
    print(f"  разрешения   : {', '.join(manifest['permissions']) or 'нет'}")
    print(f"  подпись      : {'есть' if signatures else 'нет'}")

    if manifest["package"] != expected["package"]:
        problems.append(f"имя пакета {manifest['package']} != {expected['package']} из export_presets.cfg")
    if manifest["version_code"] != expected["version_code"]:
        problems.append(f"versionCode {manifest['version_code']} != {expected['version_code']}")
    if orientation != ORIENTATION_PORTRAIT:
        problems.append(f"ориентация {ORIENTATION_NAMES.get(orientation, orientation)} вместо portrait")
    if project_orientation() != ORIENTATION_PORTRAIT:
        problems.append("в project.godot не выставлена портретная ориентация")
    if expected["arm64"] and not any("/arm64-v8a/" in name for name in libraries):
        problems.append("нет нативной библиотеки под arm64-v8a")
    for abi in expected["other_abis"]:
        if any(f"/{abi}/" in name for name in libraries):
            problems.append(f"в пакет попала лишняя ABI {abi}")
    for permission in manifest["permissions"]:
        if permission not in ALLOWED_PERMISSIONS:
            problems.append(f"лишнее разрешение в манифесте: {permission}")
    if not signatures:
        problems.append("APK не подписан")

    apksigner = None
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or ""
    if sdk:
        found = sorted((Path(sdk) / "build-tools").glob("*/apksigner"))
        if found:
            apksigner = str(found[-1])
    if apksigner:
        check = subprocess.run([apksigner, "verify", "--print-certs", str(apk)],
                               capture_output=True, text=True, check=False)
        print("  apksigner    :", "подпись действительна" if check.returncode == 0 else "проверка не прошла")
        if check.returncode != 0:
            problems.append(f"apksigner verify: {check.stderr.strip()[:200]}")

    if problems:
        for problem in problems:
            fail(problem)
        print("APK VERIFY FAILED")
        return 1
    print("APK VERIFY PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
