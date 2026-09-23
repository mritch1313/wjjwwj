class_name HudBar
extends Control

## Small code-drawn progress bar used by the HUD (nitro charge, escape timer,
## arrest progress).  No textures: two rectangles and an optional caption, which
## keeps the mobile fill rate down.

var value: float = 0.0
var caption: String = ""
var fill_color: Color = Color(0.15, 0.75, 0.95)
var background_color: Color = Color(0.05, 0.06, 0.08, 0.65)
var border_color: Color = Color(0.85, 0.87, 0.90, 0.35)
var corner_radius: float = 4.0
var glow: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_value(new_value: float, new_caption: String = "") -> void:
	value = clampf(new_value, 0.0, 1.0)
	if new_caption != "":
		caption = new_caption
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, background_color, true)
	draw_rect(rect, border_color, false, 1.0)
	var inner := Rect2(Vector2(2.0, 2.0), Vector2(maxf(size.x - 4.0, 0.0) * value, maxf(size.y - 4.0, 0.0)))
	if inner.size.x > 0.5:
		draw_rect(inner, fill_color, true)
		if glow:
			draw_rect(inner, Color(fill_color.r, fill_color.g, fill_color.b, 0.35), false, 3.0)
	if caption != "":
		var font := ThemeDB.fallback_font
		var font_size := int(clampf(size.y * 0.62, 10.0, 22.0))
		var text_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var text_position := Vector2(
			(size.x - text_size.x) * 0.5,
			(size.y + text_size.y) * 0.5 - text_size.y * 0.2
		)
		draw_string(font, text_position + Vector2(1.0, 1.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.7))
		draw_string(font, text_position, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.97, 0.97, 0.99))
