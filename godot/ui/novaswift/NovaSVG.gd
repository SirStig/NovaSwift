# NOVA Swift — NovaSwift UI kit: SVG icons and art.
#
# Godot rasterises SVG natively (Image.load_svg_from_string, ThorVG), so the kit's richer glyphs
# and decorative art are authored here as small SVG documents instead of NovaIcons' hand-rolled
# stroke ops. Rendering goes through the engine, so it is crisp at any size and far cheaper than
# the per-pixel GDScript rasteriser. NovaIcons.texture()/image() consult this set first, so every
# existing `T.icon("name")` / `C.icon_rect(...)` call picks the SVG version up automatically.
#
#   NovaSVG.texture("terminal", 18, Color.WHITE)     -> ImageTexture (cached)
#   NovaSVG.image("terminal", 18, Color.WHITE)       -> Image
#   NovaSVG.render(svg_source, Vector2i(w, h))       -> ImageTexture of an arbitrary SVG document
#   NovaSVG.has("terminal")
#
# Glyphs are the BODY of a 24 x 24 SVG (SF Symbols' grid). `C` is replaced with the requested
# colour, so write stroke="C" / fill="C". Strokes default to 1.8 px round caps/joins via the
# wrapping <g>; override per element. Keep shapes simple and SF-Symbol-like.
extends RefCounted

const _HEAD := "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' width='24' height='24'><g fill='none' stroke='C' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'>"
const _TAIL := "</g></svg>"

