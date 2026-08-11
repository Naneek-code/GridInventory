#!/usr/bin/env bash
# run_tests.sh — roda todas as suites de teste do GridInventory.
# Usa Lua 5.1.5 (mesmo major do Kahlua do PZ). Se não existir, baixa e compila.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_BASE="$(dirname "$SCRIPT_DIR")"

LUA_DIR="/tmp/lua-5.1.5"
LUA_BIN="$LUA_DIR/src/lua"
LUAC_BIN="$LUA_DIR/src/luac"

# 1) Garante o Lua 5.1.5 (volátil no /tmp; recompila se sumir).
if [ ! -x "$LUA_BIN" ] || [ ! -x "$LUAC_BIN" ]; then
    echo "[tests] construindo Lua 5.1.5..."
    cd /tmp
    if [ ! -f lua-5.1.5.tar.gz ]; then
        curl -sSL -o lua-5.1.5.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz
    fi
    rm -rf "$LUA_DIR"
    tar xzf lua-5.1.5.tar.gz
    cd "$LUA_DIR"
    make posix >/dev/null 2>&1
    cd "$MOD_BASE"
fi

# 2) Syntax-check de TODAS as .lua do mod (client + shared).
echo "[tests] syntax check (luac -p)..."
ok=1
while IFS= read -r f; do
    if ! "$LUAC_BIN" -p "$f" >/dev/null 2>&1; then
        echo "  FALHOU: $f"
        "$LUAC_BIN" -p "$f" 2>&1 | head -3
        ok=0
    fi
done < <(find "$MOD_BASE/42.20/media/lua" "$MOD_BASE/common/media/lua" -name "*.lua" | sort)
if [ "$ok" -eq 1 ]; then
    echo "  todas compilam"
else
    echo "[tests] ERRO de sintaxe. Abortando."
    exit 1
fi

# 3) Roda cada suite num processo Lua separado.
echo "[tests] rodando suites..."
FAILED_TESTS=()
for t in "$SCRIPT_DIR"/*_test.lua; do
    name="$(basename "$t")"
    if [ "$name" = "harness.lua" ]; then continue; fi
    if GRID_MOD_BASE="$MOD_BASE" LUA_PATH="$SCRIPT_DIR/?.lua;;" "$LUA_BIN" "$t"; then
        :
    else
        FAILED_TESTS+=("$name")
    fi
done

if [ "${#FAILED_TESTS[@]}" -gt 0 ]; then
    echo "[tests] suites FALHARAM: ${FAILED_TESTS[*]}"
    exit 1
fi
echo "[tests] TODAS as suites passaram"
