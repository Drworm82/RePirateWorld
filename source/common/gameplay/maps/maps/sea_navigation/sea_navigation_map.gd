class_name SeaNavigationMap
extends Map

func _draw() -> void:
	draw_rect(Rect2(-1200, -700, 2400, 1400), Color("#2a8fa8"), true)
	draw_circle(Vector2(-360, -220), 150.0, Color("#d4c28b"))
	draw_circle(Vector2(390, 250), 180.0, Color("#d4c28b"))
	draw_circle(Vector2(0, 0), 38.0, Color("#7ad7df"), false, 5.0)
