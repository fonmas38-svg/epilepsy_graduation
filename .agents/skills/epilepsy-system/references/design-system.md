# Modern Health-Tech Design System Specification

Official visual and interaction design specification for the `epilepsy_graduation_project` cross-platform patient, caregiver, and doctor ecosystem.

---

## 1. Visual Identity & Foundations

### 1.1 Color Palette

| Token | Light Value | Dark Value | Usage |
|---|---|---|---|
| **Background (Scaffold)** | `#F6F9FD` | `#101A2B` | Clean, clinical canvas reducing visual noise |
| **Surface (Card)** | `#FFFFFF` | `#172338` | Rounded elevated cards with hairline borders |
| **Primary Brand Blue** | `#0066FF` | `#4D94FF` | Interactive buttons, active indicators, highlights |
| **Hero Gradient Start** | `#003B94` | `#0A2540` | Deep royal blue for monitoring cards |
| **Hero Gradient End** | `#0070F3` | `#0051B3` | Radiant cyan-blue gradient edge |
| **Text Primary (Headings)** | `#0D253C` | `#F1F5F9` | High contrast, authoritative clinical typography |
| **Text Secondary (Subtitles)** | `#64748B` | `#94A3B8` | Subtle metadata, timestamps, units |
| **Card Border Hairline** | `#E4EDF7` (1.2px) | `#233550` | Soft boundary definition without visual clutter |

### 1.2 Semantic Risk & Status Palette

| Risk Level | Solid Fill | Container (Pastel) | Foreground | Border | Semantic Meaning |
|---|---|---|---|---|---|
| **Safe / Normal** | `#0F7A4D` | `#E8F5E9` | `#0B5D3B` | `#A7F3D0` | Stable rhythm, baseline EEG, verified sync |
| **Caution / Low-Med** | `#D97706` | `#FEF3C7` | `#92400E` | `#FDE68A` | Elevated probability, trigger logged, pending |
| **Danger / High Risk**| `#E11D48` | `#FFF1F2` | `#9F1239` | `#FECDD3` | Imminent seizure, active emergency, SOS |
| **Neutral / Info** | `#0066FF` | `#EFF6FF` | `#1E40AF` | `#BFDBFE` | Educational note, dose recorded, server |

---

## 2. Core Visual Components

### 2.1 Smart Monitoring Hero Card (`_SmartMonitoringHeroCard`)
- **Dimensions & Radius:** Height ~150–160dp, `BorderRadius.circular(22)`.
- **Background:** Linear gradient from `0xFF003B94` (30%) to `0xFF0070F3` (100%) at angle `Alignment.topLeft` to `Alignment.bottomRight`.
- **Left Column:**
  - Live pulse row: 10dp circle (`#00E676`) with radial glow shadow, accompanied by "المراقبة الذكية نشطة" in 17px bold white text.
  - Subtitle: "يتم تحليل إشارات EEG في الوقت الحقيقي" in 13.5px translucent white (`0xD9FFFFFF`) with 1.4 line height.
- **Right Column (Custom Vector `BrainEegPainter`):**
  - Profile silhouette: Vector head profile drawn in soft cyan translucency (`0x3364B5F6`).
  - Cerebral cortex: Semi-elliptical lobes with radiating neural nodes (`Color(0xFF64B5F6)` and `#00E5FF`).
  - Focal active cluster: Multi-layer radial glow node (`0xFF00E5FF` & `#FFD600`) representing localized detection.
  - Live EEG sparkline: Sine-wave with sharp spikes (`0x80FFFFFF`) representing real-time microvolt activity.

### 2.2 Donut Risk Gauge (`_SeizureProbabilityCard` & `DonutGaugePainter`)
- **Geometry:** Diameter 72dp, stroke width 8dp, background track `theme.colorScheme.outlineVariant` (Light reference `#E4EDF7`).
- **Progress Arc:** Custom sweep gradient or solid risk color (`#0066FF` / `#059669` / `#D97706` / `#E11D48` via `AppColors`) mapped to `preictalProb`.
- **Center Text:** Integer percentage (e.g., `12%`), 17px, bold (`FontWeight.w800`), `theme.colorScheme.onSurface` (Light reference `#0D253C`).
- **Companion Status:** Risk label ("منخفضة", "متوسطة", "مرتفعة") with clinical reassuring subtitle.

