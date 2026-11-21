#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
SYSROOT_LIB="${SYSROOT_LIB:-${WORKSPACE_DIR}/sysroot}"
SDL2_INSTALL="${SDL2_INSTALL:-${WORKSPACE_DIR}/sdl2-install}"
JOBS="${JOBS:-4}"
MAX_GLIBC="${MAX_GLIBC:-2.30}"
MC3_PATCH_STRICT="${MC3_PATCH_STRICT:-0}"
MC3_SKIP_PATCHES="${MC3_SKIP_PATCHES:-}"

echo "== Git & Submodule Init =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates
git --version
git config --global --add safe.directory '*'

if [ ! -e .git ]; then
  echo "Kein .git-Verzeichnis gefunden. Initialisiere Git-Workspace..."
  git init -q
  git config user.name "CI Builder"
  git config user.email "ci@localhost"
  git add -A
  git commit -q -m "Workspace snapshot" || true
fi

if [ -f .gitmodules ]; then
  git submodule sync --recursive || true
  git submodule update --init --recursive || true
fi

if [ ! -f external/xport/xport.cmake ]; then
  echo "external/xport/xport.cmake fehlt noch - klone https://github.com/SickSartori/xport.git..."
  rm -rf external/xport
  mkdir -p external
  git clone --recursive https://github.com/SickSartori/xport.git external/xport
fi

test -f external/xport/xport.cmake
echo "Gefunden: external/xport/xport.cmake"

echo "== Repo Structure =="
ls -la
ls -la patches/ 2>/dev/null || true
ls -la scripts/ 2>/dev/null || true
ls -la cmake/ 2>/dev/null || true
ls -la external/xport 2>/dev/null || true

echo "== Enable aarch64 Multiarch =="
dpkg --add-architecture arm64
cp /etc/apt/sources.list /etc/apt/sources.list.bak
sed -i -E 's/^deb (\[[^]]*\] )?http/deb [arch=amd64] http/' /etc/apt/sources.list
cat > /etc/apt/sources.list.d/arm64.list <<'EOF'
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main universe
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main universe
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-security main universe
EOF
apt-get update

echo "== Install CMake 3.28.3 =="
apt-get install -y --no-install-recommends wget ca-certificates
wget -q https://github.com/Kitware/CMake/releases/download/v3.28.3/cmake-3.28.3-linux-x86_64.tar.gz
tar -xzf cmake-3.28.3-linux-x86_64.tar.gz -C /opt
ln -sf /opt/cmake-3.28.3-linux-x86_64/bin/cmake /usr/local/bin/cmake
ln -sf /opt/cmake-3.28.3-linux-x86_64/bin/ctest /usr/local/bin/ctest
ln -sf /opt/cmake-3.28.3-linux-x86_64/bin/cpack /usr/local/bin/cpack
rm -f cmake-3.28.3-linux-x86_64.tar.gz
cmake --version

echo "== Install Native & aarch64 Build Dependencies =="
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential ninja-build git curl wget ca-certificates \
  pkg-config python3 python3-pip file patchelf \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  unzip p7zip-full libarchive-tools zstd xz-utils

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  libdrm-dev:arm64 libgbm-dev:arm64 libegl-dev:arm64 \
  libgles2-mesa-dev:arm64 libasound2-dev:arm64 libudev-dev:arm64 \
  libarchive-dev:arm64 zlib1g-dev:arm64 libbz2-dev:arm64 \
  liblzma-dev:arm64 libzstd-dev:arm64 liblz4-dev:arm64 \
  libwayland-dev:arm64 libpulse-dev:arm64 libxkbcommon-dev:arm64

echo "== Setup Cross-Sysroot =="
if [ -f scripts/ci-setup-sysroot.sh ]; then
  bash scripts/ci-setup-sysroot.sh
