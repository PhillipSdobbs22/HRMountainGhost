# HRMountainGhost

A native iPhone + Apple Watch app that turns a sensorless indoor exercise bike into a mountain climb. The Watch supplies live heart rate and active calories, the app estimates vertical gain, and you race "ghosts" built from your own past rides up a virtual mountain.

**Status:** project setup (Stage 0). No app code yet.

## What it does (planned)
- Live Watch-to-iPhone link during an indoor cycling workout
- Climb estimate from active calories (no bike sensors needed)
- Ghosts: 42-day average, best rides, slowest ride ("lanterne rouge"), and chase ghosts
- Ride rankings: calories, time, average heart rate, efficiency
- Optional aid station stops and sprint intervals
- Radar + mountain profile screen and a first-person switchback view

See [docs/DESIGN.md](docs/DESIGN.md) for the full spec.

## Requirements
- Mac with Xcode 26.6 or later
- iPhone running iOS 17 or later (developed on iPhone 13 Pro, iOS 26.6.2)
- Apple Watch running watchOS 10 or later (developed on watchOS 10.6.2)
- Apple ID (free works; a free account's installs expire after about 7 days)
- Live heart rate only works on a real Watch, not the simulator

## Build and run
1. Clone the repo and open `HRMountainGhost.xcodeproj` in Xcode.
2. For both targets, set Signing & Capabilities > Team to your own team and change the bundle ID prefix to yours.
3. Confirm the HealthKit capability is on for both targets, and Workout Processing is on for the Watch target.
4. Turn on Developer Mode on the iPhone and the Watch.
5. Run the iPhone scheme on your iPhone, then the Watch scheme on your Watch.
6. Allow Health access when prompted.

## Privacy
Health data (heart rate, calories, workouts) stays on your devices. The app has no server and sends nothing off-device.

## Project layout (planned)
- `HRMountainGhost/` iPhone app (SwiftUI)
- `HRMountainGhost Watch App/` Watch app (SwiftUI, HealthKit workout session)
- `docs/` design notes and mockups

## License
Not yet chosen.
