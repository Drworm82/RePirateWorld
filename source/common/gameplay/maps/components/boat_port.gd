class_name BoatPort
extends Node2D

@export var destination_label: String = "Sea Route"

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	# High-contrast MVP marker. The port is intentionally visible above the
	# y-sorted map so players can find it without relying on a hidden trigger.
	draw_circle(Vector2.ZERO, 220.0, Color(0.02, 0.22, 0.28, 0.18), true)
	draw_circle(Vector2.ZERO, 160.0, Color(0.08, 0.55, 0.68, 0.24), true)
	draw_circle(Vector2.ZERO, 112.0, Color(0.86, 0.68, 0.20, 0.95), true)
	draw_circle(Vector2.ZERO, 112.0, Color(1.0, 0.92, 0.58, 1.0), false, 8.0)
	draw_circle(Vector2.ZERO, 76.0, Color(0.20, 0.13, 0.07, 1.0), false, 6.0)
	draw_line(Vector2(-52, 0), Vector2(52, 0), Color(0.20, 0.13, 0.07, 1.0), 10.0, true)
	draw_line(Vector2(0, -52), Vector2(0, 52), Color(0.20, 0.13, 0.07, 1.0), 10.0, true)

	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-96, -132), "BOAT PORT", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color.WHITE)
	draw_string(font, Vector2(-96, 148), "TO: " + destination_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)
	draw_string(font, Vector2(-96, 176), "E: BOARD", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
