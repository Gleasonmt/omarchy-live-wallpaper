#!/bin/bash
# Live backgrounds: scenes that go with any theme. Each pack lives in
# ~/.config/omarchy/live-backgrounds/<pack>/ with the same layout a live theme
# uses (backgrounds/<name>.png, live/<name>.frag.qsb and friends). This links
# every pack's backgrounds into ~/.config/omarchy/backgrounds/<theme>/ for each
# installed theme, where Omarchy's background switcher looks. Picking one
# points the current background into the pack, where the plugin finds its
# shader.
#   link-backgrounds.sh [theme ...]     (default: every installed theme)
# Only links into the packs folder are ever made or removed (links into a pack
# that's gone are cleaned up); a file of yours with the same name is left alone.
# Run by the live-wallpaper plugin at startup, on theme changes and now and then.
set -uo pipefail
cfg=$HOME/.config/omarchy
packs=$cfg/live-backgrounds
user_bgs=$cfg/backgrounds
omarchy=${OMARCHY_PATH:-/usr/share/omarchy}

valid() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; }

if (( $# )); then
  themes=("$@")
else
  mapfile -t themes < <(
    { for d in "$omarchy"/themes/*/ "$cfg"/themes/*/; do [[ -d $d ]] && basename "$d"; done
      cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null; echo; } | sort -u
  )
fi

# Every pack background that has a shader: the scenes to offer.
scenes=()
for img in "$packs"/*/backgrounds/*; do
  [[ -f $img && ! -L $img ]] || continue
  name=${img##*/}
  valid "$name" || continue
  [[ -f ${img%/backgrounds/*}/live/${name%.*}.frag.qsb ]] && scenes+=("$img")
done

for theme in "${themes[@]}"; do
  valid "$theme" || continue
  (( ${#scenes[@]} )) || break
  dir=$user_bgs/$theme
  mkdir -p "$dir" || continue
  for img in "${scenes[@]}"; do
    dest=$dir/${img##*/}
    if [[ -L $dest ]]; then
      target=$(readlink "$dest")
      [[ $target == "$img" ]] && continue
      # ours, but into a pack that's gone: repoint it
      [[ $target == "$packs"/* && ! -e $target ]] || continue
    elif [[ -e $dest ]]; then
      continue   # someone's own file of that name
    fi
    ln -sfn "$img" "$dest"
  done
done

# Links into packs (or pictures) that have been removed
[[ -d $user_bgs ]] && find "$user_bgs" -mindepth 2 -maxdepth 2 -type l -print0 2>/dev/null |
  while IFS= read -r -d '' link; do
    target=$(readlink "$link")
    [[ $target == "$packs"/* && ! -e $target ]] && rm -f "$link"
  done
exit 0
