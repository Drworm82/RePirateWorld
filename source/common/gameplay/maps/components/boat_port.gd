class_name BoatPort
extends Node2D

@export var destination_label: String = "Sea Route"

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 140.0, Color(0.05, 0.35, 0.42, 0.22), true)
	draw_circle(Vector2.ZERO, 72.0, Color(0.82, 0.69, 0.30, 0.9), true)
	draw_circle(Vector2.ZERO, 72.0, Color(0.95, 0.9, 0.65, 0.95), false, 5.0)
	draw_line(Vector2(-42, 0), Vector2(42, 0), Color(0.16, 0.10, 0.05), 8.0)
	draw_line(Vector2(0, -42), Vector2(0, 42), Color(0.16, 0.10, 0.05), 8.0)
	draw_string(ThemeDB.fallback_font, Vector2(-58, 112), destination_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
