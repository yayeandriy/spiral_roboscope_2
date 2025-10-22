# Settings System

## Overview

Centralized configuration system for scan registration with preset profiles and real-time performance estimates.

## Implementation

### Files Created

1. **`roboscope2/Models/AppSettings.swift`**
   - Singleton settings manager with `@Published` properties
   - UserDefaults persistence for all settings
   - Preset system (Fast/Balanced/Accurate/Custom)
   - Default values matching optimized performance parameters

2. **`roboscope2/Views/SettingsView.swift`**
   - Full settings UI with sections for presets, point clouds, ICP, performance, and debug
   - Real-time performance estimates based on current configuration
   - Preset descriptions with use cases
   - Reset to defaults functionality

### Files Modified

1. **`roboscope2/Views/MainTabView.swift`**
   - Replaced `SettingsPlaceholderView` with `SettingsView`
   - Removed unused placeholder

2. **`roboscope2/Views/SessionScanView.swift`**
   - Added `@StateObject private var settings = AppSettings.shared`
   - Updated point cloud extraction to use `settings.modelPointsSampleCount` and `settings.scanPointsSampleCount`
   - Updated ICP registration to use `settings.maxICPIterations` and `settings.icpConvergenceThreshold`
   - Conditionally pause AR based on `settings.pauseARDuringRegistration`
   - Conditionally load models in background based on `settings.useBackgroundLoading`
   - Skip consistency checks based on `settings.skipModelConsistencyChecks`
   - Show performance logs based on `settings.showPerformanceLogs`

3. **`roboscope2/Views/Space3DViewer.swift`**
   - Added `@StateObject private var settings = AppSettings.shared`
   - Updated point cloud extraction and ICP parameters to use settings
   - Ensures consistent behavior between Session and Space registration

4. **`docs/SESSION_SCAN_REGISTRATION.md`**
   - Added comprehensive Settings & Configuration section
   - Documented all presets and parameters
   - Added settings integration examples
   - Updated version history

## Settings Parameters

### Registration Presets

| Preset | Model Points | Scan Points | Iterations | Threshold | Time | RMSE |
|--------|--------------|-------------|------------|-----------|------|------|
| **Fast** | 3,000 | 7,000 | 20 | 0.002 | ~10-15s | < 0.15m |
| **Balanced** | 5,000 | 10,000 | 30 | 0.001 | ~15-25s | < 0.10m |
| **Accurate** | 10,000 | 20,000 | 50 | 0.0001 | ~30-40s | < 0.05m |
| **Custom** | User-defined | User-defined | User-defined | User-defined | Varies | Varies |

### Point Cloud Sampling

- **`modelPointsSampleCount`**: 1,000 - 20,000 (default: 5,000)
  - Points sampled from Space USDC model
  - Higher values improve accuracy but slow down registration
  
- **`scanPointsSampleCount`**: 1,000 - 30,000 (default: 10,000)
  - Points sampled from AR mesh scan
  - Should be higher than model points for better coverage

### ICP Algorithm

- **`maxICPIterations`**: 10 - 100 (default: 30)
  - Maximum iterations for Iterative Closest Point algorithm
  - More iterations = better convergence but longer time
  
- **`icpConvergenceThreshold`**: 0.0001 - 0.005 (default: 0.001)
  - Early exit when change between iterations falls below threshold
  - Lower = more precise but may not converge quickly

### Performance Optimizations

- **`pauseARDuringRegistration`**: Bool (default: true)
  - Pauses ARKit session during registration
  - Frees 30-40% CPU/GPU resources
  - Significantly speeds up registration
  
- **`useBackgroundLoading`**: Bool (default: true)
  - Loads USDC and OBJ files on background thread
  - Keeps UI responsive
  - No performance penalty
  
- **`skipModelConsistencyChecks`**: Bool (default: true)
  - Skips SceneKit validation checks when loading
  - Faster loading times
  - Safe for trusted model sources

### Debug

- **`showPerformanceLogs`**: Bool (default: false)
  - Enables detailed console logging for each registration step
  - Shows timing breakdown and point counts
  - Useful for optimization and debugging

## Usage

### In Settings UI

1. Open app → Navigate to Settings tab
2. Select a preset or customize individual parameters
3. Changes apply immediately to both Session and Space registration
4. View real-time performance estimates
5. Reset to defaults if needed

### Programmatically

```swift
// Access shared instance
let settings = AppSettings.shared

// Read current values
let modelPoints = settings.modelPointsSampleCount
let iterations = settings.maxICPIterations

// Apply a preset
settings.applyPreset(.fast)  // Quick alignment
settings.applyPreset(.balanced)  // Recommended
settings.applyPreset(.accurate)  // Maximum precision

// Custom configuration
settings.modelPointsSampleCount = 7000
settings.scanPointsSampleCount = 15000
settings.maxICPIterations = 40
settings.icpConvergenceThreshold = 0.0005

// Enable debug logging
settings.showPerformanceLogs = true
```

### In Registration Code

Settings are automatically used in both:
- `SessionScanView.performSpaceRegistration()` - Session scanning
- `Space3DViewer.performRegistration()` - Space model registration

