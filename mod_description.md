# 🔬 Logistics Simulation Logger

**Turn your factory into a science experiment.**

Ever wondered *exactly* why your production line is underperforming? Want hard data to prove your new design is 23% more efficient? Need to compare two layouts side-by-side with *actual numbers*?

**LogSim gives you the data. You make it better.**

---

## 🎯 What It Does

LogSim continuously monitors your factory and logs **everything that matters**:

- ⚡ **Power consumption** - Track energy usage in real-time
- 🏭 **Pollution output** - See your environmental impact per second
- 📦 **Chest contents** - Monitor buffer levels and throughput
- 🔧 **Machine states** - Know exactly when machines are idle, starved, or blocked
- 📊 **Production counts** - Measure actual output, not just recipes

All logged to a **text format** perfect for Excel, Python, or your favorite analysis tool.

---

## 💡 Why You Need This

### 🔍 **Find Bottlenecks Instantly**
No more guessing. See which machines are waiting for input (`NOIN`) or have full outputs (`FULL`). Your bottleneck lights up like a Christmas tree in the data.

### 📈 **Prove Your Optimizations Work**
Changed your belt layout? Tweaked your ratios? Reset, run for 10 minutes, compare the numbers. **Science > guesswork.**

### ⚖️ **A/B Test Factory Designs**
Run Design A, export the data. Run Design B, export again. Which one produces more copper wire per megawatt? *Now you know.*

### 🎓 **Learn How Factorio Really Works**
See the exact moment when pollution spikes. Watch power consumption dip when machines idle. Understand the real performance of your builds.

---

## 🚀 Quick Start (30 Seconds)

1. **Press Shift+B** → Enter a run name (e.g., "BaseDesign_v1")
2. **Hover over entities** → Press **Shift+R** to track them
3. **Let it run** → LogSim records every second
4. **Press Shift+B** → Click "Copy" → Paste into Excel/Python

**Done.** You now have scientific data about your factory.

---

## 🎮 Features That Just Work

### 🔄 **Reproducible Testing**
Built-in **Reset** clears all items, buffers, and pollution in one click. Get a clean starting state for every test run.

### 🛡️ **Protected Entities**
Mark input/output chests as **Protected** (Shift+P) so they survive resets. Keep your test materials safe.

### 📱 **Live Monitoring**
Watch your factory state update in real-time. The buffer window shows the last 20,000 lines with **Live Mode** following new entries automatically.

### 🎨 **Smart Formatting**
Item aliases (`Fe=iron-plate`, `cirG=green-circuits`) keep logs compact. Full prototype IDs when you need precision.

### 🌍 **Multilingual**
Full English and German localization. Designed to be community-translatable.

---

## 📊 What The Data Looks Like

**Compact Format (for files):**
```
1234 tick=67890;PWR:12500;POL=5.32;M01:RUN|Gear=125;C01:Fe=50|Cu=30
```

**Translation:**
- Line 1234 at game tick 67890
- Power: 12.5 kW
- Pollution: 5.32/s
- Machine M01: Running, made 125 gears
- Chest C01: 50 iron plates, 30 copper plates

**Import to Excel → Make graphs → Optimize → Repeat.**

---

## 🛠️ Perfect For...

- 🏆 **Speedrunners** - Optimize every second of your runs
- 🔬 **Theorycrafters** - Test ratio calculations with real data
- 📚 **Content Creators** - Show *proof* your design is better
- 🎯 **Perfectionists** - Because "good enough" isn't good enough
- 🤝 **Multiplayer Teams** - Share objective performance data

---

## 💪 Built for Performance

- **Throttled GUI updates** - No lag even with 10,000+ lines
- **Smart paging** - Navigate huge logs without freezing
- **Minimal tick impact** - Samples once per second (configurable)
- **Memory-safe** - Auto-trims to 20,000 lines max

---

## 🎓 Learning Curve: **Zero**

If you can press Shift+R, you can use LogSim. The rest is just **looking at numbers and making things better**.

---

## 🔮 Coming Soon (Community Requests Welcome!)

- CSV/JSON direct export
- Built-in statistics (average power, peak pollution)
- Entity filters (show only selected machines)
- Trigger-based logging (only log when condition met)

---

## 🤝 Open to Feedback

This mod is built **for the community, by the community**. Found a bug? Want a feature? Open an issue on the mod portal!

---

## 📥 Ready to Optimize?

**Download LogSim** and turn your factory from "it works" to "it works *perfectly*."

*Because in Factorio, if you can't measure it, you can't improve it.*

---

**Version:** 0.5.0  
**Factorio:** 2.0+  
**License:** MIT  
**Source:** [Coming Soon]

---

### 🎮 Hotkeys Quick Reference

| Key | Action |
|-----|--------|
| `Shift+B` | Toggle log window |
| `Shift+R` | Register entity (chest/machine) |
| `Shift+P` | Protect entity from reset |
| `Shift+U` | Unregister entity |

---

*"The factory must grow... efficiently."*