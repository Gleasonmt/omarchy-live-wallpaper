#!/bin/bash
# Lite copies of live-wallpaper themes, so Omarchy's theme picker offers both
# "Topside" (full motion) and "Topside Lite" (only small parts move).
#   make-lite.sh [themes-dir]     (default ~/.config/omarchy/themes)
# For every theme whose live/mode.json isn't "details", <name>-lite is made
# (or remade when the theme has changed since, e.g. after `omarchy theme
# update`), without its .git, src, media or README, with live/mode.json set to
# details and LITE on its preview. Lite copies whose theme is gone are
# removed. Only folders carrying this script's marker are ever replaced or
# removed. Run by the live-wallpaper plugin at startup and now and then.
set -uo pipefail
themes=${1:-$HOME/.config/omarchy/themes}
marker=.made-by-live-wallpaper
[[ -d $themes ]] || exit 0

font=$(magick -list font 2>/dev/null | awk '/Font: (Adwaita-Sans-Bold|DejaVu-Sans-Bold|Noto-Sans-Bold|Liberation-Sans-Bold)$/ && !f { print $2; f = 1 }')
badge_font=()
[[ -n $font ]] && badge_font=(-font "$font")

for mode in "$themes"/*/live/mode.json; do
  [[ -e $mode ]] || continue
  dir=${mode%/live/mode.json}
  name=${dir##*/}
  [[ $name == *-lite || -e $dir/$marker || -e $dir/.made-by-omarchy-themes ]] && continue
  grep -q '"details"' "$mode" && continue
  lite="$themes/$name-lite"
  if [[ -e $lite && ! -e $lite/$marker && ! -e $lite/.made-by-omarchy-themes ]]; then
    continue   # someone's own theme of that name: leave it alone
  fi
  if [[ -e $lite/$marker ]] && [[ -z $(find -L "$dir" -path "$dir/.git" -prune -o -type f -newer "$lite/$marker" -print -quit 2>/dev/null) ]]; then
    continue   # up to date
  fi
  tmp="$themes/.$name-lite.tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  find -L "$dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name src ! -name media ! -name 'preview.*' ! -iname 'README*' ! -name LICENSE \
    -exec cp -rL {} "$tmp/" \;
  printf '{\n  "mode": "details"\n}\n' >"$tmp/live/mode.json"
  preview=$(find -L "$dir" -maxdepth 1 -type f -iname 'preview.*' | sort | head -1)
  if [[ -n $preview ]]; then
    # preview.jpg, so "<name>-lite.jpg" sorts right after "<name>.jpg" in the picker
    magick "$preview" -resize 1800x1012^ -gravity center -extent 1800x1012 -gravity southeast \
      -fill '#f2f2f2e6' -draw "roundrectangle 1560,910 1772,992 18,18" \
      -fill '#111111' "${badge_font[@]}" -pointsize 48 -annotate +74+36 'LITE' -quality 90 "$tmp/preview.jpg" 2>/dev/null \
      || cp "$preview" "$tmp/preview.${preview##*.}"
  fi
  touch "$tmp/$marker"
  rm -rf "$lite"
  mv "$tmp" "$lite"
  echo "made $name-lite"
done

# Lite copies whose theme has been removed
for lite in "$themes"/*-lite; do
  [[ -e $lite/$marker && ! -d ${lite%-lite} ]] && rm -rf "$lite" && echo "removed ${lite##*/}"
done
exit 0