```swift
// Example from SessionScanView
@StateObject private var settings = AppSettings.shared

// Point cloud extraction uses settings
let modelPoints = ModelRegistrationService.extractPointCloud(
    from: modelNode,
    sampleCount: settings.modelPointsSampleCount
)
let scanPoints = ModelRegistrationService.extractPointCloud(
    from: scanNode,
    sampleCount: settings.scanPointsSampleCount
)

// ICP registration uses settings
let result = await ModelRegistrationService.registerModels(
    modelPoints: modelPoints,
    scanPoints: scanPoints,
    maxIterations: settings.maxICPIterations,
    convergenceThreshold: settings.icpConvergenceThreshold
)

// Performance optimizations use settings
if settings.pauseARDuringRegistration {
    captureSession.session.pause()
}
```

## UI Design

### Preset Section
- Picker for Fast/Balanced/Accurate/Custom
- Dynamic description based on selected preset
- Auto-applies preset values when changed

### Point Cloud Section
- Steppers with 1000-point increments
- Current value display below each stepper
- Footer explaining impact of higher values

### ICP Section
- Stepper for iterations (5-iteration increments)
- Picker for threshold with labeled values
- Current threshold display

### Performance Section
- Three toggles with descriptions
- Explanations of resource savings
- Footer with recommendations

### Debug Section
- Performance logs toggle
- Hidden unless needed

### Info Section
- Real-time estimated time calculation
- Expected RMSE and accuracy ratings
- Updates when any parameter changes

### Reset Section
- Red destructive-style button
- Confirmation alert before resetting

## Performance Estimates

The UI calculates estimates based on:

**Time Estimation**:
```
baseTime = 8s (download + export + load)
pointsTime = (modelPoints + scanPoints) / 2000
iterationsTime = maxIterations * 0.2s
totalTime = baseTime + pointsTime + iterationsTime
```

**RMSE Estimation**:
- threshold ≤ 0.0001: < 0.05m (Excellent)
- threshold ≤ 0.001: < 0.10m (Good)
- threshold > 0.001: < 0.15m (Acceptable)

**Accuracy Estimation**:
- points ≥ 20,000: Very High
- points ≥ 12,000: High
- points < 12,000: Medium

## Persistence

All settings are automatically persisted to UserDefaults:

```swift
// UserDefaults keys
@AppStorage("registration_modelPointsSampleCount") var modelPointsSampleCount: Int = 5000
@AppStorage("registration_scanPointsSampleCount") var scanPointsSampleCount: Int = 10000
@AppStorage("registration_maxICPIterations") var maxICPIterations: Int = 30
@AppStorage("registration_icpConvergenceThreshold") var icpConvergenceThreshold: Double = 0.001
@AppStorage("registration_pauseARDuringRegistration") var pauseARDuringRegistration: Bool = true
@AppStorage("registration_useBackgroundLoading") var useBackgroundLoading: Bool = true
@AppStorage("registration_skipModelConsistencyChecks") var skipModelConsistencyChecks: Bool = true
@AppStorage("registration_showPerformanceLogs") var showPerformanceLogs: Bool = false
```

Settings persist across app launches and are shared across all registration operations.

## Recommendations

### For Quick Testing
- Use **Fast** preset
- Good enough for rough alignment checks
- Fastest iteration during development

### For Production Use
- Use **Balanced** preset (default)
- Best trade-off between speed and accuracy
- Suitable for most marker placement scenarios

### For Critical Applications
- Use **Accurate** preset
- When precision is paramount
- Worth the extra time for important measurements

### Custom Tuning
- Start with Balanced preset
- Adjust individual parameters as needed
- Monitor performance logs to optimize
- Experiment with point counts vs iterations

## Benefits

1. **Centralized Configuration**: All registration parameters in one place
2. **User Control**: Users can optimize for their specific use case
3. **Consistency**: Same settings apply to Session and Space registration
4. **Transparency**: Real-time estimates help users make informed choices
5. **Flexibility**: Presets for common cases, custom for advanced users
6. **Persistence**: Settings survive app restarts
7. **Debuggability**: Optional performance logging for optimization

## Future Enhancements

Potential improvements:

- Per-space settings override
- Automatic preset selection based on space size
- Performance profiling and recommendations
- Settings export/import
- Advanced users: custom ICP termination criteria
- A/B testing of parameter combinations
- Machine learning to suggest optimal settings

## Testing

To verify settings are working:

1. **Change Preset**: Switch between presets, verify parameters update
2. **Custom Values**: Modify individual settings, verify preset changes to "Custom"
3. **Performance Impact**: Enable logs, compare timings with different presets
4. **Persistence**: Change settings, close app, reopen, verify settings persisted
5. **Integration**: Perform registration in Session and Space, verify both use settings
6. **Estimates**: Check if UI estimates match actual performance

## Related Documentation

- [Session Scan & Registration](./SESSION_SCAN_REGISTRATION.md)
- [Model Registration](./MODEL_REGISTRATION.md)
- [Performance Optimization](./SESSION_SCAN_REGISTRATION.md#performance-optimization)
