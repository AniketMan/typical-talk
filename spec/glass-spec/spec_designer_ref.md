# SwiftUI 26 Liquid Glass API Reference

This document provides a comprehensive reference for all Liquid Glass properties, modifiers, and behaviors introduced in SwiftUI 26. It covers core materials, interactive states, optical properties, morphing transitions, and platform-specific background effects.

## 1. Core Glass Material

The foundation of the Liquid Glass system is the `Glass` struct, which defines the visual appearance and interactivity of the material.

### Variants
The base appearance of the glass is determined by its variant.

*   `.regular`: The standard frosted glass appearance with default refraction, blur, and specularity.
*   `.clear`: A highly transparent variant with minimal base opacity, relying primarily on refraction and edge lighting to define its volume.
*   `.identity`: A fully transparent, non-rendering variant. It preserves layout space and can participate in morphing transitions without drawing pixels itself.

### Tinting
Glass materials can be tinted while preserving their optical properties.

*   `.tint(Color?)`: Applies a color tint to the glass volume. Passing `nil` removes any existing tint, reverting the glass to its base variant color. The system automatically handles color blending to ensure the tint interacts realistically with the background.

### Interactivity
The material can respond to user input automatically.

*   `.interactive(Bool)`: When enabled (default is `true`), the glass automatically applies physics-based scale and lighting changes during touch or pointer interactions (e.g., pressing down). This applies the same responsive and fluid reactions that `.glass` provides to standard buttons.

## 2. Applying Glass to Views

The primary method for applying a glass material to a view is the `glassEffect` modifier.

### Base Modifier
*   `.glassEffect()`: Applies a default `.regular` glass effect using a `.capsule` shape behind the view's content. Apply the `glassEffect(_:in:)` modifier *after* other modifiers that affect the appearance of the view.

### Custom Configuration
You can pass a specific `Glass` configuration to customize the appearance.

*   `.glassEffect(Glass)`: Applies the specified glass configuration. For example, `.glassEffect(.clear.tint(.blue))`.

### Shape Definition
The shape of the glass volume can be explicitly defined. If not provided, it defaults to `.capsule`.

