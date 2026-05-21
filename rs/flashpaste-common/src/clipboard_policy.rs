//! Pure clipboard decision helpers for paste dispatch.
//!
//! The shell dispatcher still owns the full hot path, but these small pure
//! functions keep the hard-won Wayland/X11 policy regression-testable without
//! needing a live compositor in CI.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HasImagePolicy {
    WaylandAuthoritative,
    WaylandAuthoritativeStaleX11Ignored,
    X11FallbackWaylandSilent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HasImageDecision {
    pub has_image: bool,
    pub policy: HasImagePolicy,
}

/// Decide whether the current clipboard should be treated as image content.
///
/// If Wayland answers with either MIME types or text, Wayland is authoritative
/// and X11's image advertisement is ignored. X11 is only consulted when
/// Wayland is fully silent.
pub fn decide_has_image(
    wayland_types: &str,
    wayland_text: &str,
    x11_types: &str,
) -> HasImageDecision {
    let wl_has_image = contains_image_mime(wayland_types);
    let x_has_image = contains_image_mime(x11_types);
    let wayland_answered = !wayland_types.trim().is_empty() || !wayland_text.trim().is_empty();

    if wayland_answered {
        let policy = if x_has_image && !wl_has_image {
            HasImagePolicy::WaylandAuthoritativeStaleX11Ignored
        } else {
            HasImagePolicy::WaylandAuthoritative
        };
        return HasImageDecision {
            has_image: wl_has_image,
            policy,
        };
    }

    HasImageDecision {
        has_image: x_has_image,
        policy: HasImagePolicy::X11FallbackWaylandSilent,
    }
}

fn contains_image_mime(types: &str) -> bool {
    types
        .split(|c: char| c == ',' || c == '\n' || c == '\r' || c == '\t' || c.is_whitespace())
        .any(|token| token.starts_with("image/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wayland_image_wins_when_wayland_answers() {
        assert_eq!(
            decide_has_image("text/plain\nimage/png", "", "text/plain"),
            HasImageDecision {
                has_image: true,
                policy: HasImagePolicy::WaylandAuthoritative,
            }
        );
    }

    #[test]
    fn stale_x11_image_is_ignored_when_wayland_has_text() {
        assert_eq!(
            decide_has_image(
                "text/plain",
                "https://github.com/recodeee/flashpaste",
                "TARGETS\nimage/png",
            ),
            HasImageDecision {
                has_image: false,
                policy: HasImagePolicy::WaylandAuthoritativeStaleX11Ignored,
            }
        );
    }

    #[test]
    fn x11_image_is_used_only_when_wayland_is_silent() {
        assert_eq!(
            decide_has_image("", "", "TARGETS,image/png"),
            HasImageDecision {
                has_image: true,
                policy: HasImagePolicy::X11FallbackWaylandSilent,
            }
        );
    }
}
