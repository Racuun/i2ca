# rv32i_test.s - Comprehensive RV32I Core Compliance Test Suite
# Target: Single-Cycle RV32I Processor (i2ca)
#
# Protocol:
#   gp (x3) holds the current test number (1..8).
#   Status is reported 100% IN-MEMORY into Data RAM[0] (address 0x00000000).
#   On success: writes 1 (0x00000001) to RAM[0] and loops at pass_loop.
#   On error:   writes gp (>1) to RAM[0] and loops at fail_loop.

.global _start
.text

_start:
    # Initialize stack pointer to top of Data RAM (16 KB = 0x4000 bytes)
    li      sp, 0x00003FFC

# ==============================================================================
# TEST 1: ADDI, ADD, SUB and x0 immutability
# ==============================================================================
test_1:
    li      gp, 1
    # Check x0 hardwired to zero
    addi    x0, x0, 42
    bne     x0, zero, fail

    # ADDI with positive and negative immediates
    li      t0, 10
    addi    t0, t0, 25          # 35
    li      t1, 35
    bne     t0, t1, fail

    addi    t0, t0, -15         # 20
    li      t1, 20
    bne     t0, t1, fail

    # ADD and SUB
    li      t1, 15
    add     t2, t0, t1          # 20 + 15 = 35
    li      t3, 35
    bne     t2, t3, fail

    sub     t2, t2, t1          # 35 - 15 = 20
    bne     t2, t0, fail

# ==============================================================================
# TEST 2: Logical Operations (AND, OR, XOR, ANDI, ORI, XORI)
# ==============================================================================
test_2:
    li      gp, 2
    li      t0, 0x000000FF
    li      t1, 0x00000F0F
    
    and     t2, t0, t1          # 0x0000000F
    li      t3, 0x0000000F
    bne     t2, t3, fail

    or      t2, t0, t1          # 0x00000FFF
    li      t3, 0x00000FFF
    bne     t2, t3, fail

    xor     t2, t0, t1          # 0x00000FF0
    li      t3, 0x00000FF0
    bne     t2, t3, fail

    andi    t2, t0, 0x0F        # 0x0000000F
    li      t3, 0x0000000F
    bne     t2, t3, fail

    ori     t2, t0, 0x700       # 0x000007FF
    li      t3, 0x000007FF
    bne     t2, t3, fail

    xori    t2, t0, 0x0F        # 0x000000F0
    li      t3, 0x000000F0
    bne     t2, t3, fail

# ==============================================================================
# TEST 3: Shifts (SLL, SRL, SRA, SLLI, SRLI, SRAI)
# ==============================================================================
test_3:
    li      gp, 3
    li      t0, 1
    slli    t1, t0, 4           # 16
    li      t2, 16
    bne     t1, t2, fail

    srli    t1, t1, 4           # 1
    bne     t1, t0, fail

    # Arithmetic shift right with sign preservation
    li      t0, -32             # 0xFFFFFFE0
    srai    t1, t0, 2           # -8 (0xFFFFFFF8)
    li      t2, -8
    bne     t1, t2, fail

    # Variable shift register variants
    li      t0, 0x0F
    li      t1, 2
    sll     t2, t0, t1          # 0x3C
    li      t3, 0x3C
    bne     t2, t3, fail

    srl     t2, t2, t1          # 0x0F
    bne     t2, t0, fail

# ==============================================================================
# TEST 4: Comparisons (SLT, SLTU, SLTI, SLTIU)
# ==============================================================================
test_4:
    li      gp, 4
    # Signed vs unsigned comparison of negative number vs positive number
    li      t0, -1              # 0xFFFFFFFF
    li      t1, 1

    slt     t2, t0, t1          # -1 < 1 is true (signed) -> 1
    li      t3, 1
    bne     t2, t3, fail

    sltu    t2, t0, t1          # 0xFFFFFFFF < 1 is false (unsigned) -> 0
    bne     t2, zero, fail

    slti    t2, t0, 0           # -1 < 0 is true -> 1
    bne     t2, t3, fail

    sltiu   t2, t0, 10          # 0xFFFFFFFF < 10 is false -> 0
    bne     t2, zero, fail

