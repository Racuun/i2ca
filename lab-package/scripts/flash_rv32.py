#!/usr/bin/env python3
"""
flash_rv32.py - Programator UART dla procesora RISC-V (RV32I) na FPGA Nexys 4 DDR
Obsługuje wgrywanie plików .s, .c, .elf, .bin, .hex zgodnie z protokołem sprzętowym:
  -> 100ms LOW (Break)
  <- READY (0xAA)
  -> SET_ADDR (0x41) + ADDR x4 (little-endian)
  <- ACK (0x5A)
  -> WRITE_DATA (0x44) + DATA x4 (little-endian)
  <- ACK (0x5A) [auto-increment addr + 4]
  ...
  -> DONE (0x96)
  <- DONE (0x96) [start procesora]
"""

import argparse
import glob
import os
import struct
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    print("[ERROR] Brak biblioteki pyserial. Zainstaluj ja poleceniem: pip install pyserial")
    sys.exit(1)

# Kody komunikatów protokołu UART
READY_MSG      = 0xAA
SET_ADDR_MSG   = 0x41
WRITE_DATA_MSG = 0x44
ACK_MSG        = 0x5A
NACK_MSG       = 0xA5
TIMEOUT_MSG    = 0x69
DONE_MSG       = 0x96
PING_MSG       = 0x55

def autodetect_port():
    """Automatyczne wykrywanie portu UART (na Nexys 4 DDR domyślnie ttyUSB1)."""
    ports = sorted(glob.glob('/dev/ttyUSB*') + glob.glob('/dev/ttyACM*'))
    if sys.platform.startswith('win'):
        ports = [f"COM{i}" for i in range(1, 256)]
    
    if not ports:
        return None
    # Na układach FT2232 (Nexys 4 DDR) port 0 to JTAG, a port 1 to UART
    if len(ports) >= 2 and 'ttyUSB1' in ports[1]:
        return ports[1]
    return ports[0]

