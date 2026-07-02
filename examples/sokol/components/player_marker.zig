// Empty tag component used by gizmos/player_marker.zon to attach a
// debug outline to the player entity. Marker components carry no
// data — their only purpose is letting the gizmo registry's
// `.match = .{"PlayerMarker"}` rule find the entity.
pub const PlayerMarker = struct {};
