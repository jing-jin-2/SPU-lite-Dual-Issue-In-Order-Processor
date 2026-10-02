# ====================================================================
# test_demo.s -- single-program walkthrough for ESE 545 live demo
# ====================================================================
#
# Sections in the order the prof checks:
#
#   1. Hazard-free first two instructions  (pipeline depth)
#      +- il r10 (even FX1) + rotqbyi r11 (odd PERM): different pipes,
#         no RAW, both write a register.  Watch wr_en pulses, count
#         cycles to retire.
#
#   2. Structural hazard                    (both slots -> FX1 even)
#      +- il r12 (slot 0) issues; il r13 (slot 1) replays next cycle.
#
#   3. RAW resolved by FORWARDING, SAME pipe   (FX1 -> FX1, gap=1 -> no stall)
#   4. RAW resolved by FORWARDING, CROSS pipe  (FX1 -> PERM, gap=1 -> no stall)
#
#   5. RAW that REQUIRES a STALL               (FP lat 7 -> FX1, gap=0)
#      +- Consumer stalls 5 cycles (the minimum: FP depth=6, c2r=5
#         when the producer enters pipe[0]; forwardable when c2r=0).
#
#   6. Branch NOT TAKEN                        (correct prediction, no flush)
#   7. Branch TAKEN                            (cold BHT mispredicts -> flush)
#   8. 3-iteration loop                        (predictor warming, BTB hit)
#
# Run from the repository root: ./build.sh demo
# Optional waveform: DUMP=1 ./build.sh demo
# ====================================================================


# ====================================================================
#  SECTION 1 -- first two hazard-free instructions
#    Both write a register; different pipes; no RAW.
#    Use this to count pipeline depth in the wave.
# ====================================================================
    il      r10, 100        # even FX1, slot 0  -> r10 = 0x00000064
    rotqbyi r11, r0, 0      # odd  PERM, slot 1 -> r11 = 0  (rotqbyi r0=0)

# Drain so the wave clearly shows two retirements then idle.
    nop
    lnop
    nop
    lnop
    nop
    lnop


# ====================================================================
#  SETUP -- constants for later sections
# ====================================================================
    il      r1, 0           # zero condition (BRZ taken-when-zero)
    lnop
    il      r2, 5           # nonzero condition
    lnop
    ilhu    r80, 0x3F80     # 1.0 in IEEE single (each word = 0x3F800000)
    lnop
    ilhu    r81, 0x4000     # 2.0 (each word = 0x40000000)
    lnop
    nop
    lnop
    nop
    lnop


# ====================================================================
#  SECTION 2 -- structural hazard (both slots -> FX1 even)
#    Slot 0 (il r12) issues this cycle.
#    Slot 1 (il r13) is held; replays alone next cycle (pending_slot1=1).
# ====================================================================
    il      r12, 50         # even FX1, slot 0 -- issues
    il      r12, 60         # even FX1, slot 1 -- STRUCT HAZARD, replays
    nop
    lnop
    nop
    lnop


# ====================================================================
#  SECTION 3 -- RAW forward, SAME pipe  (FX1 -> FX1, no stall)
#    Producer at bundle N, consumer at bundle N+2 -> consumer's stage-3
#    sees producer in pipe[1] with c2r=0 -> forward, no stall.
# ====================================================================
    il      r14, 7          # producer (even FX1)
    lnop
    nop                     # filler bundle (1 in between)
    lnop
    ai      r14, r14, 3     # consumer (even FX1) -- forwards from pipe[1]
    lnop
    nop
    lnop


# ====================================================================
#  SECTION 4 -- RAW forward, CROSS pipe  (FX1 -> PERM, no stall)
#    Even producer, odd consumer.  Same gap as section 3 -> no stall.
# ====================================================================
    il      r16, 1          # producer (even FX1) -- r16 = 0x00000001
    lnop
    nop                     # filler bundle
    lnop
    nop                     # consumer goes in slot 1 (odd) of next bundle
    rotqbyi r17, r16, 0     # consumer (odd PERM) -- cross-pipe forward
    nop
    lnop


# ====================================================================
#  SECTION 5 -- RAW that REQUIRES a stall  (FP lat 7 -> FX1, gap=0)
#    fa enters pipe[0] with c2r=5 (FP depth=6).
#    Consumer at gap=0 stalls 5 cycles, then forwards from pipe[5].
#    This is the MINIMUM stall for this dependency -- there is no way
#    to forward sooner because cycles_to_ready hasn't reached 0.
# ====================================================================
    fa      r18, r80, r81   # FP add, lat 7 -> r18 = 1.0+2.0 = 3.0
    lnop                    #                 = 0x40400000 (each word)
    ai      r19, r18, 0     # immediate consumer -- STALLS 5 cycles, then fwd
    lnop
    nop
    lnop
    nop
    lnop


# ====================================================================
#  SECTION 6 -- branch NOT taken (correct prediction)
#    Cold BHT predicts not-taken.  r2 = 5 (nonzero) -> BRZ falls through.
#    Prediction matches outcome -> no flush, no flush_o pulse.
#    The post-branch ai executes -> r20 = 1.
# ====================================================================
    il      r20, 0          # marker
    lnop
    nop
    lnop
    nop
    brz     r2, sec6_skip   # NOT taken (r2 nonzero)
    ai      r20, r20, 1     # executes (no flush) -> r20 = 1
    lnop
    nop
    lnop
sec6_skip:
    nop
    lnop
    nop
    lnop


# ====================================================================
#  SECTION 7 -- branch TAKEN (misprediction -> flush)
#    Cold BHT predicts not-taken; BR is unconditional -> MISPREDICTION.
#    flush_o pulses; the post-branch IL is squashed -> r21 stays 0.
#    BTB now installed; future encounters of this PC predict taken.
# ====================================================================
    il      r21, 0          # marker (expect to stay 0)
    lnop
    nop
    lnop
    nop
    br      sec7_after      # always taken
    il      r21, 0xDEAD     # FLUSHED -- r21 stays 0
    lnop
    nop
    lnop
sec7_after:
    nop
    lnop
    nop
    lnop


# ====================================================================
#  SECTION 8 -- 3-iteration loop (predictor warming)
#    Iter 1: cold BHT predicts not-taken; brnz IS taken -> flush, BTB install.
#    Iter 2: BTB hot, predicts taken; brnz IS taken      -> no flush (free).
#    Iter 3: BTB still predicts taken; brnz NOT taken    -> flush, fall through.
#    Final: r22 = 0, r23 = 3.
# ====================================================================
    il      r22, 3          # counter
    lnop
    il      r23, 0          # accumulator
    lnop
    nop
    lnop
loop_top:
    ai      r23, r23, 1     # acc++  (FX1 lat 3)
    lnop
    ai      r22, r22, -1    # ctr--  (FX1 lat 3)
    lnop
    nop
    brnz    r22, loop_top   # taken iter 1,2; not-taken iter 3
    nop
    lnop
    nop
    lnop


# ====================================================================
#  END
# ====================================================================
    stop
    lnop
