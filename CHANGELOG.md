# QuikburstApp Changelog

## [Latest] - Encoder + Bluetooth Integration

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
