#!/usr/bin/env bash
# Mutation check for the testbench: each mutant breaks one rule the bridge
# relies on (an exact text substitution in a temporary copy of the RTL), and
# the randomized self-check must catch it (data errors or the deadlock
# watchdog) within a few seeds.  A mutant that survives means a test gap.
# Usage: tb/run_mutants.sh [ops] [seeds]      (run from ddr_bridge/)
#
# Not listed, because they cannot change the data:
#  * dropping only ~wb_valid or only ~push_wr from can_alloc: each covers the
#    other (with wb_valid and an empty write queue, flush_idle pushes the held
#    write that cycle; without wb_valid there is nothing for push_wr to push),
#    so the mutant drops both;
#  * no alloc_cool: a double allocation only wastes a DDR read -- a waiting
#    read takes its data from the current-line copy keyed by its own gen.
set -u
OPS="${1:-3000}"
SEEDS="${2:-4}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
cd "$(dirname "$0")/.."

python3 - "$OUT" <<'EOF'
import sys
out = sys.argv[1]
src = open("rtl/ahb_ddr3_bridge.v").read()
M = [
  ("read_overtakes_queued_write",
   "wire sp_go    = rd_wait & (sp_st == SP_IDLE) & ~wq_busy;",
   "wire sp_go    = rd_wait & (sp_st == SP_IDLE);"),
  ("write_keeps_current_line",
   "                if (cl_v && cl_line == wh_line) begin\n                    cl_v <= 1'b0;",
   "                if (1'b0) begin\n                    cl_v <= 1'b0;"),
  ("write_keeps_line_buffers",
   "                    if (ent_alloc[k] && ent_tag[k] == wh_line) begin",
   "                    if (1'b0) begin"),
  ("predict_from_missing_half",
   "wire          nb_ok   = nb_v & (nb_left != 2'd0) & cl_v & cl_hv[nb_beat[1]]",
   "wire          nb_ok   = nb_v & (nb_left != 2'd0) & cl_v"),
  ("predict_counts_busy",
   "wire t_seq     = (htrans == 2'b11);",
   "wire t_seq     = htrans[0];"),
  ("predict_wrong_next_beat",
   "                    nb_beat <= aq_beat + 2'd1;",
   "                    nb_beat <= aq_beat;"),
  ("no_return_forward_on_load",
   "(cl_ld_ent ? (rf_ent == lk_idx) && (rf_gen == ent_gen[lk_idx])",
   "(1'b0      ? (rf_ent == lk_idx) && (rf_gen == ent_gen[lk_idx])"),
  ("merge_flag_ignores_consumed_head",
   "(wq_mem[wq_rp][WQW-1 -: BB] == (wh_cons ? wh_blk : wb_blk))",
   "(wq_mem[wq_rp][WQW-1 -: BB] == wb_blk)"),
  # needs a held merged write while the command FIFO is nearly full: heavy
  # DDR back-pressure and longer runs
  ("read_overtakes_held_write",
   "wire can_alloc = vic_ok_q & ~alloc_cool & ~cf_afull & ~wb_valid & ~wq_busy & ~push_wr;",
   "wire can_alloc = vic_ok_q & ~alloc_cool & ~cf_afull & ~wq_busy;",
   "+mode=0 +rdy_pct=20 +ops=8000"),
  ("one_read_mode_ignores_pending_tag",
   "    wire          rd_out    = (tq_n != 5'd0) | tq_push_q;",
   "    wire          rd_out    = (tq_n != 5'd0);",
   "+mode=0x100 +max_rd=1"),
]
with open(out + "/mutants.list", "w") as lst:
    for m in M:
        name, old, new = m[:3]
        args = m[3] if len(m) > 3 else "+mode=0"
        assert src.count(old) == 1, (name, old)
        open("%s/mut_%s.v" % (out, name), "w").write(src.replace(old, new))
        lst.write("%s|%s\n" % (name, args))
EOF
[ $? = 0 ] || { echo "MUTANTS: could not apply"; exit 1; }

missed=0
while IFS='|' read -r name margs; do
    if ! iverilog -g2012 -P tb_ahb_ddr3_bridge.XROW_REORDER=1 -o "$OUT/tb_$name" \
            tb/tb_ahb_ddr3_bridge.v tb/ddr3_ui_model.v "$OUT/mut_$name.v" \
            rtl/ddr_async_fifo.v rtl/ddr_rd_bist.v > "$OUT/$name.build" 2>&1; then
        echo "$name: BUILD FAILED"; missed=1; continue
    fi
    verdict="SURVIVED"
    for ((s = 1; s <= SEEDS; s++)); do
        # 100 MHz bus; the default +mode=0 keeps the row rule active against the
        # reordering DDR model, so a broken row / in-flight rule shows up as errors
        # per-mutant plusargs first: the first matching plusarg wins
        r=$(timeout 600 vvp -n "$OUT/tb_$name" $margs +seed=$((s * 7919)) +ops="$OPS" \
                +hclk_ns=10 +uclk_ns=10 | grep -E "^TEST|^TIMEOUT" | head -1)
        if [[ $r != "TEST PASSED" ]]; then verdict="caught (seed $s: ${r:0:48})"; break; fi
    done
    printf "%-42s %s\n" "$name" "$verdict"
    [[ $verdict == SURVIVED ]] && missed=1
done < "$OUT/mutants.list"
[ $missed = 0 ] && echo "MUTANTS ALL CAUGHT" || echo "MUTANTS: SOME SURVIVED"
exit $missed
