# Distinct lanes expose lane order and partial-result errors.
# The testbench preloads LS[0]=[1,2,3,4], LS[1]=[10,20,30,40].
# Run: ./build.sh lanes
    il r1, 0
    lnop
    nop
    lqd r10, 0(r1)
    nop
    lqd r11, 16(r1)
    a r12, r10, r11
    lnop
    nop
    stqd r12, 32(r1)
# Allow the store to complete before reading the same location.
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lqd r13, 32(r1)
    ai r14, r13, 1
    lnop
    nop
    stqd r14, 48(r1)
# Drain before STOP so outstanding stores complete.
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    nop
    lnop
    stop
    lnop
