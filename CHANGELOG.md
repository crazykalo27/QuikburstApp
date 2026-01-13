# QuikburstApp Changelog

## [Latest] - Live Variation Bounds Enforcement

### Training View Improvements
- **Robust Live Variation Bounds**: Live variation selector slider now properly enforces bounds set during drill creation
  - Bounds are validated during initialization (min <= max)
  - Slider values are clamped to bounds using a clamped binding
  - Default values (midpoint) calculated from validated bounds
  - Works for both constant force (N) and percentile (%) force types

## [Previous] - Multi-Phase Drill Support

### Drill Creation Flow
- **Refactored Drill Creation Wizard**: Two-step process
  - Step 1: Basics (name, description, video attachment)
  - Step 2: Phase configuration (minimum 1 phase, can add unlimited phases)
- **Phase Configuration**: Each phase can be independently configured with:
  - Drill type (Force or Speed)
  - Motor behavior (Resist/Assist toggles)
  - Target (time for force drills, distance for speed drills)
  - Force type (Constant or Percentile)
  - Torque curve settings
- **Multi-Phase Support**: Users can create drills with multiple sequential phases
  - Each phase can have different drill type, motor behavior, and targets
  - Example: 10-second force drill followed by 40-meter speed drill
  - Phases execute sequentially during drill runs

### Data Model Updates
- **Added `DrillPhase` Structure**: New model for phase configuration
  - Contains all phase-specific settings (type, resist/assist, distance/time, force settings)
  - Each phase has unique ID for tracking
- **Updated `DrillTemplate`**: Now supports both legacy single-phase and new multi-phase formats
  - `phases` array for multi-phase drills
  - Legacy fields maintained for backward compatibility
  - `effectivePhases` computed property handles both formats seamlessly

### Drill Execution
- **Multi-Phase Execution**: MeasuringView now handles phase transitions
  - Tracks current phase index
  - Automatically transitions to next phase when current phase completes
  - Shows phase progress (e.g., "Phase 1 of 3")
  - Displays phase-specific targets and timers
  - Collects samples from all phases for complete drill results
- **Phase Completion Logic**: Each phase completes based on its own criteria
  - Speed drills: Complete when target distance reached or 5 seconds without data
  - Force drills: Complete when target time reached
  - Seamless transition between phases with no user intervention required

### Backward Compatibility
- **Legacy Drill Support**: Existing single-phase drills continue to work
  - Automatically converted to single-phase format using `effectivePhases`
  - No migration required for existing drills
  - All existing functionality preserved

## [Previous] - Progress Tracking Overhaul
- Consolidated drill/workout data stores as shared environment objects so Train, Progress, and Drill tabs stay in sync.
- Session history now records every drill completion (including drills inside workouts) with workout grouping and name snapshots.
- Progress history UI rebuilt with drill rows and grouped workout entries; drill details open the analysis sheet with recorded samples.
- Workout runs add per-drill session results while still saving drill runs for drill-level progress views.

## [Latest] - Modern Design System & UX Enhancements (2024 Design Guide Implementation)

### Design System & Visual Polish
- **Enhanced Theme System**: Upgraded `Theme.swift` with modern 2024 design elements
  - Added adaptive color system with primary/secondary accents
  - Implemented gradient support (primaryGradient, backgroundGradient)
  - Added shadow system for depth and layering
  - Improved typography with Dynamic Type support
  - Added animation constants for micro-interactions
- **Button Hierarchy System**: Created `ButtonStyles.swift` with clear visual hierarchy
  - PrimaryButtonStyle: High-emphasis filled buttons with gradients
  - SecondaryButtonStyle: Medium-emphasis outlined buttons
  - TextButtonStyle: Low-emphasis borderless buttons
  - IconButtonStyle: Quick-action icon buttons
  - All buttons include proper touch targets (44pt minimum) and press animations
- **Micro-interactions & Haptics**: Added `HapticFeedback.swift` utility
  - Light/medium/heavy impact feedback
  - Success/warning/error notifications
  - Selection feedback for UI interactions
  - Convenience methods for common actions (buttonPress, cardTap, workoutComplete)
- **Accessibility Improvements**: Created `AccessibilityHelpers.swift`
  - Accessibility label helpers with proper contrast
  - Minimum touch target enforcement (44x44pt)
  - Dynamic Type support with minimum readable sizes
  - High contrast mode support
  - AccessibleButton component for consistent accessibility

