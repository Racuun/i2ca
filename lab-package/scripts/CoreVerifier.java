/*
 * CoreVerifier.java - Headless RV32I Processor Verification Engine for Digital
 * Part of i2ca (Introduction to Computer Architecture) course.
 *
 * Simulates a single-cycle RV32I core without requiring datapath modification
 * or artificial output pins. Directly injects hex program into Program Memory
 * and introspects Data RAM (single 32-bit or 4-bank 8-bit masked RAM) at address 0.
 */

import de.neemann.digital.core.Model;
import de.neemann.digital.core.Node;
import de.neemann.digital.core.Signal;
import de.neemann.digital.core.memory.DataField;
import de.neemann.digital.core.memory.ProgramMemory;
import de.neemann.digital.core.memory.RAMInterface;
import de.neemann.digital.core.memory.ROM;
import de.neemann.digital.core.wiring.Clock;
import de.neemann.digital.draw.elements.Circuit;
import de.neemann.digital.draw.library.ElementLibrary;
import de.neemann.digital.draw.model.ModelCreator;
import de.neemann.digital.draw.shapes.ShapeFactory;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public class CoreVerifier {

    private static class RamBank {
        final RAMInterface ram;
        final int lane;

        RamBank(RAMInterface ram, int lane) {
            this.ram = ram;
            this.lane = lane;
        }
    }

    public static void main(String[] args) {
        String circPath = null;
        String hexPath = null;
        int maxCycles = 2000;
        long expected = 1;
        boolean verbose = false;

        for (int i = 0; i < args.length; i++) {
            if ("--circ".equals(args[i]) && i + 1 < args.length) {
                circPath = args[++i];
            } else if ("--hex".equals(args[i]) && i + 1 < args.length) {
                hexPath = args[++i];
            } else if ("--cycles".equals(args[i]) && i + 1 < args.length) {
                maxCycles = Integer.parseInt(args[++i]);
            } else if ("--expected".equals(args[i]) && i + 1 < args.length) {
                String valStr = args[++i];
                expected = valStr.startsWith("0x") || valStr.startsWith("0X")
                        ? Long.parseUnsignedLong(valStr.substring(2), 16)
                        : Long.parseLong(valStr);
            } else if ("--verbose".equals(args[i]) || "-v".equals(args[i])) {
                verbose = true;
            }
        }

        if (circPath == null || hexPath == null) {
            System.err.println("Usage: java CoreVerifier --circ <circuit.dig> --hex <program.hex> [--cycles 2000] [--expected 1]");
            System.exit(2);
        }

        try {
            runVerification(new File(circPath), new File(hexPath), maxCycles, expected, verbose);
        } catch (Throwable t) {
            System.out.println("{\"status\": \"ERROR\", \"error\": \"" + escapeJson(t.getMessage()) + "\"}");
            t.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static void runVerification(File circFile, File hexFile, int maxCycles, long expected, boolean verbose) throws Exception {
        ElementLibrary lib = new ElementLibrary();
        lib.setRootFilePath(circFile.getParentFile());
        ShapeFactory sf = new ShapeFactory(lib);
        Circuit circuit = Circuit.loadCircuit(circFile, sf);
        ModelCreator mc = new ModelCreator(circuit, lib);
        Model model = mc.createModel(false);

        // 1. Read HEX file
        ArrayList<Long> hexWords = new ArrayList<>();
        try (BufferedReader br = new BufferedReader(new FileReader(hexFile))) {
            String line;
            while ((line = br.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#") || line.startsWith("//") || line.startsWith("v2.0")) continue;
                for (String part : line.split("\\s+")) {
                    if (!part.isEmpty()) hexWords.add(Long.parseUnsignedLong(part, 16));
                }
            }
        }
        long[] code = new long[hexWords.size()];
        for (int i = 0; i < code.length; i++) code[i] = hexWords.get(i);

        // 2. Identify Program Memory (must be 32-bit instruction memory)
        ProgramMemory progMem = null;

        // First pass: look for isProgramMemory flag with 32-bit width
        for (Node n : model.getNodes()) {
            if (n instanceof ProgramMemory) {
                ProgramMemory pm = (ProgramMemory) n;
                if (pm.isProgramMemory() && pm.getDataBits() == 32) {
                    progMem = pm;
                    break;
                }
            }
        }

        // Second pass: look for 32-bit node labeled ROM / Instr / Code
        if (progMem == null) {
            for (Node n : model.getNodes()) {
                if (n instanceof ProgramMemory) {
                    ProgramMemory pm = (ProgramMemory) n;
                    String lbl = pm.getLabel() != null ? pm.getLabel().toLowerCase() : "";
                    if (pm.getDataBits() == 32 && (lbl.equals("rom") || lbl.contains("instr") || lbl.contains("prog") || lbl.contains("code"))) {
                        progMem = pm;
                        break;
                    }
                }
            }
        }

        // Third pass: any ROM with 32 data bits
        if (progMem == null) {
            for (Node n : model.getNodes()) {
                if (n instanceof ROM) {
                    ROM r = (ROM) n;
                    if (r.getDataBits() == 32) {
                        progMem = r;
                        break;
                    }
                }
            }
        }

        // Fallback: any ProgramMemory with 32 data bits
        if (progMem == null) {
            for (Node n : model.getNodes()) {
                if (n instanceof ProgramMemory) {
                    ProgramMemory pm = (ProgramMemory) n;
                    if (pm.getDataBits() == 32) {
                        progMem = pm;
                        break;
                    }
                }
            }
        }

        if (progMem == null) {
            throw new IllegalStateException("No 32-bit Program Memory (ROM / isProgramMemory RAM) found in circuit " + circFile.getName());
        }

        progMem.setProgramMemory(new DataField(code));
        if (progMem instanceof ROM) {
            ((ROM) progMem).setData(new DataField(code));
        }

        // 3. Identify Data RAM (exclude progMem)
        List<RAMInterface> ramCandidates = new ArrayList<>();
        for (Node n : model.getNodes()) {
            if (n instanceof RAMInterface && n != progMem) {
                ramCandidates.add((RAMInterface) n);
            }
        }

        RAMInterface singleRam32 = null;
        List<RamBank> byteBanks = new ArrayList<>();
        String ramDescription;

        // Check for 4-bank masked 8-bit RAM first (e.g. CMEM.dig or Lab 4 Exercise 4.3)
        List<RAMInterface> banks8 = new ArrayList<>();
        for (RAMInterface r : ramCandidates) {
            if (r.getDataBits() == 8) {
                banks8.add(r);
            }
        }

        if (banks8.size() >= 4) {
            for (int i = 0; i < 4; i++) {
                RAMInterface r = banks8.get(i);
                int lane = detectLane(r.getLabel(), i);
                byteBanks.add(new RamBank(r, lane));
            }
            byteBanks.sort(Comparator.comparingInt(b -> b.lane));
            StringBuilder sb = new StringBuilder("4-bank masked 8-bit RAM [");
            for (int i = 0; i < 4; i++) {
                if (i > 0) sb.append(", ");
                sb.append("Lane ").append(byteBanks.get(i).lane).append(": ").append(byteBanks.get(i).ram.getLabel());
            }
            sb.append("]");
            ramDescription = sb.toString();
        } else {
            // Check for 32-bit RAM
            for (RAMInterface r : ramCandidates) {
                String lbl = r.getLabel() != null ? r.getLabel().toLowerCase() : "";
                if (r.getDataBits() == 32 && (lbl.contains("ram") || lbl.contains("data") || lbl.contains("dmem"))) {
                    singleRam32 = r;
                    break;
                }
            }
            if (singleRam32 == null) {
                for (RAMInterface r : ramCandidates) {
                    if (r.getDataBits() == 32) {
                        singleRam32 = r;
                        break;
                    }
                }
            }

            if (singleRam32 != null) {
                ramDescription = "Single 32-bit RAM [" + (singleRam32.getLabel() != null ? singleRam32.getLabel() : "RAM") + "]";
            } else if (!ramCandidates.isEmpty()) {
                singleRam32 = ramCandidates.get(0);
                ramDescription = "RAM [" + singleRam32.getLabel() + ", " + singleRam32.getDataBits() + "-bit]";
            } else {
                throw new IllegalStateException("No Data RAM component found in circuit " + circFile.getName());
            }
        }

        // 4. Initialize model
        model.init();

        // 5. Detect Clock and Reset
        ArrayList<Clock> clocks = model.getClocks();
        Clock clkComp = clocks.isEmpty() ? null : clocks.get(0);
        Signal.Setter clkSetter = (clkComp == null) ? model.getSignalSetter("clk") : null;
        if (clkComp == null && clkSetter == null) clkSetter = model.getSignalSetter("CLK");
        if (clkComp == null && clkSetter == null) clkSetter = model.getSignalSetter("clock");

        Signal.Setter rstNSetter = model.getSignalSetter("rst_n");
        Signal.Setter rstSetter = (rstNSetter == null) ? model.getSignalSetter("rst") : null;
        if (rstNSetter == null && rstSetter == null) rstNSetter = model.getSignalSetter("reset_n");
        if (rstNSetter == null && rstSetter == null) rstSetter = model.getSignalSetter("reset");

        // 6. Reset sequence (2 cycles active)
        if (rstNSetter != null) rstNSetter.set(0, 0);
        if (rstSetter != null) rstSetter.set(1, 0);

        for (int i = 0; i < 2; i++) {
            tickClock(clkComp, clkSetter, model);
        }

        if (rstNSetter != null) rstNSetter.set(1, 0);
        if (rstSetter != null) rstSetter.set(0, 0);
        tickClock(clkComp, clkSetter, model);

        // 7. Simulation loop
        int finalCycle = 0;
        long finalRam0 = 0;
        String status = "TIMEOUT";

        for (int cycle = 1; cycle <= maxCycles; cycle++) {
            tickClock(clkComp, clkSetter, model);

            long ram0 = readRam0(singleRam32, byteBanks);
            if (verbose && (cycle <= 20 || cycle % 100 == 0)) {
                System.err.println("[VERBOSE] Cycle " + cycle + ": RAM[0] = 0x" + Long.toHexString(ram0));
            }

            if (ram0 == expected) {
                status = "PASS";
                finalCycle = cycle;
                finalRam0 = ram0;
                break;
            } else if (ram0 > 1) {
                status = "FAIL";
                finalCycle = cycle;
                finalRam0 = ram0;
                break;
            }
            finalCycle = cycle;
            finalRam0 = ram0;
        }

        // 8. Output JSON result
        System.out.println("{"
                + "\"status\": \"" + status + "\", "
                + "\"cycles\": " + finalCycle + ", "
                + "\"ram0\": " + finalRam0 + ", "
                + "\"ram0_hex\": \"0x" + String.format("%08x", finalRam0) + "\", "
                + "\"expected\": " + expected + ", "
                + "\"expected_hex\": \"0x" + String.format("%08x", expected) + "\", "
                + "\"prog_mem\": \"" + escapeJson(progMem.getLabel()) + "\", "
                + "\"ram_desc\": \"" + escapeJson(ramDescription) + "\""
                + "}");
    }

    private static void tickClock(Clock clkComp, Signal.Setter clkSetter, Model model) throws Exception {
        if (clkComp != null) {
            clkComp.getClockOutput().setValue(0);
            model.doStep();
            clkComp.getClockOutput().setValue(1);
            model.doStep();
        } else if (clkSetter != null) {
            clkSetter.set(0, 0);
            model.doStep();
            clkSetter.set(1, 0);
            model.doStep();
        } else {
            model.doStep();
        }
    }

    private static long readRam0(RAMInterface singleRam32, List<RamBank> byteBanks) {
        if (singleRam32 != null) {
            long[] d = singleRam32.getMemory().getData();
            return (d.length > 0) ? (d[0] & 0xFFFFFFFFL) : 0L;
        }
        if (byteBanks.size() >= 4) {
            long b0 = byteBanks.get(0).ram.getMemory().getData().length > 0 ? byteBanks.get(0).ram.getMemory().getData()[0] & 0xFF : 0;
            long b1 = byteBanks.get(1).ram.getMemory().getData().length > 0 ? byteBanks.get(1).ram.getMemory().getData()[0] & 0xFF : 0;
            long b2 = byteBanks.get(2).ram.getMemory().getData().length > 0 ? byteBanks.get(2).ram.getMemory().getData()[0] & 0xFF : 0;
            long b3 = byteBanks.get(3).ram.getMemory().getData().length > 0 ? byteBanks.get(3).ram.getMemory().getData()[0] & 0xFF : 0;
            return ((b3 << 24) | (b2 << 16) | (b1 << 8) | b0) & 0xFFFFFFFFL;
        }
        return 0L;
    }

    private static int detectLane(String label, int fallback) {
        if (label == null) return fallback;
        String l = label.toLowerCase().trim();
        if (l.contains("24-31") || l.contains("24..31")) return 3;
        if (l.contains("16-23") || l.contains("16..23")) return 2;
        if (l.contains("8-15") || l.contains("8..15")) return 1;
        if (l.contains("0-7") || l.contains("0..7")) return 0;

        if (l.contains("byte3") || l.contains("b3") || l.contains("bank3") || l.contains("lane3")) return 3;
        if (l.contains("byte2") || l.contains("b2") || l.contains("bank2") || l.contains("lane2")) return 2;
        if (l.contains("byte1") || l.contains("b1") || l.contains("bank1") || l.contains("lane1")) return 1;
        if (l.contains("byte0") || l.contains("b0") || l.contains("bank0") || l.contains("lane0")) return 0;

        if (l.matches(".*[^0-9]3$")) return 3;
        if (l.matches(".*[^0-9]2$")) return 2;
        if (l.matches(".*[^0-9]1$")) return 1;
        if (l.matches(".*[^0-9]0$")) return 0;

        return fallback;
    }

    private static String escapeJson(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "");
    }
}
