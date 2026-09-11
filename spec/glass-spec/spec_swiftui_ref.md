# iOS 26 Liquid Glass: The Complete SwiftUI Reference

Liquid Glass is the translucent, dynamic material introduced in iOS 26 that bends light (lensing), responds to device motion with specular highlights, and reacts fluidly to touch. It creates depth by continuously adapting to background content and lighting conditions.

This reference breaks down the exact SwiftUI APIs, their parameters, and practical implementations so you can build morphing, chromatic, and interactive elements. **This document is 100% SwiftUI-native.**

## Core API: The `glassEffect` Modifier

The foundation of all custom Liquid Glass in SwiftUI is the `glassEffect` modifier.

```swift
func glassEffect(
    _ glass: Glass = .regular,
    in shape: some Shape = DefaultGlassEffectShape()
) -> some View
```

### Parameters

*   **`glass`**: The configuration of the material (using the `Glass` struct).
*   **`shape`**: The bounding geometry of the glass. Defaults to `Capsule()` via `DefaultGlassEffectShape()`.

### The `Glass` Struct (Variants & Behaviors)

The `Glass` struct defines the visual properties and interactive behaviors of the material.

| Variant / Modifier | Code Name | Description |
| :--- | :--- | :--- |
| **Regular** | `Glass.regular` | The standard, adaptive material. Provides medium transparency and full adaptivity to background content. Use for toolbars, standard buttons, and most UI elements. |
| **Clear** | `Glass.clear` | A high-transparency variant. Best used for small floating controls over media-rich backgrounds (like maps or photos) where the foreground content is bold. |
| **Identity** | `Glass.identity` | A passthrough state where no glass effect is applied. Useful for conditional toggling without changing view hierarchy. |
| **Tint** | `.tint(_ color: Color)` | Applies a color tint to the glass. This is used to convey semantic meaning (like a primary action state). It dynamically adjusts hue and brightness for legibility. |
| **Interactive** | `.interactive()` | **(Crucial for touch response)** Enables the fluid, gel-like reactions. This activates scaling on press, bouncing animations, shimmering, touch-point illumination (chromatic aberration that radiates to nearby glass), and response to drag gestures. |

**Implementation Example:**
```swift
// A fully interactive, tinted glass button
Button("Morph Me") {
    // Action
}
.padding()
.glassEffect(.regular.tint(.blue).interactive(), in: RoundedRectangle(cornerRadius: 16))
```

## Morphing & Blending: The Container System

To achieve the "cool stuff" where elements morph, blend, and stretch into one another, you must use the container system. Glass cannot sample other glass; it needs a shared sampling region.

### `GlassEffectContainer`

This view wraps multiple glass elements, allowing them to share rendering performance and interact.

```swift
GlassEffectContainer(spacing: 40.0) {
    // Glass elements go here
}
```

*   **`spacing` parameter**: This is the morphing threshold. If two glass elements within the container move closer than this `CGFloat` value, their paths will automatically blend and merge together.

### Morphing Transitions

To make elements seamlessly morph into one another when views appear or disappear (like an expanding menu), you use `glassEffectID` and `glassEffectTransition`.

1.  **`glassEffectID(_:in:)`**: Associates a specific glass element with a unique identifier within a `@Namespace`. SwiftUI uses this to track the geometry for morphing.
2.  **`glassEffectTransition(_:)`**: Defines how the element enters or exits.

**Transition Types (`GlassEffectTransition`):**
*   `.matchedGeometry`: (Default) Morphs the shape of the appearing/disappearing element to match nearby elements.
*   `.materialize`: Fades in the content and animates the glass material in/out, but does *not* attempt to match geometry.
*   `.identity`: No transition changes.

**Implementation Example (Expandable Action Menu):**
```swift
struct MorphingMenu: View {
    @State private var isExpanded = false
    @Namespace private var glassSpace

    var body: some View {
        GlassEffectContainer(spacing: 30.0) {
            HStack(spacing: 20) {
                // The main toggle button
                Button(action: {
                    withAnimation(.bouncy) { isExpanded.toggle() }
                }) {
                    Image(systemName: isExpanded ? "xmark" : "plus")
                        .frame(width: 50, height: 50)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("toggleButton", in: glassSpace)

                // The expanding action
                if isExpanded {
                    Button(action: { /* Do something */ }) {
                        Image(systemName: "pencil")
                            .frame(width: 50, height: 50)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("editButton", in: glassSpace)
                }
            }
        }
    }
}
```