### Gamification & Engagement
- **Achievement System**: Created `Gamification.swift` with full achievement tracking
  - Achievement model with requirements (workouts, drills, streaks, personal bests)
  - UserStats tracking (total workouts, drills, streaks)
  - Streak calculation and maintenance
  - AchievementStore for persistence
  - Default achievements: First Steps, Getting Started, Dedicated, Week Warrior, On Fire
- **Celebration Views**: Added delightful celebration animations
  - AchievementUnlocked celebration with animations
  - Generic success celebrations
  - Auto-dismissing with smooth animations
  - Haptic feedback integration
- **Streak Indicator Component**: Visual streak display
  - Current streak with flame icon
  - Longest streak tracking
  - Accessible labels for screen readers

### Design Principles Applied
- **Modern High-End Look**: Clean, minimalist aesthetic with bold typography
- **Progressive Disclosure**: Foundation laid for progressive disclosure patterns
- **Accessibility First**: WCAG-compliant components with proper contrast and sizing
- **Micro-interactions**: Smooth animations and haptic feedback throughout
- **Button Hierarchy**: Clear visual hierarchy following Material Design and iOS HIG

## [Previous] - Bluetooth Pairing Fix, User Selection, Drill Editing Fixes, Connection Indicator, Default Tab

### Navigation & UX
- **Default Tab on Login**: Changed default tab to Train tab so users land on the Train screen after signing in
- **Preferences Navigation**: Preferences button in ProfilesTabView now navigates to SettingsView
- **Dark Mode Support**: Implemented functional dark mode toggle in Settings that applies system-wide dark color scheme

### Bluetooth & Device Management
- **Fixed Device Pairing Button**: Device Pairing button in ProfilesTabView now properly navigates to BluetoothConsoleView for scanning and connecting to devices
- **Bluetooth Functionality Verified**: Scanning, connection, and device management functionality confirmed working
- **Connection Indicator on Train Screen**: Added visual Bluetooth connection indicator in the Train tab navigation bar showing connection status (connected/disconnected/connecting) with device name when connected
- **Improved Scan Button Visibility**: Made scan button always visible and more prominent in BluetoothConsoleView with better state handling and messaging for when Bluetooth is unavailable

### User Management
- **Multiple User Support**: Added user selection dropdown in ProfilesTabView allowing users to switch between multiple user profiles
- **User Selection UI**: Menu-based user selection with visual indicator for currently selected user
- **Add User**: Quick access to add new users directly from the Profiles tab

### Workout & Drill Management
- **Fixed Drill Editing in Workouts**: WorkoutItemEditorRow now observes DrillStore to automatically update when drills are edited, ensuring drill changes persist in workouts
- **Missing Drill Handling**: Added graceful handling for missing drills in workouts (shows placeholder instead of disappearing)
- **Drill Reference Persistence**: Ensured workout items maintain drill references even when drills are edited
- **Fixed Button Overlap**: Added proper spacing between edit and delete buttons in workout drill items to prevent overlap
- **Rest Periods Between Drills**: Added ability to insert rest periods as separate items between drills in workouts, with dedicated UI for adding and editing rest periods

## [Previous] - Major UI Overhaul: Custom Tab Bar, Drill/Workout System, Train State Machine

