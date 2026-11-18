#!/usr/bin/env python3
"""
verify_core.py - Automated Headless RV32I Processor Verification Tool
Part of i2ca (Introduction to Computer Architecture) course.

Verifies single-cycle RV32I processor circuits in Digital without requiring
datapath modifications, artificial status pins, or GUI interaction.
Loads the compliance test into ROM and verifies the status word in Data RAM[0].

Usage:
    python3 verify_core.py
    python3 verify_core.py --circ path/to/core.dig
    python3 verify_core.py --cmem
    python3 verify_core.py --circ ref-model/hw/digital/hart.dig --cmem
"""

import sys
import os
import subprocess
import argparse
import json
import shutil

TEST_NAMES = {
    1: "TEST 1: ADDI, ADD, SUB & x0 Immutability",
    2: "TEST 2: Logical Operations (AND, OR, XOR, ANDI, ORI, XORI)",
    3: "TEST 3: Shifts (SLL, SRL, SRA, SLLI, SRLI, SRAI)",
    4: "TEST 4: Comparisons (SLT, SLTU, SLTI, SLTIU)",
    5: "TEST 5: Upper Immediates (LUI, AUIPC)",
    6: "TEST 6: Conditional Branches (BEQ, BNE, BLT, BGE, BLTU, BGEU)",
    7: "TEST 7: Memory Subsystem (SW, LW, SB, LB, LBU, SH, LH, LHU)",
    8: "TEST 8: Jumps and Link (JAL, JALR) & Call Stack",
}

def find_digital_jar():
    candidates = [
        "/opt/digital/Digital.jar",
        os.path.expanduser("~/.local/share/digital/Digital.jar"),
        os.path.expanduser("~/Digital/Digital.jar"),
        "/usr/local/share/digital/Digital.jar",
        "/opt/Digital/Digital.jar"
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
            
    dig_cmd = shutil.which("digital")
    if dig_cmd:
        try:
            with open(dig_cmd) as f:
                for part in f.read().split():
                    if part.endswith("Digital.jar") and os.path.isfile(part):
                        return part
        except Exception:
            pass

    return None

def main():
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(scripts_dir, "..", ".."))

    default_circ = os.path.join(repo_root, "ref-model", "hw", "digital", "hart.dig")

    parser = argparse.ArgumentParser(description="Headless RV32I Processor Verification Tool")
    parser.add_argument("--circ", default=None,
                        help="Path to target circuit (.dig, default: ref-model/hw/digital/hart.dig)")
    parser.add_argument("--cmem", action="store_true",
                        help="Verify with unified/mapped memory architecture (CMEM, RAM base 0x00008000)")
    parser.add_argument("--cycles", type=int, default=2000,
                        help="Maximum simulation clock cycles (default: 2000)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Enable verbose cycle logging")

    args = parser.parse_args()

    # Determine circuit path
    if args.circ:
        circ_path = os.path.abspath(args.circ)
    else:
        circ_path = default_circ

    # Determine test hex
    hex_name = "rv32i_test_cmem.hex" if args.cmem else "rv32i_test.hex"
    hex_path = os.path.join(scripts_dir, "tests_rv32i", hex_name)

    digital_jar = find_digital_jar()
    if not digital_jar:
        print("[ERROR] Could not find Digital.jar in standard system locations.", file=sys.stderr)
        sys.exit(1)

    if not shutil.which("java"):
        print("[ERROR] 'java' command not found. Java JRE is required.", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(circ_path):
        print(f"[ERROR] Target circuit not found: {circ_path}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(hex_path):
        print(f"[ERROR] Test hex file not found: {hex_path}", file=sys.stderr)
        sys.exit(1)

    verifier_java = os.path.join(scripts_dir, "CoreVerifier.java")
    if not os.path.isfile(verifier_java):
        print(f"[ERROR] CoreVerifier.java not found in {scripts_dir}", file=sys.stderr)
        sys.exit(1)

    cmd = [
        "java",
        "-Djava.awt.headless=true",
        "-cp", digital_jar,
        verifier_java,
        "--circ", circ_path,
        "--hex", hex_path,
        "--cycles", str(args.cycles),
        "--expected", "0x1"
    ]
    if args.verbose:
        cmd.append("--verbose")

    mem_mode = "Mapped CMEM (RAM @ 0x00008000)" if args.cmem else "Harvard (RAM @ 0x00000000)"

    print("=" * 66)
    print("                 i2ca RV32I Core Verifier")
    print("=" * 66)
    print(f"Target Circuit:    {os.path.relpath(circ_path, repo_root)}")
    print(f"Memory Mode:       {mem_mode}")
    print(f"Test Program:      {hex_name}")
    print(f"Max Cycles:        {args.cycles}")
    print("-" * 66)

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except Exception as e:
        print(f"[ERROR] Failed to execute simulation: {e}", file=sys.stderr)
        sys.exit(1)

    if proc.stderr and args.verbose:
        print("[STDERR]", proc.stderr.strip())

    stdout_lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    json_result = None
    for line in reversed(stdout_lines):
        if line.startswith("{") and line.endswith("}"):
            try:
                json_result = json.loads(line)
                break
            except json.JSONDecodeError:
                pass

    if not json_result:
        print(f"[ERROR] Simulator did not return valid result:\n{proc.stdout}\n{proc.stderr}", file=sys.stderr)
        sys.exit(1)

    status = json_result.get("status", "UNKNOWN")
    cycles = json_result.get("cycles", 0)
    ram0 = json_result.get("ram0", 0)
    ram0_hex = json_result.get("ram0_hex", "0x00000000")
    prog_mem = json_result.get("prog_mem", "Unknown")
    ram_desc = json_result.get("ram_desc", "Unknown")

    print(f"Program Memory:    {prog_mem}")
    print(f"Data Memory:       {ram_desc}")
    print(f"Simulation Cycles: {cycles}")
    print(f"Status in RAM[0]:  {ram0_hex} ({ram0})")
    print("-" * 66)

    if status == "PASS":
        print(f"\033[92m>>> RESULT: PASS (All tests passed in {cycles} cycles!)\033[0m")
        print("=" * 66)
        sys.exit(0)
    elif status == "FAIL":
        fail_name = TEST_NAMES.get(ram0, f"Subtest ID {ram0}")
        print(f"\033[91m>>> RESULT: FAIL at {fail_name}\033[0m")
        print(f"Status word {ram0_hex} indicates test failure.")
        print("=" * 66)
        sys.exit(1)
    elif status == "TIMEOUT":
        print(f"\033[93m>>> RESULT: TIMEOUT (Core did not finish within {cycles} cycles)\033[0m")
        print(f"RAM[0] remained {ram0_hex}. Verify clock, reset_n, and PC increment.")
        print("=" * 66)
        sys.exit(1)
    else:
        err = json_result.get("error", "Unknown error")
        print(f"\033[91m>>> RESULT: ERROR: {err}\033[0m")
        print("=" * 66)
        sys.exit(1)

if __name__ == "__main__":
    main()
