/// Chain position (0-indexed) of key (row, col) — must match
/// generate_pcb.py's `led_chain_index`. The chain is wired
/// serpentine/boustrophedon: even rows run col 0->COLS-1, odd rows run
/// COLS-1->0, so chain-adjacent LEDs stay physically adjacent.
func ledChainIndex(row: Int, col: Int, colCount: Int) -> Int {
    if row % 2 == 0 {
        return row * colCount + col
    } else {
        return row * colCount + (colCount - 1 - col)
    }
}
