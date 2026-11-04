# Understanding the code

A guided tour of Notch Island for developers coming from Java, C#, TypeScript or React. Swift will feel like a mix of all of them.

## 1. The big picture

```
 Services/            ViewModel/                 Views/
 (data sources)       (decides what to show)     (draws it)
 ─────────────        ──────────────────         ──────────
 BatteryService ─┐
 NowPlaying      ├──▶  IslandViewModel  ──────▶  IslandView
 Clipboard       │     • mode, tab, peek          ├ CompactView   (collapsed)
 Timer, Calendar │     • sizes & animations       └ ExpandedView  (open)
 Downloads …    ─┘
                            ▲
 Window/NotchWindowController: watches the mouse → tells the view model "expand" / "collapse"
 App/NotchIslandApp: starts everything, menu bar icon, Settings window
```

It's the same idea as a React app with a store: **services** fetch data, the **view model** is the store, and **views** render the store's state.

## 2. Swift ↔ what you know

| Swift | Java / C# | TypeScript / React |
|---|---|---|
| `let x = 5` / `var x = 5` | `final int x` / `int x` | `const` / `let` |
| `String?` (optional) | `@Nullable String` / `string?` | `string \| undefined` |
| `struct` (copied when passed) | C# `struct` | plain object |
| `class` (shared reference) | `class` | `class` |
| `protocol` | `interface` | `interface` |
| `extension Foo { … }` | C# extension methods | adding to a prototype |
| `{ x in x * 2 }` (closure) | lambda `x -> x * 2` | `x => x * 2` |
| `enum` with `switch` | `enum` + `switch` | union type + `switch` |

### Optionals

The biggest new idea. Swift makes you handle "might be empty" explicitly:

```swift
if let track = nowPlaying.track {        // only runs if track isn't nil
    Text(track.title)
}
guard let url = URL(string: s) else { return }   // early exit if nil
let name = user.name ?? "Guest"          // default value, like C#'s ??
```

### Property observers

`didSet` runs after every change to a property. Many services use it to start and stop:

```swift
var isEnabled = false {
    didSet { if isEnabled { start() } else { stop() } }
}
```

## 3. SwiftUI ≈ React

A SwiftUI view is a **struct with a `body`**, much like a function component returning JSX:

```swift
struct BatteryBadge: View {                     // ≈ function BatteryBadge(props)
    @ObservedObject var battery: BatteryService //  ≈ useStore(battery): redraws when it changes

    var body: some View {                       //  ≈ return ( <HStack>… )
        HStack(spacing: 6) {
            Text("\(battery.level)%")           //  "\( )" is interpolation, like `${}`
            BatteryGlyph(level: battery.level, …)
        }
    }
}
```

- **Modifiers** chain like CSS: `.font(...)`, `.padding(...)`, `.background(...)`. Order matters, because each one wraps the view before it.
- **`if` / `switch` inside `body`** works like conditional rendering in JSX.
- **`withAnimation { … }`:** any state change inside it animates. That's how the island's spring works.

## 4. How state flows (Combine ≈ RxJS)

- **`@Published var level = 100`** inside an `ObservableObject` class works like an observable field. When it changes, every view watching it redraws.
- **`.sink { }`** is `.subscribe()`.
- **`.store(in: &cancellables)`** keeps the subscription alive, a bit like holding onto an RxJS `Subscription`.

## 5. One feature, end to end: plugging in the charger

1. **macOS → `BatteryService.update()`:** IOKit calls this when the power source changes, and it sets `@Published isPluggedIn = true`.
2. **The view model listens** (`ViewModel/IslandViewModel.swift`):
   ```swift
   battery.$isPluggedIn                 // "$" gives you the stream of changes
       .removeDuplicates()
       .dropFirst()                     // ignore the value at launch
       .filter { plugged in plugged }   // only when it becomes true
       .sink { [weak self] _ in self?.showPeek(.charging) }
   ```
   `[weak self]` avoids memory leaks, like making sure a callback doesn't keep a component alive forever.
3. **`showPeek(.charging)`** sets `peek` inside `withAnimation`. `currentSize` now returns a wider size.
4. **`Views/Compact/CompactView.swift`** `switch`es on `peek` and draws the battery glyph and "56%".
5. **`Views/IslandView.swift`** sees the new size and springs the black shape wider.

Every feature follows this pattern: **a service publishes → the view model decides → a view draws.**

## 6. Where AppKit comes in

SwiftUI draws the content, while **AppKit** (Apple's older Mac UI framework) provides the special window:

- `Window/NotchPanel.swift`: an `NSPanel` with no border that floats above the menu bar.
- `NSHostingView` puts SwiftUI content inside that AppKit window, a bridge between the two frameworks.

## 7. How to start exploring

1. **Open it in Xcode:** run `open Package.swift`. You get autocomplete, and ⌥-clicking any symbol shows its docs.
2. **Make a small, safe change first:** in `Views/Theme.swift`, change `.pink` to `.mint` for Music, then rebuild. The colour flows through the tabs, the welcome and the buttons.
3. **Then read in this order:**
   1. `Services/BatteryService.swift` (small and self-contained)
   2. `ViewModel/IslandViewModel.swift` (the brain)
   3. `Views/Compact/CompactView.swift` (the collapsed island)
   4. `Window/NotchWindowController.swift` (the mouse logic)