### Architecture & Design System
- **Created `Theme.swift`**: Centralized design system with primary colors (Orange #FEA705, Deep Blue #041E34), typography tokens, and spacing constants
- **Custom Expanding Tab Bar**: Replaced default TabView with custom animated tab bar featuring 4 tabs (Drill, Train, Progress, Profiles) with expanding selected state

### Data Models & Stores
- **New Models** (`Models.swift`):
  - `Drill`: Core drill model with category (speed/force), resistive/assistive flags, length, torque profile reference
  - `Workout`: Collection of workout items with ordering
  - `WorkoutItem`: Links drills to workouts with reps, rest time, and optional level
  - `SessionResult`: Stores completed session data with ESP32 samples and derived metrics
  - `SessionMetrics`: Lightweight computed results (peak force, average force, duration)
- **New Stores**:
  - `DrillStore`: Manages drill persistence with seed data ("20 Yard Dash" built-in drill)
  - `WorkoutStore`: Manages workout persistence
  - `SessionResultStore`: Manages session history persistence

### Drill Tab (Catalog & Editor)
- **DrillTabView**: Main catalog interface with segmented control (Drills/Workouts)
- **Search & Filters**: Text search with filter sheet (placeholder for advanced filtering)
- **Drill Catalog**: List view showing name, category badge, favorite/custom indicators, length
- **Workout Catalog**: List view showing name, item count, custom/favorite indicators
- **Drill Detail View**: Shows drill properties with "Start in Train" and "Edit" actions
- **Workout Detail View**: Shows workout items with drill details, reps, rest times
- **Drill Editor**: Multi-step form with name, category, length, resistive/assistive toggles, torque curve selection
- **Torque Curve Integration**: Links to torque profile editor (reuses existing ProfileEditorView pattern)
- **Workout Builder**: Create/edit workouts with drill picker, reorderable items, reps/rest/level configuration

### Train Tab (State Machine)
- **TrainTabView**: Complete state machine implementation with 10 states:
  - `idle` → `selectingMode` → `selectingItem` → `selectingLevel` (drills only) → `readyHold` → `countdown` → `measuring` → `resting` (workouts) → `results` / `aborted`
- **Mode Selection**: Choose Single Drill or Workout
- **Item Selection**: Pick drill or workout from catalog
- **Level Selection**: 1-5 level picker for drills (segmented control)
- **Hold-to-Start**: 3-second press-and-hold with progress ring and haptic feedback
- **Countdown**: 5-4-3-2-1 countdown with audio beeps (placeholder for audio implementation)
- **Measuring Screen**: Live chart display using ESP32 data stream, duration timer, large RED ABORT button
- **Workout Execution**: Drill-by-drill with automatic rest timers, skip rest option, auto-progression
- **Results Screen**: Shows session metrics (peak force, average force, duration), "Done" and "Start Again" options
- **Abort Handling**: Graceful abort with return to Train root

### Progress Tab
- **ProgressTabView**: History and trend visualization
- **Filters**: By type (All/Drills/Workouts), by drill/workout, by date range (All/Week/Month/Year)
- **Charts**: Line charts showing peak force trends over time (using Swift Charts)
- **History List**: Grouped by date with drill/workout name, time, level, peak force metrics
- **Empty State**: Helpful message when no progress data exists

### Profiles Tab
- **ProfilesTabView**: Simplified placeholder with user profile card
- Shows selected user name, height, weight, age
- "Edit Profile" button linking to existing UserEditView
- Future hooks: Device pairing, preferences (placeholder rows)

### Integration
- **ESP32 Data Stream**: Wrapped in protocol interface - Train tab subscribes to live samples via DataStreamViewModel
- **BluetoothManager**: Existing implementation preserved, used by Train tab for START/STOP commands
- **MainContentView**: New root view using custom tab bar container
- **Navigation**: NavigationStack within each tab root for drill/workout detail flows

### Technical Notes
- All stores use UserDefaults for persistence (can be swapped for Core Data/Realm later)
- State machines are deterministic and testable
- UI components are modular and reusable
- Design system ensures consistent theming throughout app

## [Previous] - Encoder + Bluetooth Integration

### Arduino Changes
- **Created `bluetooth_encoder.ino`**: Combined encoder reading and BLE communication
  - Integrates PCNT encoder reading from `encoderread.ino` with BLE server from `bluetooth.ino`
  - Sends live encoder data as CSV format (`time_ms,counts`) over BLE at 100ms intervals
  - Responds to START/STOP/RESET commands from the app
  - Maintains encoder overflow handling for 32-bit count range

### iOS App Changes
- **Updated `BluetoothManager`**: Enhanced data parsing
  - Parses CSV format (`time_ms,counts`) from encoder data
  - Filters out control messages (TRIAL_STARTED, QUICKBURST_READY, etc.)
  - Falls back to single numeric value parsing for compatibility

- **Updated `LiveChartView`**: Added command sending
  - Start button now sends "START" command to Arduino before starting data stream
  - Stop button sends "STOP" command to Arduino before stopping data stream
  - Maintains existing chart display functionality

### Data Flow
1. App connects to ESP32 via BLE
2. User taps "Start" → App sends "START" command → Arduino begins sampling encoder
3. Arduino sends CSV data (`time_ms,counts`) every 100ms over BLE
4. App parses data and displays encoder counts in real-time chart
5. User taps "Stop" → App sends "STOP" command → Arduino stops sampling