def compile_source(src_path, output_bin="build/program.bin"):
    """Kompiluje kod źródłowy .s lub .c za pomocą riscv32-gcc."""
    os.makedirs("build", exist_ok=True)
    elf_path = "build/program.elf"

    cmd_gcc = [
        "riscv32-unknown-elf-gcc",
        "-march=rv32i_zicsr", "-mabi=ilp32",
        "-static", "-mcmodel=medany",
        "-fvisibility=hidden", "-nostdlib", "-nostartfiles",
        "-T", "linker.ld" if os.path.exists("linker.ld") else "tests_rv32i/env/link.ld",
        src_path,
        "-o", elf_path
    ]
    
    print(f"[COMP] Kompilacja {src_path} -> {elf_path}...")
    res = subprocess.run(cmd_gcc, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[ERROR] Blad kompilacji GCC:\n{res.stderr}")
        sys.exit(1)

    cmd_objcopy = [
        "riscv32-unknown-elf-objcopy",
        "-O", "binary",
        elf_path, output_bin
    ]
    print(f"[COMP] Ekstrakcja binariow do {output_bin}...")
    res = subprocess.run(cmd_objcopy, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[ERROR] Blad objcopy:\n{res.stderr}")
        sys.exit(1)

    return output_bin

def read_words_from_file(file_path):
    """Wczytuje 32-bitowe słowa instrukcji z pliku (.s, .c, .elf, .bin, .hex)."""
    ext = os.path.splitext(file_path)[1].lower()

    if ext in ['.s', '.c']:
        bin_file = compile_source(file_path)
        return read_words_from_file(bin_file)

    elif ext == '.elf':
        bin_file = "build/program.bin"
        subprocess.run(["riscv32-unknown-elf-objcopy", "-O", "binary", file_path, bin_file], check=True)
        return read_words_from_file(bin_file)

    elif ext == '.hex':
        words = []
        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    words.append(int(line, 16))
        return words

    else:
        words = []
        with open(file_path, 'rb') as f:
            data = f.read()
            if len(data) % 4 != 0:
                data += b'\x00' * (4 - (len(data) % 4))
            for i in range(0, len(data), 4):
                val = struct.unpack('<I', data[i:i+4])[0]
                words.append(val)
        return words

def flash_fpga(port, baudrate, words, base_addr=0x00000000):
    """Realizacja protokołu programatora UART z obsługą błędów i ponowień."""
    print(f"\n[UART] Otwieranie portu {port} (Baudrate: {baudrate}, 8E1)...")
    try:
        ser = serial.Serial(
            port=port,
            baudrate=baudrate,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_EVEN,
            stopbits=serial.STOPBITS_ONE,
            timeout=1.5
        )
    except Exception as e:
        print(f"[ERROR] Nie mozna otworzyc portu {port}: {e}")
        sys.exit(1)

    # Czyszczenie buforów przed startem
    ser.reset_input_buffer()
    ser.reset_output_buffer()

    # KROK 1: Impuls Break (120 ms stanu LOW) w celu wybudzenia programatora
    print("[KROK 1] Wysylanie impulsu BREAK (120 ms LOW)...")
    ser.break_condition = True
    time.sleep(0.12)
    ser.break_condition = False
    
    # Oczekiwanie na READY (0xAA)
    rx = ser.read(1)
    if not rx or rx[0] != READY_MSG:
        recv_hex = f"0x{rx[0]:02X}" if rx else "TIMEOUT"
        print(f"[WARN] Brak odpowiedzi READY (0xAA), odebrano: {recv_hex}")
        print("       (Sprawdz czy FPGA ma wgrany bitstream i czy wybrano wlasciwy port)")
    else:
        print("[KROK 1] Odebrano READY (0xAA) -> Programator gotowy!")

    def send_packet_with_pacing(cmd, payload_bytes):
        """Wysyła bajt komendy i kolejne bajty z małym odstępem dla synchronizacji."""
        ser.write(bytes([cmd]))
        time.sleep(0.002)
        for b in payload_bytes:
            ser.write(bytes([b]))
            time.sleep(0.002)

    # KROK 2: Ustawienie adresu startowego (SET_ADDR 0x41 + 4 bajty adresu)
    print(f"[KROK 2] Ustawianie adresu bazowego: 0x{base_addr:08X}...")
    addr_bytes = struct.pack('<I', base_addr)
    
    retries = 3
    addr_ok = False
    while retries > 0 and not addr_ok:
        send_packet_with_pacing(SET_ADDR_MSG, addr_bytes)
        rx = ser.read(1)
        if rx and rx[0] == ACK_MSG:
            addr_ok = True
        elif rx and rx[0] == NACK_MSG:
            print("[WARN] Odebrano NACK przy SET_ADDR, ponawiam...")
            retries -= 1
            time.sleep(0.02)
        else:
            recv_hex = f"0x{rx[0]:02X}" if rx else "TIMEOUT"
            print(f"[ERROR] Brak ACK po SET_ADDR, odebrano: {recv_hex}")
            ser.close()
            sys.exit(1)

    if not addr_ok:
        print("[ERROR] Nie udalo sie ustawic adresu bazowego po 3 probach.")
        ser.close()
        sys.exit(1)
    print("[KROK 2] Odebrano ACK (0x5A) -> Adres ustawiony!")

    # KROK 3: Wgrywanie słów (WRITE_DATA 0x44 + 4 bajty danych)
    total_words = len(words)
    print(f"[KROK 3] Wgrywanie {total_words} slow ({total_words * 4} bajtow)...")
    
    start_time = time.time()
    for idx, word in enumerate(words):
        word_bytes = struct.pack('<I', word)
        
        # Próba zapisu z ewentualnym ponowieniem przy NACK
        retries = 3
        success = False
        while retries > 0 and not success:
            send_packet_with_pacing(WRITE_DATA_MSG, word_bytes)
            rx = ser.read(1)
            
            if rx and rx[0] == ACK_MSG:
                success = True
            elif rx and rx[0] == NACK_MSG:
                print(f"\n[WARN] Odebrano NACK przy slowie #{idx} (0x{word:08X}), ponawiam...")
                retries -= 1
                time.sleep(0.02)
            else:
                recv_hex = f"0x{rx[0]:02X}" if rx else "TIMEOUT"
                print(f"\n[ERROR] Blad zapisu slowa #{idx} (0x{word:08X}), odebrano: {recv_hex}")
                ser.close()
                sys.exit(1)

        if not success:
            print(f"\n[ERROR] Przekroczono limit prob zapisu slowa #{idx}.")
            ser.close()
            sys.exit(1)

        # Aktualizacja paska postępu
        progress = (idx + 1) / total_words * 100
        bar = ('=' * int(progress // 2)).ljust(50)
        sys.stdout.write(f"\r  Postep: [{bar}] {progress:5.1f}% ({idx+1}/{total_words})")
        sys.stdout.flush()

    elapsed = time.time() - start_time
    rate = (total_words * 4) / elapsed if elapsed > 0 else 0
    print(f"\n[KROK 3] Wgrano {total_words * 4} bajtow w {elapsed:.2f}s ({rate:.1f} B/s)")

    # KROK 4: Zakończenie programowania (DONE 0x96)
    print("[KROK 4] Wysylanie DONE (0x96) -> Start procesora...")
    ser.write(bytes([DONE_MSG]))
    
    rx = ser.read(1)
    if rx and rx[0] == DONE_MSG:
        print("[KROK 4] Odebrano DONE (0x96) -> Procesor wystartowal pomyslnie!\n")
    else:
        recv_hex = f"0x{rx[0]:02X}" if rx else "TIMEOUT"
        print(f"[WARN] Brak potwierdzenia DONE, odebrano: {recv_hex}")

    ser.close()

def main():
    parser = argparse.ArgumentParser(description="Programator UART dla procesora RISC-V (RV32I) na FPGA")
    parser.add_argument("file", help="Plik z kodem (.s, .c, .elf, .bin, .hex)")
    parser.add_argument("-p", "--port", default=None, help="Port szeregowy (domyslnie autodetekcja, np. /dev/ttyUSB1)")
    parser.add_argument("-b", "--baud", type=int, default=9600, help="Predkosc UART (domyslnie 9600)")
    parser.add_argument("-a", "--addr", type=lambda x: int(x, 0), default=0x00000000, help="Adres poczatkowy (domyslnie 0x00000000)")

    args = parser.parse_args()

    port = args.port or autodetect_port()
    if not port:
        print("[ERROR] Nie wykryto zadnego portu szeregowego. Podaj go recznie przez -p /dev/ttyUSBx")
        sys.exit(1)

    print("=======================================================")
    print("   PROGRAMATOR UART DLA PROCESORA RISC-V (RV32I)")
    print("=======================================================")
    print(f"Plik programu: {args.file}")
    print(f"Port UART:     {port}")
    print(f"Baudrate:      {args.baud} (8E1)")
    print(f"Adres bazowy:  0x{args.addr:08X}")

    words = read_words_from_file(args.file)
    flash_fpga(port, args.baud, words, args.addr)
    print("[SUCCESS] Programowanie zakonczone sukcesem!")

if __name__ == "__main__":
    main()