*   `.glassEffect(_:in:)`: Applies the glass effect constrained to a specific `Shape`. Supported shapes include `.capsule`, `.circle`, `.rect`, and `.rect(cornerRadius:)`. Use different shapes to have a consistent look and feel across custom components in your app (e.g., use a rounded rectangle if you're applying the effect to larger components that would look odd as a `Capsule` or `Circle`).

## 3. Advanced Layout and Morphing

SwiftUI 26 introduces powerful capabilities for grouping and morphing multiple glass elements.

### GlassEffectContainer
Use `GlassEffectContainer` when applying Liquid Glass effects on multiple views to achieve the best rendering performance. A container also allows views with Liquid Glass effects to blend their shapes together and to morph in and out of each other during transitions. Inside a container, each view with the `glassEffect(_:in:)` modifier renders with the effects behind it.

*   `GlassEffectContainer(spacing: CGFloat) { ... }`: Defines a spatial boundary where child glass elements can interact. Customize the `spacing` parameter to control how the Liquid Glass effects behind views interact with one another. The larger the spacing value on the container, the sooner the Liquid Glass effects behind views blend together and merge the shapes during a transition.
    *   *Note*: A spacing value on the container that's larger than the spacing of an interior `HStack`, `VStack`, or other layout container causes Liquid Glass effects to blend together at rest because the views are too close to each other. Animating views in or out causes the shapes to morph apart or together as the space in the container changes.

### Morphing Identifiers
Morphing effects occur during transitions or animations between views with Liquid Glass effects. Coordinate transitions between views with effects in a container by using the `glassEffectID(_:in:)` modifier.

*   `.glassEffectID(_:in:)`: Tags a view with a unique `Hashable` identifier within a specific `@Namespace`. These IDs ensure SwiftUI animates the same shapes correctly when a shape appears or disappears due to view hierarchy changes. SwiftUI uses the spacing provided to the effect container along with the geometry of the shapes themselves to determine when and which appropriate shapes to morph into and out of.

### Transitions
`GlassEffectTransition` allows you to specify the type of transition to use when you want to add or remove effects within a container.

*   `.glassEffectTransition(_:)`: Specifies the animation style. Options include:
    *   `.matchedGeometry`: The default transition type for effects you want to add or remove that are positioned *within* the container's assigned spacing. The element morphs smoothly from or to another element with the same ID.
    *   `.materialize`: Use this transition for effects you want to add or remove that are *farther* from each other than the container's assigned spacing. If you prefer to have a simpler transition or to create a custom transition, use the `materialize` transition and `withAnimation(_:_:)`.
    *   `.identity`: The element appears or disappears instantly without a morphing animation.

To provide people with a consistent experience, use `matchedGeometry` and `materialize` transitions across your apps. The system applies more than opacity changes with the available transition types.

### Unification
In some cases, you want the geometries of multiple views to contribute to a single Liquid Glass effect capsule, even when your content is at rest.

*   `.glassEffectUnion(id:namespace:)`: Specify that a view contributes to a unified effect with a particular ID. This combines all effects with a similar shape, Liquid Glass effect, and ID into a single shape with the applied Liquid Glass material. This is especially useful when creating views dynamically, or with views that live outside of a layout container, like an `HStack` or `VStack`.

## 4. Controls and Buttons

The Liquid Glass system integrates directly with SwiftUI controls.

### Button Styles
You can apply glass styling directly to buttons using dedicated styles.

*   `.buttonStyle(.glass)`: Applies the standard interactive glass appearance to the button.
*   `.buttonStyle(.glassProminent)`: Applies a visually heavier, more pronounced glass style, typically used for primary actions.
*   `.buttonStyle(GlassButtonStyle(Glass))`: Allows you to pass a fully custom `Glass` configuration to be used as the button's background material.

## 5. Platform-Specific Effects (visionOS)

On visionOS (1.0+), the `glassBackgroundEffect` modifier provides a true 3D glass volume that influences z-axis layout and casts physical shadows.

### Base Effect
*   `.glassBackgroundEffect(displayMode:)`: Applies the system standard 3D glass background. The `displayMode` (`GlassBackgroundDisplayMode`) controls its visibility:
    *   `.always`: The background is always visible.
    *   `.implicit`: The background visibility is determined by the system context (e.g., whether the window is focused).
    *   `.never`: The background is hidden.

### Shape Override
*   `.glassBackgroundEffect(in:displayMode:)`: Overrides the default window shape with a specific `InsettableShape` (e.g., `.circle` or `.rect(cornerRadius:)`).

### Feathered Edges (visionOS 2.4+)
For a softer integration with the environment, the glass edges can be feathered.

*   `.glassBackgroundEffect(.feathered(padding:softEdgeRadius:), displayMode:)`: Applies a feathered edge to the glass volume.
    *   `padding`: Defines the distance from the view's bounds where the feathering begins.
    *   `softEdgeRadius`: Controls the gradient curve of the feathering effect.

## 6. Optical Properties (System Rendered)

While not directly controllable via simple modifiers, the Liquid Glass system automatically calculates several optical properties based on the environment and the glass configuration. These are simulated in the Designer tool but are handled by the OS renderer in production.

*   **Refraction Blur**: The degree to which background content is blurred.
*   **Saturation**: The enhancement of colors behind the glass volume.
*   **Specular Highlight**: The physical reflection of environmental light sources on the top surface of the glass.
*   **Edge Light**: The internal reflection and brightening at the physical boundaries of the shape.
*   **Chromatic Aberration**: The splitting of RGB channels at the edges of the glass, simulating real-world lens distortion.

## 7. Performance Considerations

Creating too many Liquid Glass effect containers and applying too many effects to views outside of containers can degrade performance. Limit the use of Liquid Glass effects onscreen at the same time. Additionally, optimize how your app spends rendering time as people use it.