# ==============================================================================
# TEST 5: Upper Immediates (LUI, AUIPC)
# ==============================================================================
test_5:
    li      gp, 5
    lui     t0, 0x12345         # 0x12345000
    li      t1, 0x12345000
    bne     t0, t1, fail

    # AUIPC verification
here:
    auipc   t2, 0               # t2 should equal address of 'here'
    la      t3, here
    bne     t2, t3, fail

# ==============================================================================
# TEST 6: Conditional Branches (BEQ, BNE, BLT, BGE, BLTU, BGEU)
# ==============================================================================
test_6:
    li      gp, 6
    li      t0, 5
    li      t1, 10

    # BEQ & BNE
    beq     t0, t0, br_eq_ok
    j       fail
br_eq_ok:
    bne     t0, t1, br_ne_ok
    j       fail
br_ne_ok:

    # BLT & BGE (signed)
    li      t2, -5
    blt     t2, t0, br_lt_ok
    j       fail
br_lt_ok:
    bge     t0, t2, br_ge_ok
    j       fail
br_ge_ok:

    # BLTU & BGEU (unsigned)
    bltu    t0, t2, br_ltu_ok   # 5 < 0xFFFFFFFB (unsigned true)
    j       fail
br_ltu_ok:
    bgeu    t2, t0, br_geu_ok
    j       fail
br_geu_ok:

# ==============================================================================
# TEST 7: Memory Subsystem (SW, LW, SB, LB, LBU, SH, LH, LHU)
# ==============================================================================
test_7:
    li      gp, 7
    li      t0, 0x00000100      # Working buffer in Data RAM (offset 256)
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    bne     t1, t2, fail

    # Store bytes: 0x11, 0x22, 0x33, 0x44 (Little-Endian verification)
    li      t1, 0x44
    sb      t1, 0(t0)
    li      t1, 0x33
    sb      t1, 1(t0)
    li      t1, 0x22
    sb      t1, 2(t0)
    li      t1, 0x11
    sb      t1, 3(t0)
    lw      t2, 0(t0)
    li      t3, 0x11223344
    bne     t2, t3, fail

    # Byte load sign-extension vs zero-extension
    li      t1, 0x85
    sb      t1, 0(t0)
    lb      t2, 0(t0)           # Sign-extended: 0xFFFFFF85
    li      t3, 0xFFFFFF85
    bne     t2, t3, fail
    lbu     t2, 0(t0)           # Zero-extended: 0x00000085
    li      t3, 0x00000085
    bne     t2, t3, fail

    # Halfword operations
    li      t1, 0x1234
    sh      t1, 4(t0)
    lh      t2, 4(t0)
    bne     t1, t2, fail

    li      t1, 0x8765
    sh      t1, 4(t0)
    lh      t2, 4(t0)           # Sign-extended: 0xFFFF8765
    li      t3, 0xFFFF8765
    bne     t2, t3, fail
    lhu     t2, 4(t0)           # Zero-extended: 0x00008765
    li      t3, 0x00008765
    bne     t2, t3, fail

# ==============================================================================
# TEST 8: Jumps and Link (JAL, JALR) & Call Stack
# ==============================================================================
test_8:
    li      gp, 8
    li      a0, 40
    jal     ra, add_two
    li      t0, 42
    bne     a0, t0, fail
    j       all_pass

add_two:
    addi    a0, a0, 2
    ret

# ==============================================================================
# Outcome Handlers (100% In-Memory Reporting)
# ==============================================================================
all_pass:
    # Success: write 1 (0x00000001) into RAM[0] (address 0x00000000)
    li      t0, 0x00000000
    li      t1, 1
    sw      t1, 0(t0)

pass_loop:
    j       pass_loop

fail:
    # Error: write failing test number (gp) into RAM[0] (address 0x00000000)
    li      t0, 0x00000000
    sw      gp, 0(t0)

fail_loop:
    j       fail_loop
