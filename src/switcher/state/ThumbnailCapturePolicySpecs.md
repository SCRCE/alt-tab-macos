# Partial thumbnail captures

The ScreenCaptureKit path compares a capture's content dimensions with the output expected for the
window's current size and display scale. Content less than 90% of the expected width or height is
partial. Pixel rounding within that tolerance is accepted.

The configured capture area includes any child windows, so its expected output size takes precedence
over the bare window size. Capturing a sheet must not look like a partial frame merely because the
combined area has a different aspect ratio.

- Sample-buffer captures use the metadata content rectangle converted to pixels with its display
  scale factor and clipped to the actual buffer. Missing or invalid metadata falls back to image size.
- Screenshot captures with alpha are sampled off-main at 64 × 64. The bounding box of pixels with alpha
  at least 32/255 estimates the content dimensions while excluding faint shadows. Images without alpha
  or an unavailable sampling context fall back to image dimensions. Transparent images are partial.
- Discard an in-flight frame if window size, display scale, or fullscreen state changed since its request.

- Refuse partial captures even when no previous thumbnail exists; the app icon remains the placeholder.
- Keep an existing thumbnail after retry exhaustion. Exhaustion never makes a partial frame acceptable.
- Allow at most three delayed retries per run of partial frames at the same expected output size.
- Only one retry may be pending per window. Ordinary capture events cannot multiply pending retries.
- A valid frame cancels an outstanding retry and resets the budget.
- A changed expected output size starts a new budget and invalidates the old pending retry. Legitimate
  resizing and display-scale changes are judged against that new size, not an older accepted image.
- A fresh window owns a fresh policy, so a recycled WindowServer ID inherits no exhausted budget.
- Retry callbacks may run only once and only while their token is current. The caller applies the
  normal capture permission, visibility, and screen-lock guards when executing them.

Opaque padding cannot be distinguished from real window content by the alpha check. Intentionally
mostly transparent windows can be rejected by this heuristic. The policy does not change the capture
backend or prevent macOS from treating a capture as screen recording.
