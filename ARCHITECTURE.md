# Architecture

Dplug is an audio plugin framework.

Its core value proposition is abstracting over:
- the various plugin formats. Dplug implements 5 plugin "client" and 1 plugin "host".
- the various OS windowing

so that developers can focus on a portable codebase for audio software.



## Plugin clients


`dplug:vst2`, `dplug:vst3`, `dplug:au`, `dplug:lv2`, and `dplug-aax` are "plugin clients" libraries.
These subpackage depends on the "generic client" `dplug:client`.



## OS windows

`dplug:window` implements windowing for the various OS. It implements `IWindow`.
Each window is given a `IWindowListener`.


# GUI subsystem

`dplug:client` defines `IGraphics` which is implemented by `dplug:gui`.
`dplug:gui` is at the interface between `dplug:window` and `dplug:client`.

`dplug:gui` also define a widget system, whose base class is `UIElement`.
In Dplug, that UI system is Physically Based Rendered through the use of two layers: the "Raw" and "PBR layer". The PBR layer is slow to update but support more complex rendering. The Raw layer is quick to update and is always on top.

The god object orchestrating all this is `GUIGraphics`.

Within each layer, widgets are Z-ordered for drawing and events.

`dplug:pbr-widget` and `dplug:flatwidgets` are different collections of widgets that act on these layers. They can act as base class, or examples, for custom widgets.


# Graphics subsystem

`dplug:math` defines small vectors, rectangles, and matrices.

`dplug:graphics` defines drawing surfaces and a lot of low-level rendering routines. They are considered a legacy way to draw on screen. This is based on a fork of `ae:graphics`, a stripped-down generic library for working with images.

`dplug:canvas` is a 2D rasterizer library that provide quick RGBA drawing with a friendly interface. It is now the preferred way to draw on screen.

[More info on this in the Wiki.](https://github.com/AuburnSounds/Dplug/wiki)
