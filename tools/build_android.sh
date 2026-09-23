#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Head-less сборка Android-пакета игры (APK или AAB) без графической оболочки.
#
# Используется и в CI (.github/workflows/ci.yml), и локально на машине
# разработчика — один и тот же путь сборки, чтобы «в CI собирается, локально
# нет» не случалось.
#
# Требуется:
#   * GODOT_BIN          — путь к редактору Godot 4.7.2 (по умолчанию `godot`);
#   * ~/.local/share/godot/export_templates/4.7.2.stable/ — шаблоны экспорта
#     (android_debug.apk, android_release.apk) из Godot_v4.7.2-stable_export_templates.tpz;
#   * ANDROID_HOME       — Android SDK с build-tools (apksigner, zipalign);
#   * JAVA_HOME          — JDK (keytool + apksigner);
#   * для подписанного release — GODOT_ANDROID_KEYSTORE_RELEASE_{PATH,USER,PASSWORD}.
#
# Использование:
#   tools/build_android.sh                 # release APK в build/android/
#   tools/build_android.sh release aab     # release AAB
#   tools/build_android.sh debug apk       # debug APK
# ---------------------------------------------------------------------------
set -euo pipefail

MODE="${1:-release}"
FORMAT="${2:-apk}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/build/android}"
PRESET="${PRESET:-Android}"
GODOT_BIN="${GODOT_BIN:-godot}"

cd "$PROJECT_DIR"

if ! command -v "$GODOT_BIN" >/dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
	echo "ОШИБКА: редактор Godot не найден: $GODOT_BIN (задайте GODOT_BIN)" >&2
	exit 2
fi

if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
	echo "ОШИБКА: не задан ANDROID_HOME/ANDROID_SDK_ROOT — без Android SDK экспорт невозможен" >&2
	exit 2
fi
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

if [ ! -d "$ANDROID_HOME/build-tools" ]; then
	echo "ОШИБКА: в $ANDROID_HOME нет build-tools (нужны apksigner и zipalign)" >&2
	exit 2
fi

# Каталог шаблонов экспорта зависит от версии движка — берём её у самого Godot,
# чтобы путь не разъехался с версией бинарника.
VERSION="$("$GODOT_BIN" --version | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
TEMPLATES_DIR="${GODOT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/${VERSION}.stable}"
if [ ! -f "$TEMPLATES_DIR/android_release.apk" ] && [ ! -f "$TEMPLATES_DIR/android_debug.apk" ]; then
	echo "ОШИБКА: не найдены шаблоны экспорта Android в $TEMPLATES_DIR" >&2
	echo "        (Godot_v${VERSION}-stable_export_templates.tpz -> export_templates/${VERSION}.stable/)" >&2
	exit 2
fi

EXT="$FORMAT"
[ "$FORMAT" = "aab" ] && EXT="aab"
TARGET="$OUT_DIR/chase-open-world-${MODE}.${EXT}"
mkdir -p "$OUT_DIR"

echo "=== 1/4 Импорт ресурсов (headless) ==="
"$GODOT_BIN" --headless --path . --import 2>&1 | tee /tmp/godot_import.log | tail -2
if grep -q "SCRIPT ERROR" /tmp/godot_import.log; then
	echo "ОШИБКА: при импорте есть ошибки скриптов:" >&2
	grep -A 2 "SCRIPT ERROR" /tmp/godot_import.log >&2
	exit 1
fi

echo "=== 2/4 Экспорт Android ($PRESET, режим $MODE, формат $FORMAT) ==="
rm -f "$TARGET"
set +e
"$GODOT_BIN" --headless --path . "--export-$MODE" "$PRESET" "$TARGET" 2>&1 | tee /tmp/godot_export.log | tail -20
EXPORT_STATUS=${PIPESTATUS[0]}
set -e

if [ ! -f "$TARGET" ]; then
	echo "ОШИБКА: пакет не создан ($TARGET), код выхода Godot: $EXPORT_STATUS" >&2
	tail -40 /tmp/godot_export.log >&2
	exit 1
fi

echo "=== 3/4 Проверка пакета ==="
ls -lh "$TARGET"
if [ "$EXT" = "apk" ]; then
	APKSIGNER="$(find "$ANDROID_HOME/build-tools" -name apksigner -type f | sort -V | tail -1)"
	"$APKSIGNER" verify --print-certs "$TARGET" >/dev/null && echo "подпись APK проверена"
	unzip -l "$TARGET" | grep -E "AndroidManifest.xml|lib/arm64-v8a/libgodot" | sed 's/^/  /'
fi

echo "=== 4/4 Готово: $TARGET ==="
