const std = @import("std");

pub const component = @import("component.zig");
pub const input_mod = @import("input.zig");
pub const editor_mod = @import("editor.zig");
pub const markdown_mod = @import("markdown.zig");
pub const ansi = @import("ansi.zig");
pub const theme_mod = @import("theme.zig");
pub const highlight_mod = @import("highlight.zig");
pub const lines_util = @import("lines_util.zig");
pub const renderer_mod = @import("renderer.zig");
pub const tool_status_mod = @import("tool_status.zig");

pub const Component = component.Component;
pub const Container = component.Container;
pub const Text = component.Text;
pub const InputEvent = input_mod.InputEvent;
pub const InputAction = input_mod.Action;
pub const InputDecoder = input_mod.InputDecoder;
pub const Editor = editor_mod.Editor;
pub const Markdown = markdown_mod.Markdown;
pub const InlineRenderer = renderer_mod.InlineRenderer;
pub const ToolStatus = tool_status_mod.ToolStatus;
pub const ColorDepth = theme_mod.ColorDepth;
pub const Theme = theme_mod.Theme;
pub const ThemePalette = theme_mod.Palette;

test {
    _ = component;
    _ = input_mod;
    _ = editor_mod;
    _ = markdown_mod;
    _ = ansi;
    _ = theme_mod;
    _ = highlight_mod;
    _ = lines_util;
    _ = renderer_mod;
    _ = tool_status_mod;
}
