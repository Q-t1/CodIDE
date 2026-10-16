# Nerd Font glyphs for the editor (nvim.nix), written as codepoints. Nerd Font
# icons sit in Unicode's private-use area, which editors, terminals and
# copy-paste silently drop — how the original literal glyphs were lost — so
# this source stays ASCII and
# builtins.fromJSON decodes the \u escapes Nix strings lack. Keep to codepoints
# below U+FFFF (nf-md-* icons above it would need a surrogate pair).
let
  glyph = hex: builtins.fromJSON ''"\u${hex}"'';
in
{
  error = glyph "f057"; # nf-fa-times_circle
  warn = glyph "f071"; # nf-fa-warning
  info = glyph "f05a"; # nf-fa-info_circle
  hint = glyph "f0eb"; # nf-fa-lightbulb_o
  lsp = glyph "f013"; # nf-fa-gear
}
