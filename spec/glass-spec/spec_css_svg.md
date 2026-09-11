# Technical Breakdown: Liquid Glass Effect with CSS and SVG

This document provides a detailed technical analysis of the "Liquid Glass" effect as described in the [kube.io blog post](https://kube.io/blog/liquid-glass-css-svg/). The technique approximates the visual effect of light refracting through a curved glass surface, primarily using SVG filters and CSS.

## Core Concepts

The effect is achieved by programmatically generating an SVG displacement map based on the physics of light refraction and applying it to an HTML element using the CSS `backdrop-filter` property. A specular highlight is then added to enhance the realism.

## 1. The Physics of Refraction

The foundation of the effect is Snell's Law, which describes how light bends when it passes from one medium to another (e.g., from air to glass). The amount of bending depends on the angle at which the light hits the surface (angle of incidence) and the refractive indices of the two materials.

> *Snell's Law:* `n1 * sin(θ1) = n2 * sin(θ2)`

For this effect, the implementation is simplified by making several assumptions:
- The surrounding medium is air (refractive index `n1 = 1`).
- The glass has a refractive index `n2 > 1` (typically ~1.5).
- Only a single refraction event is calculated (light entering the glass, but not exiting).
- The object is a 2D shape parallel to the background.

## 2. Defining the Glass Surface Geometry

The shape of the virtual glass is defined by a mathematical height function, `f(d)`, which determines the thickness of the glass at a given distance `d` from its edge. The article explores four different surface profiles, each producing a distinct refractive pattern.

| Surface Profile | Equation | Description |
|---|---|---|
| **Convex Circle** | `y = sqrt(1 - (1-x)^2)` | A simple spherical dome shape. It produces a sharp transition at the edge of the bezel. |
| **Convex Squircle** | `y = (1 - (1-x)^4)^(1/4)` | A shape with a softer, flatter curve at the edges. This is noted as being favored by Apple for its smooth refraction gradients, even on non-circular shapes. |
| **Concave** | `y = 1 - Convex(x)` | An inverted, bowl-like shape that causes light rays to diverge outwards. |
| **Lip** | `mix(Convex, Concave, Smootherstep)` | A combination of convex and concave shapes, creating a raised rim with a dipped center. |

The choice of a **convex** profile is critical, as it bends light inwards, keeping the displaced pixels within the object's boundaries. Concave profiles push pixels outwards, which would require sampling the background from outside the element.

## 3. Calculating the Displacement Vector Field

For every point on the glass surface, a displacement vector is calculated. This vector determines how far and in what direction a pixel from the background should be moved to simulate refraction.

1.  **Calculate the Surface Normal:** The derivative of the height function at a given point gives the slope of the surface. The normal vector is perpendicular to this slope.
2.  **Apply Snell's Law:** Using the surface normal and the refractive indices, the angle of the refracted light ray is calculated.
3.  **Determine Displacement:** The difference between the original path of the light ray and the new refracted path gives the displacement vector.

For efficiency, these calculations are performed only along a single radius of the object (e.g., for 127 sample points). The results are then rotated to generate the full displacement map for a circular or rounded shape, leveraging the object's symmetry.

## 4. Implementation with SVG `feDisplacementMap`

The calculated displacement field is translated into a visual format that the browser can use: an SVG displacement map. This is the core of the implementation.

The `<feDisplacementMap>` SVG filter takes an input image (`in2`) and uses its color channels to shift the pixels of another input (`in`).

-   **Encoding:** The 2D displacement vectors (X, Y) are encoded into the Red and Green channels of an image.
    -   The vector components, originally in a normalized `[-1, 1]` range, are remapped to the `[0, 255]` range of an 8-bit color channel. A value of 128 represents zero displacement.
    -   `Red = 128 + (X * 127)`
    -   `Green = 128 + (Y * 127)`
-   **Applying the Filter:** The generated displacement map image is used within an SVG filter.

```xml
<svg>
  <filter id="liquidGlassFilter">
    <feImage href="{displacementMapDataUrl}" result="displacementMap" />
    <feDisplacementMap
      in="SourceGraphic"
      in2="displacementMap"
      scale="{maxDisplacementValue}"
      xChannelSelector="R"
      yChannelSelector="G"
    />
  </filter>
</svg>
```

The `scale` attribute is a multiplier for the displacement values. It is set to the maximum displacement magnitude calculated in the previous step to ensure the visual effect matches the physical simulation.

## 5. Adding the Specular Highlight

To complete the illusion of glass, a specular highlight is added. This is not a physically accurate reflection but a stylized rim light effect.

-   An image is generated where the brightness corresponds to the angle of the surface normal relative to a fixed light source.
-   This highlight image is blended on top of the refracted background using another SVG filter primitive, such as `<feBlend>` or `<feComposite>`.

## 6. Application and Limitations

The final SVG filter is applied to an HTML element using the CSS `backdrop-filter` property.

```css
.glass-element {
  backdrop-filter: url(#liquidGlassFilter);
}
```

### Critical Limitations:

-   **Browser Compatibility:** This technique is **Chrome-only**. As of the article's writing, only Chromium-based browsers support using an SVG filter as a `backdrop-filter`. Other browsers will not render the effect.
-   **Performance:** The generation of the displacement map is computationally intensive. The map must be rebuilt whenever the element's size or the surface parameters change, which can be slow and is not suitable for dynamically resizing elements.

This technique offers a powerful way to create a sophisticated, physically-based visual effect on the web, but its practical use is currently limited by browser support and performance considerations.
