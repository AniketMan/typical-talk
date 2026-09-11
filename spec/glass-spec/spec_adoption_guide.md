# Adopting Liquid Glass in Your Apps: A Complete Guide

Liquid Glass is a new dynamic material introduced across Apple platforms (iOS 26+, iPadOS 26+, macOS 26+, tvOS 26+, watchOS 26+) that combines the optical properties of glass with a sense of fluidity. It blurs content behind it, reflects color and light of surrounding content, and reacts to touch and pointer interactions in real time.

Whether you are upgrading an existing app or building a new one from scratch, this guide provides a step-by-step breakdown of how to adopt Liquid Glass.

## 1. Upgrading an Existing App

Adopting Liquid Glass in an existing app often requires minimal code changes if you are already using standard system components.

### Leverage System Frameworks
If your app uses standard components from SwiftUI, UIKit, or AppKit, your interface will pick up the Liquid Glass look automatically when built with the latest SDKs.

*   **SwiftUI:** `NavigationStack`, `NavigationSplitView`, `toolbar`, etc.
*   **UIKit:** `UINavigationBar`, `UITabBar`, `UIToolbar`, `UISplitViewController`.
*   **AppKit:** `NSToolbar`, `NSSplitView`.

**Actionable Step:** Remove custom backgrounds or hard-coded visual effect views from your navigation bars, tab bars, and toolbars. Let the system determine the background appearance so Liquid Glass can shine through.

### Update Controls and Navigation
Controls have rounder forms to elegantly nestle into corners.

*   **Scroll Edge Effect:** Ensure content scrolls cleanly beneath toolbars and custom bars using `.safeAreaBar(edge:alignment:spacing:content:)` in SwiftUI or `UIScrollEdgeElementContainerInteraction` in UIKit.
*   **Button Styles:** Adopt standard glass button styles instead of building custom ones:
    *   SwiftUI: `.buttonStyle(.glass)` or `.buttonStyle(.glassProminent)`
    *   UIKit: `UIButton.Configuration.glass()` or `UIButton.Configuration.prominentGlass()`

### App Icons
App icons now contain layers that dynamically respond to lighting and system effects (default, dark, clear, tinted).
*   **Actionable Step:** Redesign your app icon using solid, filled, overlapping semi-transparent shapes in layers. Use the **Icon Composer** app (available in Xcode) to preview and export your layered icon.

## 2. Building a New App with Liquid Glass Custom Views

When building a new app, or when you need highly custom interactive UI elements, you can explicitly apply Liquid Glass compositing to your custom views.

### The `glassEffect` Modifier
The core API for applying Liquid Glass in SwiftUI is the `.glassEffect(_:in:)` modifier. By default, it applies a regular glass effect within a `Capsule` shape.

```swift
// Basic Glass Effect
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect()

// Custom Shape (e.g., Rounded Rectangle)
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect(in: .rect(cornerRadius: 16.0))
```

### Making Elements Interactive
You can make custom components react to touch and pointer interactions (scaling, shimmer effects) using the `.interactive()` modifier. This is crucial for maintaining the fluid feel of Liquid Glass.

```swift
Text("Interactive Button")
    .font(.title)
    .padding()
    .glassEffect(.regular.tint(.blue).interactive())
```

### Compositing Multiple Views: `GlassEffectContainer`
When you have multiple glass elements that should blend and animate together, you must use a `GlassEffectContainer`. This is critical for performance and enables fluid morphing between shapes.

The `spacing` parameter determines how close elements need to be before their glass effects merge.

```swift
GlassEffectContainer(spacing: 40.0) {
    HStack(spacing: 40.0) {
        Image(systemName: "scribble.variable")
            .frame(width: 80.0, height: 80.0)
            .font(.system(size: 36))
            .glassEffect()

        Image(systemName: "eraser.fill")
            .frame(width: 80.0, height: 80.0)
            .font(.system(size: 36))
            .glassEffect()
            // Animating this offset will cause the two glass shapes to morph together
            .offset(x: -40.0, y: 0.0)
    }
}
```

### Unifying Geometries: `glassEffectUnion`
If you want multiple views to contribute to a single, unified Liquid Glass capsule even when at rest, use `.glassEffectUnion(id:namespace:)`.

```swift
let symbolSet: [String] = ["cloud.bolt.rain.fill", "sun.rain.fill"]
@Namespace private var namespace

GlassEffectContainer(spacing: 20.0) {
    HStack(spacing: 20.0) {
        ForEach(symbolSet.indices, id: \.self) { item in
            Image(systemName: symbolSet[item])
                .frame(width: 80.0, height: 80.0)
                .font(.system(size: 36))
                .glassEffect()
                // Combines both icons into one shared glass pill
                .glassEffectUnion(id: "weather_group", namespace: namespace)
        }
    }
}
```

### Morphing Transitions
To animate views smoothly transitioning into one another (e.g., an icon changing state), use `.glassEffectID(_:in:)`. The container handles the fluid morphing geometry automatically.

```swift
@State private var isExpanded: Bool = false
@Namespace private var namespace

var body: some View {
    GlassEffectContainer(spacing: 40.0) {
        HStack(spacing: 40.0) {
            Image(systemName: "scribble.variable")
                .frame(width: 80.0, height: 80.0)
                .font(.system(size: 36))
                .glassEffect()
                .glassEffectID("pencil", in: namespace)

            if isExpanded {
                Image(systemName: "eraser.fill")
                    .frame(width: 80.0, height: 80.0)
                    .font(.system(size: 36))
                    .glassEffect()
                    .glassEffectID("eraser", in: namespace)
            }
        }
    }

    Button("Toggle") {
        withAnimation {
            isExpanded.toggle()
        }
    }
    .buttonStyle(.glass)
}
```

## 3. Best Practices & Performance
*   **Modifier Order:** Always apply `.glassEffect()` *after* other appearance modifiers (like `.padding()`, `.font()`, `.frame()`).
*   **Limit Usage:** Liquid Glass is computationally expensive. Avoid overusing it on every single element. Use it sparingly to bring focus to key interactive elements or underlying content.
*   **Always Use Containers for Multiples:** If you have more than one custom glass view near each other, wrap them in a `GlassEffectContainer` to optimize rendering performance.
*   **Accessibility:** Test your app with "Reduce Transparency" and "Reduce Motion" enabled. The system handles standard components automatically, but you should verify your custom `.glassEffect()` views degrade gracefully.
