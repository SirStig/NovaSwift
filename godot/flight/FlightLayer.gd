# One canvas layer of the flight view: a Node2D that runs a draw callable in its own _draw, with a
# blend mode of its own. A CanvasItem has ONE blend mode, so the renderer stacks several of these in
# the Apple scene's order (hulls normal, glows additive, fog fill, booms additive, ...).
#   "mix"  normal alpha blending
#   "add"  additive (CanvasItemMaterial BLEND_MODE_ADD): glows, booms, beams, ember particles
#   "fill" the silhouette shader: every sprite draws as a flat colour at modulate.a * texture alpha,
#          which is exactly Apple's colorBlendFactor mix toward a colour (murk fog, ionize, gate wash)
extends Node2D

const FILL_SHADER := """
shader_type canvas_item;
varying vec4 tint;
void vertex() { tint = COLOR; }
void fragment() { COLOR = vec4(tint.rgb, tint.a * texture(TEXTURE, UV).a); }
"""

var draw_fn: Callable
var mode := "mix"


func setup(blend: String, fn: Callable) -> void:
	mode = blend
	draw_fn = fn
	match blend:
		"add":
			var m := CanvasItemMaterial.new()
			m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			material = m
		"fill":
			var sh := Shader.new()
			sh.code = FILL_SHADER
			var sm := ShaderMaterial.new()
			sm.shader = sh
			material = sm


func _draw() -> void:
	if draw_fn.is_valid():
		draw_fn.call(self)
