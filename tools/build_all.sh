#!/bin/bash
# tools/build_all.sh — the gate every phase of the Swift 6.4 adoption must pass.
# Clean-builds all 11 targets into build_gate/<target> (never touches your
# own build*/ dirs), runs host tests, records sizes and exported symbols.
# Written for macOS /bin/bash 3.2: no associative arrays.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES=docs/superpowers/notes/swift64-sizes.md
ALL=(esp32c6 pico pico_w pico2 pico2_w smk_kbd_rp2040 nrf52840dk feather_nrf52840 samd21 stm32f4 stm32wb)
TARGETS=("${ALL[@]}")
LABEL="$(git rev-parse --short HEAD)"; BASELINE=""; CHECK_POLLS=0; SYMBASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE="$2"; LABEL="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --only) IFS=, read -r -a TARGETS <<< "$2"; shift 2 ;;
    --check-polls) CHECK_POLLS=1; shift ;;
    --symbols-baseline) SYMBASE=1; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

ARM=/opt/homebrew/opt/arm-gcc-bin@14/bin; export PATH="$ARM:$PATH"
ESPBIN=$(ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin 2>/dev/null | head -1)
: "${PICO_SDK_PATH:=$HOME/pico-sdk}" "${TINYUSB_PATH:=$HOME/tinyusb}" "${CMSIS_CORE_PATH:=$HOME/CMSIS_6}"
: "${CMSIS_F4_PATH:=$HOME/cmsis-device-f4}" "${CMSIS_WB_PATH:=$HOME/cmsis-device-wb}" "${BTSTACK_PATH:=$HOME/btstack}"
: "${STM32CUBEWB_PATH:=$HOME/STM32CubeWB}" "${NRF5_SDK_PATH:=$HOME/nRF5_SDK}" "${NRFXLIB_PATH:=$HOME/sdk-nrfxlib}"
export PICO_SDK_PATH TINYUSB_PATH CMSIS_CORE_PATH CMSIS_F4_PATH CMSIS_WB_PATH BTSTACK_PATH STM32CUBEWB_PATH NRF5_SDK_PATH NRFXLIB_PATH
GCC=(-DCMAKE_C_COMPILER=$ARM/arm-none-eabi-gcc -DCMAKE_CXX_COMPILER=$ARM/arm-none-eabi-g++ -DCMAKE_ASM_COMPILER=$ARM/arm-none-eabi-gcc)

elf_of() {
  case $1 in
    esp32c6) echo build_gate/$1/my_swift_keyboard.elf ;;
    pico|pico_w|pico2|pico2_w|smk_kbd_rp2040) echo build_gate/$1/smk_rp2040.elf ;;
    nrf52840dk|feather_nrf52840) echo build_gate/$1/smk_nrf52840 ;;
    *) echo build_gate/$1/smk_$1 ;;
  esac
}
tool_of() { if [ "$1" = esp32c6 ]; then echo "$ESPBIN/riscv32-esp-elf-$2"; else echo "$ARM/arm-none-eabi-$2"; fi; }

build_one() {
  local t=$1 d=build_gate/$1
  rm -rf "$d"; mkdir -p build_gate
  case $t in
    esp32c6)
      ( . "$HOME/.espressif/v6.0.1/esp-idf/export.sh" >/dev/null
        idf.py -B "$d" -DIDF_TARGET=esp32c6 build ) >"$d.log" 2>&1 ;;
    pico|pico_w|pico2|pico2_w|smk_kbd_rp2040)
      local pb=$t; [ "$t" = smk_kbd_rp2040 ] && pb=pico
      { cmake -G Ninja -S ports/rp2040 -B "$d" -DPICO_BOARD=$pb -DSMK_TARGET_BOARD=$t "${GCC[@]}" && ninja -C "$d"; } >"$d.log" 2>&1 ;;
    nrf52840dk|feather_nrf52840)
      { cmake -G Ninja -S ports/nrf52840 -B "$d" -DSMK_TARGET_BOARD=$t && ninja -C "$d"; } >"$d.log" 2>&1 ;;
    samd21|stm32f4|stm32wb)
      { cmake -G Ninja -S ports/$t -B "$d" && ninja -C "$d"; } >"$d.log" 2>&1 ;;
  esac
}

fail=0; FLASH=(); RAM=()
for i in "${!TARGETS[@]}"; do
  t=${TARGETS[$i]}
  if build_one "$t" && [ -f "$(elf_of "$t")" ]; then
    elf=$(elf_of "$t")
    read -r f r < <("$(tool_of "$t" size)" -B "$elf" | awk 'NR==2 {print $1+$2, $2+$3}')
    FLASH[$i]=$f; RAM[$i]=$r
    "$(tool_of "$t" nm)" -g --defined-only "$elf" | awk '{print $NF}' | sort > "build_gate/$t/symbols.txt"
    [ $SYMBASE = 1 ] && cp "build_gate/$t/symbols.txt" "docs/superpowers/notes/symbols-$t.txt"
    echo "PASS build $t  flash=$f ram=$r"
  else
    echo "FAIL build $t  (see build_gate/$t.log)"; fail=1; FLASH[$i]=FAIL; RAM[$i]=FAIL
  fi
done

if SMK_HOST_TESTS_ONLY=1 swift test >build_gate/swift-test.log 2>&1; then echo "PASS swift test"; else echo "FAIL swift test (build_gate/swift-test.log)"; fail=1; fi