const GLYPHS := {
	# --- navigation / generic ----------------------------------------------------------------
	"chevron.right": "<path d='M9 5l7 7-7 7'/>",
	"chevron.left": "<path d='M15 5l-7 7 7 7'/>",
	"chevron.down": "<path d='M5 9l7 7 7-7'/>",
	"chevron.up": "<path d='M5 15l7-7 7 7'/>",
	"xmark": "<path d='M6 6l12 12M18 6L6 18' stroke-width='2.2'/>",
	"xmark.circle.fill": "<circle cx='12' cy='12' r='10' fill='C' stroke='none'/><path d='M8.5 8.5l7 7M15.5 8.5l-7 7' stroke='#000' stroke-opacity='0.85' stroke-width='2'/>",
	"plus": "<path d='M12 5v14M5 12h14' stroke-width='2.2'/>",
	"minus": "<path d='M5 12h14' stroke-width='2.2'/>",
	"checkmark": "<path d='M5 12.5l5 5L19 7' stroke-width='2.2'/>",
	"checkmark.circle.fill": "<circle cx='12' cy='12' r='10' fill='C' stroke='none'/><path d='M7.5 12.3l3.2 3.2L16.5 9' stroke='#000' stroke-opacity='0.85' stroke-width='2.2'/>",
	"checkmark.seal.fill": "<path fill='C' stroke='none' d='M12 1.8l2.4 1.9 3-.4 1.1 2.8 2.8 1.1-.4 3 1.9 2.4-1.9 2.4.4 3-2.8 1.1-1.1 2.8-3-.4L12 22.2l-2.4-1.9-3 .4-1.1-2.8-2.8-1.1.4-3L1.8 12l1.9-2.4-.4-3 2.8-1.1 1.1-2.8 3 .4z'/><path d='M8 12.2l2.7 2.7L16.2 9.4' stroke='#000' stroke-opacity='0.85' stroke-width='2'/>",
	"exclamationmark.triangle.fill": "<path fill='C' stroke='C' stroke-width='1.2' d='M10.3 3.6a2 2 0 013.4 0l8.2 14.6a2 2 0 01-1.7 3H3.8a2 2 0 01-1.7-3z'/><path d='M12 9v4.5' stroke='#000' stroke-opacity='0.85' stroke-width='2.2'/><circle cx='12' cy='17' r='1.25' fill='#000' fill-opacity='0.85' stroke='none'/>",
	"exclamationmark.circle.fill": "<circle cx='12' cy='12' r='10' fill='C' stroke='none'/><path d='M12 7v6' stroke='#000' stroke-opacity='0.85' stroke-width='2.2'/><circle cx='12' cy='16.6' r='1.25' fill='#000' fill-opacity='0.85' stroke='none'/>",
	"info.circle": "<circle cx='12' cy='12' r='9.5'/><path d='M12 11v6'/><circle cx='12' cy='7.6' r='1.1' fill='C' stroke='none'/>",
	"info.circle.fill": "<circle cx='12' cy='12' r='10' fill='C' stroke='none'/><path d='M12 11v6' stroke='#000' stroke-opacity='0.85' stroke-width='2.2'/><circle cx='12' cy='7.4' r='1.3' fill='#000' fill-opacity='0.85' stroke='none'/>",
	"questionmark.circle": "<circle cx='12' cy='12' r='9.5'/><path d='M9.4 9.3a2.7 2.7 0 015.2 1c0 1.8-2.6 2.3-2.6 4'/><circle cx='12' cy='17.3' r='1.1' fill='C' stroke='none'/>",
	"magnifyingglass": "<circle cx='10.5' cy='10.5' r='6.5' stroke-width='2'/><path d='M15.5 15.5l5 5' stroke-width='2.2'/>",
	"line.3.horizontal.decrease": "<path d='M4 7h16M7 12h10M10 17h4' stroke-width='2'/>",
	"arrow.clockwise": "<path d='M19 12a7 7 0 11-2.05-4.95'/><path d='M19.5 4v4.5H15'/>",
	"arrow.counterclockwise": "<path d='M5 12a7 7 0 102.05-4.95'/><path d='M4.5 4v4.5H9'/>",
	"arrow.right": "<path d='M4 12h16M14 6l6 6-6 6'/>",
	"arrow.down.circle.fill": "<circle cx='12' cy='12' r='10' fill='C' stroke='none'/><path d='M12 7v9M8 12.5l4 4 4-4' stroke='#000' stroke-opacity='0.85' stroke-width='2'/>",
	"arrow.up.right.square": "<rect x='3.5' y='3.5' width='17' height='17' rx='3.5'/><path d='M9.5 14.5l6-6M10 8.5h5.5V14'/>",
	"square.and.arrow.up": "<path d='M12 15V3.5M7.5 8L12 3.5 16.5 8'/><path d='M8 11H5.5v9.5h13V11H16'/>",
	"square.and.arrow.down": "<path d='M12 3.5V15M7.5 10.5L12 15l4.5-4.5'/><path d='M5 13v7h14v-7'/>",
	"doc.on.doc": "<rect x='8.5' y='3.5' width='12' height='14' rx='2'/><path d='M15.5 20.5H5.5a2 2 0 01-2-2v-10'/>",
	"doc.text": "<path d='M6 2.8h8l4.5 4.5v13.9H6z'/><path d='M14 2.8v4.5h4.5M9 12h6M9 15.5h6M9 9h2.5'/>",
	"folder": "<path d='M3 6.5a1.5 1.5 0 011.5-1.5h4.6l2 2.4h8.4A1.5 1.5 0 0121 8.9v9.6a1.5 1.5 0 01-1.5 1.5h-15A1.5 1.5 0 013 18.5z'/>",
	"trash": "<path d='M4 7h16M9 7V4.5h6V7M6.5 7l.8 13h9.4l.8-13M10 11v5.5M14 11v5.5'/>",
	"pencil": "<path d='M15.5 4.5l4 4L9 19l-5 1 1-5z'/><path d='M13.5 6.5l4 4'/>",
	"ellipsis": "<circle cx='5.5' cy='12' r='1.6' fill='C' stroke='none'/><circle cx='12' cy='12' r='1.6' fill='C' stroke='none'/><circle cx='18.5' cy='12' r='1.6' fill='C' stroke='none'/>",
	"star": "<path d='M12 3l2.7 5.8 6.3.7-4.7 4.3 1.3 6.2L12 16.9 6.4 20l1.3-6.2L3 9.5l6.3-.7z'/>",
	"star.fill": "<path fill='C' d='M12 3l2.7 5.8 6.3.7-4.7 4.3 1.3 6.2L12 16.9 6.4 20l1.3-6.2L3 9.5l6.3-.7z'/>",
	"clock": "<circle cx='12' cy='12' r='9'/><path d='M12 7v5.2l3.5 2'/>",
	"calendar": "<rect x='3.5' y='5' width='17' height='15.5' rx='2.5'/><path d='M3.5 10h17M8 3v4M16 3v4'/>",
	"link": "<path d='M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1.2 1.2'/><path d='M14 10a4 4 0 00-5.7 0l-3 3a4 4 0 005.7 5.7l1.2-1.2'/>",
	"globe": "<circle cx='12' cy='12' r='9'/><path d='M3 12h18M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9c-2.6-2.6-3.8-5.6-3.8-9s1.2-6.4 3.8-9z'/>",
	"person.crop.circle": "<circle cx='12' cy='12' r='9.5'/><circle cx='12' cy='9.8' r='3.3'/><path d='M6 18.3c1.4-2.1 3.5-3.2 6-3.2s4.6 1.1 6 3.2'/>",
	"tag": "<path d='M3.5 12.5V4.5a1 1 0 011-1h8l8 8a1.4 1.4 0 010 2l-7 7a1.4 1.4 0 01-2 0z'/><circle cx='8' cy='8' r='1.4' fill='C' stroke='none'/>",
	"eye": "<path d='M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z'/><circle cx='12' cy='12' r='3'/>",
	"eye.slash": "<path d='M2.5 12S6 5.5 12 5.5c1.6 0 3 .4 4.3 1M21.5 12s-3.5 6.5-9.5 6.5c-1.6 0-3-.4-4.3-1'/><path d='M4 20L20 4'/>",
	"pin": "<path d='M9 3.5h6l-1 5 3 3.5H7l3-3.5z'/><path d='M12 12v8.5'/>",
	"bolt.fill": "<path fill='C' d='M13.5 2.5L5 13.5h6l-1.5 8 8.5-11h-6z'/>",
	"lock.fill": "<rect x='5' y='10.5' width='14' height='10' rx='2.2' fill='C'/><path d='M8 10.5V7.5a4 4 0 018 0v3'/>",
	"lock.open.fill": "<rect x='5' y='10.5' width='14' height='10' rx='2.2' fill='C'/><path d='M8 10.5V7.5a4 4 0 017.6-1.8'/>",
	"circle": "<circle cx='12' cy='12' r='8.5' stroke-width='2'/>",
	"circle.fill": "<circle cx='12' cy='12' r='8.5' fill='C' stroke='none'/>",
	"circle.dashed": "<circle cx='12' cy='12' r='8.5' stroke-width='2' stroke-dasharray='3 3.2'/>",
	"smallcircle.filled.circle": "<circle cx='12' cy='12' r='9'/><circle cx='12' cy='12' r='4' fill='C' stroke='none'/>",
	"target": "<circle cx='12' cy='12' r='9'/><circle cx='12' cy='12' r='5'/><circle cx='12' cy='12' r='1.4' fill='C' stroke='none'/>",
	"location.fill": "<path fill='C' d='M20.5 3.5L3.5 11l7.2 2.3L13 20.5z'/>",
	"mappin.circle.fill": "<circle cx='12' cy='12' r='10' fill='C' stroke='none'/><circle cx='12' cy='10' r='3' stroke='#000' stroke-opacity='0.85' stroke-width='2'/><path d='M12 13v5' stroke='#000' stroke-opacity='0.85' stroke-width='2'/>",
	"flag.fill": "<path d='M5 21V4'/><path fill='C' d='M5 4.5c2.5-1.5 5-1.5 7 0s4.5 1.5 7 0v9c-2.5 1.5-5 1.5-7 0s-4.5-1.5-7 0z'/>",
	"flag.checkered": "<path d='M5 21V4'/><path d='M5 4.5c2.5-1.5 5-1.5 7 0s4.5 1.5 7 0v9c-2.5 1.5-5 1.5-7 0s-4.5-1.5-7 0z'/><path fill='C' stroke='none' d='M8.5 3.6v4.6c-1.2-.1-2.3.2-3.5.8V4.5c1.2-.6 2.3-.9 3.5-.9zM12 9.2V4.5c1.1.8 2.3 1.2 3.5 1.3v4.6c-1.2-.1-2.4-.5-3.5-1.2zM8.5 8.2c1.2 0 2.4.4 3.5 1v4.3c-1.1-.8-2.3-1.2-3.5-1.2zM15.5 10.4c1.2.1 2.3-.2 3.5-.8v3.9c-1.2.7-2.3 1-3.5 1z'/>",
	"xmark.octagon.fill": "<path fill='C' stroke='none' d='M8.2 2.5h7.6l5.7 5.7v7.6l-5.7 5.7H8.2l-5.7-5.7V8.2z'/><path d='M9 9l6 6M15 9l-6 6' stroke='#000' stroke-opacity='0.85' stroke-width='2.2'/>",
	# --- debug suite -------------------------------------------------------------------------
	"terminal": "<rect x='2.5' y='4' width='19' height='16' rx='3'/><path d='M6.5 9l3 3-3 3M11.5 15.5h6'/>",
	"terminal.fill": "<rect x='2.5' y='4' width='19' height='16' rx='3' fill='C' stroke='none'/><path d='M6.5 9l3 3-3 3M11.5 15.5h6' stroke='#000' stroke-opacity='0.85' stroke-width='2'/>",
	"slider.horizontal.3": "<path d='M3 7h18M3 12h18M3 17h18'/><circle cx='8' cy='7' r='2.2' fill='C'/><circle cx='16' cy='12' r='2.2' fill='C'/><circle cx='10' cy='17' r='2.2' fill='C'/>",
	"switch.2": "<rect x='3' y='4' width='18' height='7' rx='3.5'/><circle cx='17.5' cy='7.5' r='2' fill='C' stroke='none'/><rect x='3' y='13' width='18' height='7' rx='3.5'/><circle cx='6.5' cy='16.5' r='2'/>",
	"airplane": "<path fill='C' stroke='none' d='M12 2.5c.9 0 1.5 1 1.5 2.3V9.5l7.5 4.6v2l-7.5-2.3v4.4l2.3 1.8v1.6L12 20.5l-3.8 1.1V20l2.3-1.8v-4.4L3 16.1v-2l7.5-4.6V4.8c0-1.3.6-2.3 1.5-2.3z'/>",
	"shippingbox.fill": "<path fill='C' stroke='C' stroke-width='1' d='M12 2.8l8.5 4.3v9.8L12 21.2l-8.5-4.3V7.1z'/><path d='M3.8 7.2L12 11.4l8.2-4.2M12 11.4v9.6M7.8 5l8.3 4.3' stroke='#000' stroke-opacity='0.6' stroke-width='1.4'/>",
	"shippingbox": "<path d='M12 2.8l8.5 4.3v9.8L12 21.2l-8.5-4.3V7.1z'/><path d='M3.8 7.2L12 11.4l8.2-4.2M12 11.4v9.6'/>",
	"building.columns": "<path d='M3 9l9-5 9 5zM4 20.5h16M5.5 9.5v8.5M9.8 9.5v8.5M14.2 9.5v8.5M18.5 9.5v8.5'/>",
	"checklist": "<path d='M4 6.5l1.5 1.5 3-3M4 12.5l1.5 1.5 3-3M4 18.5l1.5 1.5 3-3M11.5 7h8.5M11.5 13h8.5M11.5 19h8.5'/>",
	"ladybug": "<path d='M7 8.5a5 5 0 0110 0v4.5a5 5 0 01-10 0z'/><path d='M12 8.5V18M9 5.5L7.5 3.5M15 5.5l1.5-2M3.5 11H7M17 11h3.5M4 17l3.3-1.5M20 17l-3.3-1.5'/><circle cx='9.8' cy='11.5' r='.9' fill='C' stroke='none'/><circle cx='14.2' cy='14.5' r='.9' fill='C' stroke='none'/>",
	"ladybug.fill": "<path fill='C' stroke='none' d='M7 8.5a5 5 0 0110 0v4.5a5 5 0 01-10 0z'/><path d='M12 8.5V18' stroke='#000' stroke-opacity='0.7'/><path d='M9 5.5L7.5 3.5M15 5.5l1.5-2M3.5 11H7M17 11h3.5M4 17l3.3-1.5M20 17l-3.3-1.5'/>",
	"waveform.path.ecg": "<path d='M2.5 12.5h4l2-5 3.5 11 3-8.5 1.5 2.5h5'/>",
	"gauge": "<path d='M4.2 17.5a9 9 0 1115.6 0'/><path d='M12 13.5l4-5'/><circle cx='12' cy='13.5' r='1.6' fill='C' stroke='none'/>",
	"cpu": "<rect x='6' y='6' width='12' height='12' rx='2'/><rect x='9.5' y='9.5' width='5' height='5' rx='.8'/><path d='M9.5 3v3M14.5 3v3M9.5 18v3M14.5 18v3M3 9.5h3M3 14.5h3M18 9.5h3M18 14.5h3'/>",
	"memorychip": "<rect x='3' y='7' width='18' height='10' rx='1.5'/><path d='M6 17v3M10 17v3M14 17v3M18 17v3M7 10.5h2.5v3H7zM14.5 10.5H17v3h-2.5z'/>",
	"list.bullet.rectangle": "<rect x='2.5' y='4' width='19' height='16' rx='3'/><path d='M10 9h8M10 12h8M10 15h8'/><circle cx='6.8' cy='9' r='.9' fill='C' stroke='none'/><circle cx='6.8' cy='12' r='.9' fill='C' stroke='none'/><circle cx='6.8' cy='15' r='.9' fill='C' stroke='none'/>",
	"wrench.and.screwdriver": "<path d='M14.5 6.5a3.5 3.5 0 00-4.6 4.6L4 17l3 3 5.9-5.9a3.5 3.5 0 004.6-4.6l-2.2 2.2-2.1-.6-.6-2.1z'/><path d='M15 15l4.5 4.5M17.5 4l2.5 2.5-3.5 3.5'/>",
	"hammer": "<path d='M4.5 19.5L13 11'/><path d='M11 4l7-.5 3 3.5-1 4-5-1z'/>",
	"play.fill": "<path fill='C' d='M7 4.5l12.5 7.5L7 19.5z'/>",
	"pause.fill": "<rect x='6' y='4.5' width='4' height='15' rx='1.2' fill='C' stroke='none'/><rect x='14' y='4.5' width='4' height='15' rx='1.2' fill='C' stroke='none'/>",
	"stop.fill": "<rect x='5.5' y='5.5' width='13' height='13' rx='2.5' fill='C' stroke='none'/>",
	"paperplane.fill": "<path fill='C' d='M21 3L3 10.5l7 2.5 2.5 7z'/><path d='M10 13l11-10' stroke='#000' stroke-opacity='0.5'/>",
	"envelope": "<rect x='3' y='5' width='18' height='14' rx='2.5'/><path d='M3.5 6.5L12 13l8.5-6.5'/>",
	"camera": "<path d='M3 8.5A1.5 1.5 0 014.5 7h3l1.5-2.5h6L16.5 7h3A1.5 1.5 0 0121 8.5v10a1.5 1.5 0 01-1.5 1.5h-15A1.5 1.5 0 013 18.5z'/><circle cx='12' cy='13' r='3.8'/>",
	"number": "<path d='M9.5 3.5L7.5 20.5M16.5 3.5l-2 17M4 8.5h16M3.5 15.5h16'/>",
	# --- story / map -------------------------------------------------------------------------
	"book": "<path d='M12 6.5c-2-1.7-5-2.2-8.5-1.8v14c3.5-.4 6.5.1 8.5 1.8 2-1.7 5-2.2 8.5-1.8v-14c-3.5-.4-6.5.1-8.5 1.8z'/><path d='M12 6.5v14'/>",
	"book.fill": "<path fill='C' d='M12 6.5c-2-1.7-5-2.2-8.5-1.8v14c3.5-.4 6.5.1 8.5 1.8 2-1.7 5-2.2 8.5-1.8v-14c-3.5-.4-6.5.1-8.5 1.8z'/><path d='M12 6.5v14' stroke='#000' stroke-opacity='0.6'/>",
	"map": "<path d='M3 6.3l6-2.3 6 2.3 6-2.3v13.7l-6 2.3-6-2.3-6 2.3z'/><path d='M9 4v13.7M15 6.3V20'/>",
	"map.fill": "<path fill='C' d='M3 6.3l6-2.3 6 2.3 6-2.3v13.7l-6 2.3-6-2.3-6 2.3z'/><path d='M9 4v13.7M15 6.3V20' stroke='#000' stroke-opacity='0.55'/>",
	"point.3.connected": "<circle cx='12' cy='5.5' r='2.4' fill='C'/><circle cx='5.5' cy='18' r='2.4' fill='C'/><circle cx='18.5' cy='18' r='2.4' fill='C'/><path d='M11 7.6L6.6 15.8M13 7.6l4.4 8.2M8 18h8'/>",
	"arrow.triangle.branch": "<path d='M6 3.5v8a4 4 0 004 4h8M6 11.5V20.5'/><path d='M15 12.5l3 3-3 3'/><circle cx='6' cy='3.5' r='.1'/>",
	"arrow.triangle.merge": "<path d='M6 3.5v6l6 6v5M18 3.5v6l-6 6'/><path d='M9.5 18l2.5 2.5 2.5-2.5'/>",
	"scope": "<circle cx='12' cy='12' r='8'/><path d='M12 2v5M12 17v5M2 12h5M17 12h5'/>",
	"sparkles": "<path fill='C' stroke='none' d='M10 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2zM18.5 3l1 3 3 1-3 1-1 3-1-3-3-1 3-1z'/>",
	"crown.fill": "<path fill='C' d='M3.5 8l4.5 4 4-7 4 7 4.5-4-1.8 10.5H5.3z'/>",
	"person.2.fill": "<circle cx='8.5' cy='8' r='3.4' fill='C' stroke='none'/><circle cx='16.5' cy='9' r='2.8' fill='C' stroke='none'/><path fill='C' stroke='none' d='M2.5 19c0-3.3 2.7-5 6-5s6 1.7 6 5zM15.5 19c0-1.6-.5-3-1.4-4 .8-.3 1.6-.5 2.4-.5 2.8 0 5 1.5 5 4.5z'/>",
	"gift.fill": "<rect x='3.5' y='8' width='17' height='4.5' rx='1' fill='C'/><path fill='C' d='M5 12.5h14V20a1 1 0 01-1 1H6a1 1 0 01-1-1z'/><path d='M12 8v13' stroke='#000' stroke-opacity='0.6'/><path d='M12 8C10.5 4 7 4 7 6s3 2 5 2zM12 8c1.5-4 5-4 5-2s-3 2-5 2z'/>",
	"creditcard": "<rect x='2.5' y='5' width='19' height='14' rx='2.5'/><path d='M2.5 9.5h19M6 15h4'/>",
	"shield.fill": "<path fill='C' d='M12 2.8l7.5 3v5.7c0 4.6-3.2 8.3-7.5 9.7-4.3-1.4-7.5-5.1-7.5-9.7V5.8z'/>",
	"scroll": "<path d='M7 4h11a2 2 0 012 2v1.5h-4M7 4a2 2 0 00-2 2v11.5a2.5 2.5 0 002.5 2.5H16a2 2 0 002-2V6'/><path d='M8.5 9h6M8.5 12.5h6M8.5 16h4'/>",
	# --- plug-ins ----------------------------------------------------------------------------
	"puzzlepiece.extension": "<path d='M4 8.5h4a2.2 2.2 0 114.4 0H16v4a2.2 2.2 0 110 4.4V20.5H4z'/>",
	"puzzlepiece.extension.fill": "<path fill='C' d='M4 8.5h4a2.2 2.2 0 114.4 0H16v4a2.2 2.2 0 110 4.4V20.5H4z'/>",
	"square.stack.3d.up": "<path d='M12 3l8.5 4.5L12 12 3.5 7.5z'/><path d='M3.5 12L12 16.5 20.5 12M3.5 16.5L12 21l8.5-4.5'/>",
	"square.grid.2x2": "<rect x='3.5' y='3.5' width='7.5' height='7.5' rx='1.8'/><rect x='13' y='3.5' width='7.5' height='7.5' rx='1.8'/><rect x='3.5' y='13' width='7.5' height='7.5' rx='1.8'/><rect x='13' y='13' width='7.5' height='7.5' rx='1.8'/>",
	"list.bullet": "<path d='M9 6.5h11M9 12h11M9 17.5h11'/><circle cx='4.8' cy='6.5' r='1.2' fill='C' stroke='none'/><circle cx='4.8' cy='12' r='1.2' fill='C' stroke='none'/><circle cx='4.8' cy='17.5' r='1.2' fill='C' stroke='none'/>",
	"icloud.and.arrow.down": "<path d='M7 18.5a4.5 4.5 0 01-.5-9 6 6 0 0111.4 1.2A3.9 3.9 0 0117.5 18.5'/><path d='M12 11.5v8.5M9 17l3 3 3-3'/>",
	"externaldrive": "<rect x='3' y='12' width='18' height='8' rx='2.5'/><path d='M5.5 12l2-6.5h9l2 6.5'/><circle cx='7.5' cy='16' r='.9' fill='C' stroke='none'/>",
	"photo": "<rect x='3' y='5' width='18' height='14' rx='2.5'/><circle cx='8.5' cy='10' r='1.7' fill='C' stroke='none'/><path d='M4 17.5l5-4 4 3 3.5-3.5 3.5 3.5'/>",
	"wand.and.stars": "<path d='M4.5 19.5L15 9'/><path fill='C' stroke='none' d='M17.5 2.5l1 3 3 1-3 1-1 3-1-3-3-1 3-1zM9 3l.7 1.8 1.8.7-1.8.7L9 8l-.7-1.8-1.8-.7 1.8-.7z'/>",
	"gearshape.fill": "<path fill='C' stroke='none' fill-rule='evenodd' d='M10.3 2.5h3.4l.5 2.6 1.6.7 2.2-1.5 2.4 2.4-1.5 2.2.7 1.6 2.6.5v3.4l-2.6.5-.7 1.6 1.5 2.2-2.4 2.4-2.2-1.5-1.6.7-.5 2.6h-3.4l-.5-2.6-1.6-.7-2.2 1.5-2.4-2.4 1.5-2.2-.7-1.6-2.6-.5v-3.4l2.6-.5.7-1.6-1.5-2.2 2.4-2.4 2.2 1.5 1.6-.7zM12 8.8a3.2 3.2 0 100 6.4 3.2 3.2 0 000-6.4z'/>",
}