### `glassEffectUnion`

If you need multiple views to act as a single, unified piece of glass *even when they are far apart* (outside the container's `spacing` threshold), use `.glassEffectUnion(id:namespace:)`. All elements sharing the same union ID will render as one continuous, complex glass shape.

## iOS 26 Exclusive Capabilities & Modifiers

iOS 26 introduces several SwiftUI-exclusive modifiers designed specifically to complement the Liquid Glass design system.

### 1. Progressive Blur & Scroll Edge Effects
Instead of a hard cutoff when content scrolls under a navigation bar, iOS 26 introduces a progressive blur "pocket".
*   **`.scrollEdgeEffectStyle(_:for:)`**: Configures the blur transition. Use `.soft` for the new progressive blur, or `.hard` for a sharp cutoff.
*   **`.scrollEdgeEffectHidden(_:for:)`**: Hides the edge effect entirely.

### 2. The `safeAreaBar` Modifier
A massive upgrade over `safeAreaInset`. When you want to build a custom floating glass bar at the bottom of the screen, use `safeAreaBar`.
*   **`safeAreaBar(edge:alignment:spacing:content:)`**: Places a view anchored to an edge. **Crucially, it automatically extends the scroll edge effect (progressive blur) under your custom bar.**

### 3. Background Extension Effect
*   **`.backgroundExtensionEffect()`**: Use this modifier to extend and blur visual content beyond a view's bounds. This is heavily used to create continuous glass backgrounds under sidebars or inspectors (`NavigationSplitView`).

### 4. TabView & Search Floating Pills
In iOS 26, `TabView` automatically becomes a floating Liquid Glass pill.
*   **`.tabBarMinimizeBehavior(.onScrollDown)`**: Automatically collapses the tab bar into a smaller pill when the user scrolls.
*   **`Tab(role: .search)`**: Automatically creates a detached, floating search button at the bottom right for reachability.
*   **`.tabViewBottomAccessory { ... }`**: Adds a persistent glass view (like a "Now Playing" bar) directly above the tab bar, seamlessly blending with it.

### 5. Toolbar & Navigation Upgrades
*   **`ToolbarSpacer(.fixed, spacing: 20)`**: Use this new API to explicitly push toolbar items apart into separate glass pills.
*   **`.sharedBackgroundVisibility(.hidden)`**: Apply this to a `ToolbarItem` if you want it to float naked without the shared glass background.
*   **`.navigationSubtitle(_:)`**: A highly requested iOS 26 feature to add contextual text under the `.navigationTitle`.
*   **`.searchToolbarBehavior(.minimized)`**: Keeps the search bar collapsed as an icon until tapped.

### 6. Concentric Shapes
*   **`ConcentricRectangle`**: A new shape in iOS 26 that automatically calculates its corner radius to follow the curvature of its parent container, ensuring perfect nesting inside glass sheets and popovers.

### 7. Sheet Morphing
When presenting a sheet from a toolbar button, iOS 26 allows the button to physically morph into the sheet.
*   Use **`.matchedTransitionSource(id:in:)`** on the button.
*   Use **`.navigationTransition(.zoom(sourceID:in:))`** on the sheet content.

### 8. Button Styles & Control Sizes
*   **`.buttonStyle(.glass)`**: Translucent, see-through secondary action.
*   **`.buttonStyle(.glassProminent)`**: Opaque, no background show-through for primary actions.
*   **`.controlSize(.extraLarge)`**: A brand new size class in iOS 26 specifically designed to give glass controls more breathing room for labels and accents.

## Performance & Best Practices

1.  **Never Stack Glass:** Do not put glass on top of glass. It breaks the visual hierarchy and ruins performance. Glass goes in the navigation layer (middle), above content, below text/icons.
2.  **Always Use Containers:** If you have more than one glass element on screen, put them in a `GlassEffectContainer`. It shares the background sampling region, drastically reducing GPU memory usage.
3.  **Accessibility is Automatic:** Do not try to build custom opacity sliders. The system automatically handles Reduced Transparency, Increased Contrast, and the user-controlled Tinted Mode.
4.  **Avoid Continuous Animation:** Liquid Glass calculates real-time lensing. Do not apply `.repeatForever()` rotation animations to glass elements, as it will drain the battery rapidly. Let the glass rest in steady states.