if [ $CHECK_POLLS = 1 ]; then
  # Entry forms (see tools/poll_functions.txt):
  #   target:function          function must contain a BACKWARD conditional
  #                            branch (target address < branch address, still
  #                            inside the function) — i.e. a loop survived.
  #   target:function>callee   function must contain a call or tail call
  #                            (bl/blx/b/jal/j/jalr/jr/call/tail) whose target
  #                            address is callee's address.
  # Both match by ADDRESS, not by objdump's "<name>" labels: ARM objdump treats
  # `$`-prefixed names as mapping symbols and never labels them, which hides
  # every Embedded-Swift mangled name ($e...). RISC-V far calls are an
  # auipc+jalr pair; objdump annotates the jalr with "# <target address>",
  # which is what gets matched there.
  # No early-exit awk in these pipelines: it SIGPIPEs the producer, which
  # pipefail + errexit turn into a silent abort (exit 141).
  # Prints "start stop" (decimal, Thumb bit cleared) for a symbol, or nothing.
  sym_range() {
    "$(tool_of "$1" nm)" -S --defined-only "$(elf_of "$1")" |
      awk -v f="$2" '$NF==f && !s {print $1, (NF==4 ? $2 : "0"); s=1}' |
      while read -r a sz; do echo "$(( 0x$a & ~1 )) $(( (0x$a & ~1) + 0x$sz ))"; done
  }
  while IFS=: read -r t entry; do
    case "$t" in ''|\#*) continue ;; esac
    fn=${entry%%>*}; callee=""
    case "$entry" in *'>'*) callee=${entry#*>} ;; esac
    body=""; range=$(sym_range "$t" "$fn")
    if [ -n "$range" ]; then
      read -r start stop <<<"$range"
      body=$("$(tool_of "$t" objdump)" -d --no-show-raw-insn --start-address=$start --stop-address=$stop "$(elf_of "$t")")
    fi
    ok=0
    if [ -z "$body" ]; then
      why="function not found"
    elif [ -n "$callee" ]; then
      why="no call to $callee (settle/delay call removed or inlined?)"
      crange=$(sym_range "$t" "$callee")
      if [ -n "$crange" ]; then
        read -r cstart _ <<<"$crange"
        hits=$(awk -v want="$(printf '%x' "$cstart")" '
          /^ *[0-9a-f]+:/ {
            m = $2
            if (m !~ /^(bl|blx|b|b\.n|b\.w|jal|j|jalr|jr|call|tail|c\.jal|c\.j)$/) next
            line = $0; sub(/<.*/, "", line)         # drop "<label>" text
            n = split(line, tok, /[ \t,#]+/)
            for (i = 3; i <= n; i++) { x = tok[i]; sub(/^0x/, "", x); sub(/^0+/, "", x)
              if (x == want) { c++; break } }
          }
          END { print c + 0 }' <<<"$body")
        [ "$hits" -gt 0 ] && ok=1
      else
        why="callee $callee not found"
      fi
    else
      why="no backward conditional branch: loop deleted?"
      hits=$(awk -v lo="$start" -v hi="$stop" '
        function hex(s,   i, c, v) { v = 0; s = tolower(s); sub(/^0x/, "", s)
          for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1))
            if (c == 0) return -1; v = v * 16 + c - 1 }
          return v }
        /^ *[0-9a-f]+:/ {
          if ($2 !~ /^c?b(ne|eq|cc|cs|hs|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|nz|z)(z|u|zu)?(\.n|\.w)?$/) next
          a = $1; sub(/:$/, "", a); a = hex(a)
          line = $0; sub(/<.*/, "", line); sub(/[ \t]+$/, "", line)
          n = split(line, tok, /[ \t,]+/); tg = hex(tok[n])
          if (tg >= lo && tg < a) c++
        }
        END { print c + 0 }' <<<"$body")
      [ "$hits" -gt 0 ] && ok=1
    fi
    if [ $ok = 1 ]; then echo "PASS poll $t:$entry"
    else echo "FAIL poll $t:$entry ($why)"; fail=1; fi
  done < tools/poll_functions.txt
fi

# Rows always use the canonical 11-column order; targets not built this run are "-".
if [ ! -f "$NOTES" ]; then
  { echo "# Swift 6.4 adoption — gate sizes"; echo; echo "flash = text+data, ram = data+bss (bytes). Cells: flash/ram."; echo
    printf '| label |'; for t in "${ALL[@]}"; do printf ' %s |' "$t"; done; echo
    printf '|---|'; for t in "${ALL[@]}"; do printf -- '---|'; done; echo; } > "$NOTES"
fi
row="| $LABEL |"
for t in "${ALL[@]}"; do
  cell="-"
  for i in "${!TARGETS[@]}"; do [ "${TARGETS[$i]}" = "$t" ] && cell="${FLASH[$i]}/${RAM[$i]}"; done
  row="$row $cell |"
done
echo "$row" >> "$NOTES"

if [ -z "$BASELINE" ]; then
  base=$(grep '^| 6.4-baseline |' "$NOTES" | head -1 || true)
  if [ -z "$base" ]; then echo "FAIL no 6.4-baseline row yet"; fail=1; else
    for i in "${!TARGETS[@]}"; do
      t=${TARGETS[$i]}; f=${FLASH[$i]}; r=${RAM[$i]}; [ "$f" = FAIL ] && continue
      col=0; for j in "${!ALL[@]}"; do [ "${ALL[$j]}" = "$t" ] && col=$((j + 3)); done
      cell=$(echo "$base" | awk -F'|' -v c=$col '{gsub(/ /,"",$c); print $c}')
      bf=${cell%/*}; br=${cell#*/}
      if [ $((f * 100)) -gt $((bf * 102)) ] || [ $((r * 100)) -gt $((br * 102)) ]; then
        echo "FAIL size $t flash $bf->$f ram $br->$r (>2%)"; fail=1
      else echo "PASS size $t flash $bf->$f ram $br->$r"; fi
    done
  fi
fi
exit $fail