static var _cache := {}
static var _extra := {}   # glyphs registered at runtime (register()) by other screens/tools


static func has(name: String) -> bool:
	return GLYPHS.has(name) or _extra.has(name)


## Add (or replace) a glyph at runtime: `body` is the inner SVG of a 24 x 24 icon, same rules as
## GLYPHS. Lets a screen ship its own glyphs without editing this file.
static func register(name: String, body: String) -> void:
	_extra[name] = body
	for k in _cache.keys():
		if String(k).begins_with(name + "/"):
			_cache.erase(k)


## A glyph's full SVG document in `color`.
static func source(name: String, color := Color.WHITE) -> String:
	var hex := "#" + color.to_html(false)
	var body: String = _extra.get(name, GLYPHS.get(name, "<rect x='6' y='6' width='12' height='12' rx='2'/>"))
	var doc := _HEAD + body + _TAIL
	doc = doc.replace("'C'", "'" + hex + "'")
	if color.a < 0.999:
		doc = doc.replace("<g fill='none'", "<g opacity='%.3f' fill='none'" % color.a)
	return doc


## The glyph rasterised at `px` x `px` in `color`.
static func image(name: String, px := 16, color := Color.WHITE) -> Image:
	return raster(source(name, color), Vector2i(px, px), Vector2i(24, 24))