else
  mkdir -p "${SYSROOT_LIB}/lib" "${SYSROOT_LIB}/include" "${SYSROOT_LIB}/pkgconfig"
  for d in /usr/lib/aarch64-linux-gnu/pkgconfig /usr/share/pkgconfig; do
    [ -d "$d" ] && cp -rn "$d"/* "${SYSROOT_LIB}/pkgconfig/" 2>/dev/null || true
  done
fi

echo "== Build SDL2 (KMSDRM + ALSA) for aarch64 =="
if [ -f scripts/ci-build-sdl2.sh ]; then
  bash scripts/ci-build-sdl2.sh
else
  SDL2_VER="2.30.10"
  mkdir -p /tmp/sdl2-src /tmp/sdl2-build "${SDL2_INSTALL}"
  wget -q -O /tmp/sdl2.tar.gz "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VER}/SDL2-${SDL2_VER}.tar.gz"
  tar -xzf /tmp/sdl2.tar.gz -C /tmp/sdl2-src --strip-components=1
  cmake -S /tmp/sdl2-src -B /tmp/sdl2-build -G Ninja \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
    -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
    -DCMAKE_C_FLAGS="-mcpu=cortex-a35 -mtune=cortex-a35 -O2 -pipe" \
    -DCMAKE_INSTALL_PREFIX="${SDL2_INSTALL}" \
    -DSDL_STATIC=OFF \
    -DSDL_SHARED=ON \
    -DSDL_KMSDRM=ON \
    -DSDL_ALSA=ON \
    -DSDL_OPENGLES=ON \
    -DSDL_X11=OFF \
    -DSDL_WAYLAND=OFF
  cmake --build /tmp/sdl2-build -j "${JOBS}"
  cmake --install /tmp/sdl2-build
  rm -rf /tmp/sdl2.tar.gz /tmp/sdl2-src /tmp/sdl2-build
fi

echo "== Stubs (libmali, libdecor) =="
if [ -f scripts/ci-build-stubs.sh ]; then
  bash scripts/ci-build-stubs.sh
else
  mkdir -p "${SYSROOT_LIB}/lib" "${SYSROOT_LIB}/include"
fi

echo "== Generate RK3326 Toolchain =="
mkdir -p "${WORKSPACE_DIR}/cmake"
if [ ! -f "${WORKSPACE_DIR}/cmake/aarch64-arkos.cmake" ]; then
  cat > "${WORKSPACE_DIR}/cmake/aarch64-arkos.cmake" <<'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_AR aarch64-linux-gnu-ar)
set(CMAKE_RANLIB aarch64-linux-gnu-ranlib)
set(CMAKE_STRIP aarch64-linux-gnu-strip)

set(RK3326_ARCH_FLAGS "-mcpu=cortex-a35 -mtune=cortex-a35 -pipe")
set(CMAKE_C_FLAGS_INIT "${RK3326_ARCH_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${RK3326_ARCH_FLAGS}")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
fi

echo "== Repair Patch Entrypoints =="
for f in patches/mc3-*.py mc3-*.py; do
  [ -f "$f" ] || continue
  if grep -qE '^def main\(' "$f" && ! grep -qE '__main__|^main\(\)' "$f"; then
    printf '\n\nif __name__ == "__main__":\n    main()\n' >> "$f"
    echo "Repaired main() guard in: $f"
  fi
done

echo "== Apply Patches =="
: > patch.log

find_script() {
  local name="$1"
  if [ -f "patches/$name" ]; then echo "patches/$name"
  elif [ -f "$name" ];      then echo "$name"
  else echo ""; fi
}

tree_hash() {
  find . -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.c' \
                    -o -name '*.cmake' -o -name '*.ini' \) \
    -not -path './.git/*' -not -path './build/*' -not -path './sysroot/*' \
    -not -path './sdl2-install/*' -not -path './dist/*' -not -path './patched-sources/*' \
    -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16
}

apply() {
  local name="$1" target="$2" S h1 h2 rc
  if [ -n "${MC3_SKIP_PATCHES}" ]; then
    case ",${MC3_SKIP_PATCHES// /}," in
      *",$name,"*|*",${name%.py},"*)
        echo "== patches/$name == SKIPPED (skip_patches)" | tee -a patch.log
        return 0 ;;
    esac
  fi
  S=$(find_script "$name")
  if [ -z "$S" ]; then
    echo "PATCH-WARNUNG: $name FEHLT" | tee -a patch.log
    return 0
  fi
  echo "== $S ==" | tee -a patch.log
  h1=$(tree_hash)
  rc=0
  python3 -u "$S" "$target" 2>&1 | tee -a patch.log || rc=$?
  [ "$rc" -ne 0 ] && echo "PATCH-FEHLER: $name Exit-Code $rc" | tee -a patch.log
  h2=$(tree_hash)
  [ "$h1" = "$h2" ] && echo "PATCH-WARNUNG: $name hat NICHTS veraendert" | tee -a patch.log
}

if [ -n "$(find_script mc3-linux-cmake.py)" ]; then
  apply mc3-linux-cmake.py CMakeLists.txt
else
  python3 -c '
from pathlib import Path
cm = Path("CMakeLists.txt")
txt = cm.read_text(encoding="utf-8")
marker = "# RK3326 / Linux aarch64 port target"
if marker not in txt:
    snippet = (
        "\n" + marker + "\n"
        "if(NOT WIN32 AND CMAKE_SYSTEM_PROCESSOR MATCHES \"^(aarch64|arm64)$\")\n"
        "    if(TARGET xportcore)\n"
        "        add_executable(mc3port_rk3326 src/pc/game_disc.cpp)\n"
        "        target_link_libraries(mc3port_rk3326 PRIVATE xportcore)\n"
        "        target_include_directories(mc3port_rk3326 PRIVATE src ${XPORT_DIR}/src)\n"
        "        target_compile_definitions(mc3port_rk3326 PRIVATE RK3326_PORT=1)\n"
        "        xport_identity(mc3port_rk3326 mc3port MC3PORT MC3_)\n"
        "    endif()\n"
        "endif()\n"
    )
    cm.write_text(txt + snippet, encoding="utf-8")
    print("CMakeLists.txt updated for RK3326 / aarch64.")
' | tee -a patch.log
fi

TOTAL=$(grep -cE 'PATCH-FEHLER:|PATCH-WARNUNG:' patch.log || true)
echo "Patch-Probleme gesamt: $TOTAL"
if [ "$TOTAL" -gt 0 ] && [ "${MC3_PATCH_STRICT}" = "1" ]; then
  echo "::error::Strict-Modus: $TOTAL Patch-Problem(e), siehe patch.log"
  exit 1
fi

echo "== Save Patched Sources =="
OUT="${WORKSPACE_DIR}/patched-sources"
rm -rf "$OUT"
mkdir -p "$OUT"
[ -f CMakeLists.txt ] && cp -a CMakeLists.txt "$OUT/CMakeLists.txt"
find src external/xport -maxdepth 4 -type f \( -name '*.cpp' -o -name '*.c' -o -name '*.h' -o -name '*.hpp' -o -name '*.cmake' \) 2>/dev/null | while IFS= read -r f; do
  mkdir -p "$OUT/$(dirname "$f")"
  cp -a "$f" "$OUT/$f"
done

echo "== Configure & Build for RK3326 (1 GB RAM / Mali-G31) =="
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="${WORKSPACE_DIR}/cmake/aarch64-arkos.cmake" \
  -DSDL2_INSTALL_DIR="${SDL2_INSTALL}" \
  -DSDL2_DIR="${SDL2_INSTALL}/lib/cmake/SDL2" \
  -DCMAKE_PREFIX_PATH="${SDL2_INSTALL};${SYSROOT_LIB}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="-mcpu=cortex-a35 -mtune=cortex-a35 -O2 -pipe" \
  -DCMAKE_CXX_FLAGS="-mcpu=cortex-a35 -mtune=cortex-a35 -O2 -pipe"

cmake --build build -j "${JOBS}"

echo "== Compatibility Check (GLIBC / NEEDED) =="
BIN=$(find build -maxdepth 3 -type f -executable ! -name '*.so*' ! -name '*.a' | head -n 1)
test -n "$BIN"
aarch64-linux-gnu-readelf -d "$BIN" | grep NEEDED || true

G=$(aarch64-linux-gnu-objdump -T "$BIN" | { grep -oE 'GLIBC_[0-9][0-9.]*' || true; } | sed 's/^GLIBC_//' | sort -Vu | tail -1)
echo "Hoechste benoetigte GLIBC: ${G:-keine} (Limit: ${MAX_GLIBC})"
if [ -n "$G" ] && [ "$(printf '%s\n%s\n' "${MAX_GLIBC}" "$G" | sort -V | tail -1)" != "${MAX_GLIBC}" ]; then
  echo "::error::Binary braucht GLIBC_${G}, erlaubt ist ${MAX_GLIBC}"
  exit 1
fi

echo "== Package Bundle for M9 Pro =="
STAGE="${WORKSPACE_DIR}/dist"
rm -rf "$STAGE"
mkdir -p "${STAGE}/mc3port/libs.aarch64" "${STAGE}/mc3port/shader_cache" "${STAGE}/mc3port/saves"
install -m 755 "$BIN" "${STAGE}/mc3port/mc3port"

for f in "${SDL2_INSTALL}/lib"/libSDL2-2.0.so*; do
  [ -e "$f" ] && cp -a "$f" "${STAGE}/mc3port/libs.aarch64/" || true
done

cat > "${STAGE}/MC3Port.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
PORT_DIR="/roms/ports/mc3port"
[ -d "$PORT_DIR" ] || PORT_DIR="$(cd "$(dirname "$0")/mc3port" && pwd)"
export LD_LIBRARY_PATH="${PORT_DIR}/libs.aarch64:${LD_LIBRARY_PATH:-}"
cd "$PORT_DIR" || exit 1
exec ./mc3port > "${PORT_DIR}/mc3port.log" 2>&1
EOF

chmod 755 "${STAGE}/MC3Port.sh" "${STAGE}/mc3port/mc3port"
cd "${STAGE}"
tar -czf mc3port-rk3326.tar.gz mc3port MC3Port.sh
ls -la