### 2.3 Pastel Squircle Quick-Action Tiles (`_PastelQuickActionsRow`)
- **Grid / Row:** 4 items (`مراقبة مباشرة`, `السجل`, `التنبيهات`, `المزيد`).
- **Tile Styling:** 
  - Container size: ~62×62dp squircle with `BorderRadius.circular(18)`.
  - Semantic container/foreground pairings via `Theme.of(context)` / `AppColors` (Light reference values shown; supply Dark equivalents in `AppTheme.darkTheme`):
    - Live Monitoring: `#EBF5FF` bg with `#0066FF` icon.
    - History: `#F0F4FF` bg with `#3B82F6` icon.
    - Alerts: `#FFF1F2` bg with `#E11D48` icon.
    - More Tools: `#F1F5F9` bg with `#475569` icon.
  - Label: 12px bold typography (`theme.colorScheme.onSurface`).

### 2.4 Form & Input Standard
- **Text Form Fields:**
  - `filled: true`, `fillColor: theme.colorScheme.surfaceContainerLowest` (Light) or `theme.colorScheme.surfaceContainerHighest` (Dark) — derive via `Theme.of(context)` / `inputDecorationTheme`, never hardcoded `Colors.white`.
  - `BorderRadius.circular(16)`.
  - Border: `theme.colorScheme.outlineVariant` (`#E4EDF7` light / `#233550` dark) 1.2px (unfocused), `theme.colorScheme.primary` 1.5px (focused).
  - Prefix icon container: Dedicated 38×38dp pastel squircle with primary icon.
- **Action Buttons:**
  - Height: Minimum 52dp (meeting touch floor).
  - Shape: `RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))`.
  - Background: `theme.colorScheme.primary` (primary) or `theme.colorScheme.surface` with `theme.colorScheme.outlineVariant` border (outlined).

---

## 3. Theme Token Enforcement, Time Display & Medical Safety Rules

1. **Zero Hardcoded Screen Colors (Light/Dark Parity):**
   - The palette tokens in Section 1 live in `AppColors` / `AppTheme` (`ThemeData` + `ColorScheme`). Feature screens (`mobile/lib/features/**`) must **never** hardcode `Colors.white`, `Colors.black`, `Color(0xFFF6F9FD)`, `Color(0xFF0D253C)`, or `Colors.grey[...]` (the 2026-11-20 audit cataloged 139 theme-breaking literals across 19 screens, out of 587 total `Colors.*`/`Color(0x...)` literals in `mobile/lib/`—508 in `features/**`, 73 in `core/**`, 6 in `widgets/**`).
   - Map surfaces to `theme.colorScheme.surface`, cards to `theme.cardTheme.color` / `theme.colorScheme.surfaceContainerLow`, and typography to `theme.colorScheme.onSurface` / `onSurfaceVariant`.
2. **Reduced Motion & Photosensitive Epilepsy Safety (WCAG 2.2 SC 2.3.1):**
   - Grounded in **W3C WCAG 2.2 Success Criterion 2.3.1 (Three Flashes or Below Threshold)**: no UI component, chart pulse, alert indicator, or route/theme transition may flash more than **3 times in any 1-second period**, nor violate general flash or saturated red flash thresholds.
   - Wrap theme switching in `AnimatedTheme` with bounded duration (respecting `AppMotion.duration()` and collapsing to `Duration.zero` when `MediaQuery.disableAnimations` is set) and avoid sudden pure-white (`#FFFFFF`) to dark-slate (`#101A2B` / `#121824`) FOUC flashes during route navigation.
3. **WCAG AA Compliance (≥ 4.5:1 Contrast):**
   - Verify ≥ 4.5:1 contrast in both Light and Dark themes (`#F1F5F9` on `#101A2B`/`#172338` in Dark Mode; `#0D253C` on `#F6F9FD`/`#FFFFFF` in Light Mode).
   - No color-alone state indication: Every risk state must pair color with both an icon and a localized text label.
4. **12-Hour Time Display & Right-to-Left (RTL) Support:**
   - Standardize all clinical timestamps, alert logs, chat headers, and medication schedules to **12-hour AM/PM** (`DateFormat.jm('ar')` rendering `ص` / `م`, and `jm('en')` rendering `AM` / `PM`)—never raw 24-hour `HH:mm`.
   - Arabic typography defaults to system Arabic fonts (Cairo/Roboto fallback) with directional chevron flips and margin alignment.
5. **Touch Target Dimensions:**
   - Minimum standard interactive target: 48×48dp (`A11y.minTouchTarget`).
   - Emergency SOS target: Minimum 72dp (`A11y.emergencyTouchTarget`) so it can be pressed during auras or trembling.