static func texture(name: String, px := 16, color := Color.WHITE) -> Texture2D:
	var key := "%s/%d/%s" % [name, px, color.to_html()]
	if not _cache.has(key):
		_cache[key] = ImageTexture.create_from_image(image(name, px, color))
	return _cache[key]


## Rasterise any SVG document to `size` px. `native` is the document's own width/height (its
## viewBox size when it declares width/height to match); the scale is size / native, taking the
## smaller axis so the art fits. Returns a transparent image on a parse failure.
static func raster(svg: String, size: Vector2i, native := Vector2i.ZERO) -> Image:
	var img := Image.new()
	var nat := native
	if nat == Vector2i.ZERO:
		nat = size
	var k := minf(float(size.x) / float(nat.x), float(size.y) / float(nat.y))
	if img.load_svg_from_string(svg, k) != OK or img.is_empty():
		img = Image.create(maxi(1, size.x), maxi(1, size.y), false, Image.FORMAT_RGBA8)
		return img
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.get_size() != size:
		var out := Image.create(maxi(1, size.x), maxi(1, size.y), false, Image.FORMAT_RGBA8)
		var at := (size - img.get_size()) / 2
		out.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), at)
		img = out
	return img


## An arbitrary SVG document (decorative art, empty-state illustrations, badges) as a texture.
## Cached by `cache_key` when given.
static func render(svg: String, size: Vector2i, native := Vector2i.ZERO, cache_key := "") -> Texture2D:
	if cache_key != "" and _cache.has(cache_key):
		return _cache[cache_key]
	var tex := ImageTexture.create_from_image(raster(svg, size, native))
	if cache_key != "":
		_cache[cache_key] = tex
	return tex
