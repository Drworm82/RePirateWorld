class_name BoatVisual
extends Node2D

var heading: float = 0.0
var boat_state: String = "docked"
var owner_player_id: int = 0

func set_state(state: Dictionary) -> void:
	global_position = Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
	heading = float(state.get("heading", 0.0))
	boat_state = str(state.get("state", "docked"))
	queue_redraw()

func _draw() -> void:
	draw_set_transform(Vector2.ZERO, heading)
	draw_colored_polygon(PackedVector2Array([
		Vector2(42, 0), Vector2(18, -18), Vector2(-34, -18), Vector2(-48, 0),
		Vector2(-34, 18), Vector2(18, 18)
	]), Color("#7b4d2a"))
	draw_circle(Vector2.ZERO, 11.0, Color("#d9b36c"))
	draw_line(Vector2(8, -28), Vector2(8, 28), Color("#3f2a1b"), 5.0)
	draw_line(Vector2(8, -25), Vector2(34, 0), Color("#f4ead0"), 3.0)
