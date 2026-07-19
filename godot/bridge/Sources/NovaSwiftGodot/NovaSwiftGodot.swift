// NovaSwiftGodot — the GDExtension entry point.
//
// This registers the Swift-defined Godot classes with the engine when Godot
// dlopen's the built library and calls `swift_entry_point` (the symbol named in
// godot/NovaSwift.gdextension). Add every `@Godot` class to the `types:` list.
//
// See docs/GODOT_LAYER.md for the architecture.

import SwiftGodot

#initSwiftExtension(cdecl: "swift_entry_point", types: [
    NovaWorld.self,
])
