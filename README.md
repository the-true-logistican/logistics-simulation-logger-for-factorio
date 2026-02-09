# Logistics Simulation Logger (LogSim)

A Factorio 2.x mod focused on observing and logging factory behavior over time.
This project treats Factorio as a logistics and production simulation, not as a gameplay optimization tool.

Below is the public mod description from the Factorio Mod Portal: [Factory Ledger](https://mods.factorio.com/mod/logistics_simulation)
activities of players which are relevant to accounting are traces by [Big Brother 1984](https://mods.factorio.com/mod/big_brother_1984)


> **"What you cannot measure, you cannot control."** > *(Tom DeMarco)*

**Turn your factory into a data-driven enterprise.**

While most players rely on intuition, **LogSim** allows you to analyze your production like a professional business consultant. It treats your factory as a complex system: capturing "transaction logs" (inventory changes), "sensor data" (machine states), and "environmental impact" (pollution/power) to give you the raw facts needed for deep optimization.

---

## 💼 The Business Intelligence Approach

In the real world of production and logistics, we don't just look at a machine to see if it's running—we analyze the data. **LogSim** follows this professional consultancy philosophy:

1.  **Raw Data Auditing:** Instead of just visual cues, you get precise timestamps and state records (`RUN`, `IDLE`, `NOIN`, `FULL`).
2.  **A/B Testing & Simulation:** Use the built-in **Reset** feature to freeze the factory, clear all buffers (belts, chests, machines), and start a "clean room" test. Compare different designs with 100% objective data.
3.  **Supply Chain Tracking:** Monitor your input/output buffers (chests) to see exactly when and why your logistics chain stutters.

### ⚖️ LogSim vs. Bottleneck
I highly recommend using [Bottleneck Lite](https://mods.factorio.com/mod/BottleneckLite) (or the original [Bottleneck](https://mods.factorio.com/mod/Bottleneck)) alongside this mod!
* **Bottleneck** is your **Real-time Dashboard**: It shows you *where* a problem is right now via colored lights.
* **LogSim** is your **Analytics Suite**: It tells you *how long* the problem existed, *why* it happened (data history), and provides the raw data for Excel/Python analysis.
* *Use Bottleneck to spot the fire; use LogSim to analyze the cause and prevent it from ever happening again.*

---

## 🚀 Key Features

* ⚡ **Power Analysis:** Track grid-wide energy consumption.
* 🏭 **Pollution Tracking:** Monitor environmental impact per second.
* 🔧 **Machine State Logging:** Records states like `RUN`, `IDLE`, `NOIN` (starved), and `FULL` (blocked).
* 📦 **Inventory Monitoring:** High-precision tracking of chest contents and throughput.
* 🧹 **Simulation Reset:** A powerful tool to clear belts, chests, and pollution for standardized testing.

---

## 🛠 How to Use

1.  **Register Entities:** Hover over any chest or machine and press `SHIFT + R`. A marker will appear, and logging starts.
2.  **Protect Assets:** Press `SHIFT + P` to "protect" an entity. These will **not** be cleared during a simulation reset (useful for main supply chests).
3.  **Analyze:** Press `SHIFT + B` to open the Log-Buffer. All data is formatted as easy-to-parse strings: `TICKS;TYPE;ID;DATA`.
4.  **Reset:** Access the Reset menu via the UI to prepare your factory for a new test run.

---

## ⌨️ Hotkeys (Default)

| Key | Action |
|-----|--------|
| **`Shift + B`** | Toggle Log Window |
| **`Shift + R`** | Register Entity for Logging |
| **`Shift + U`** | Unregister (Stop Logging) |
| **`Shift + P`** | Protect from Reset |

---

## 📈 Performance Built-in
LogSim is designed for efficiency. By sampling data only once per second (configurable) and using optimized Lua-handling for the UI buffer, it keeps your UPS stable even when monitoring large-scale production blocks.

## Background & motivation:
This mod is part of a broader exploration of using Factorio as a logistics and systems simulation.
More context here: https://martins-wahre-logistik.blogspot.com/2026/01/using-factorio-as-logistics-simulation.html
