#!/bin/sh
# Fetch the colour palettes of Omarchy's themes (MIT, (c) David Heinemeier Hansson) into
# board/overlay/usr/share/mylinux/themes/<name>/colors.toml (+ light.mode where applicable).
set -e
cd "$(dirname "$0")/.."
DEST=board/overlay/usr/share/mylinux/themes
THEMES="tokyo-night catppuccin catppuccin-latte lumon ethereal everforest gruvbox miasma hackerman osaka-jade kanagawa nord matte-black vantablack ristretto retro-82 flexoki-light rose-pine white"
LIGHT="catppuccin-latte flexoki-light rose-pine white"
for t in $THEMES; do
  mkdir -p "$DEST/$t"
  curl -fsSL "https://raw.githubusercontent.com/basecamp/omarchy/master/themes/$t/colors.toml" -o "$DEST/$t/colors.toml"
  case " $LIGHT " in *" $t "*) touch "$DEST/$t/light.mode" ;; esac
  printf '%s ' "$t"
done; echo
cat > "$DEST/LICENSE.omarchy" <<'L'
The colour palettes in these theme directories come from Omarchy (https://github.com/basecamp/omarchy),
Copyright (c) David Heinemeier Hansson, MIT License. Backgrounds are generated locally (tools/gen-wallpaper.py).
L
