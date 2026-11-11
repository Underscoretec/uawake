#!/bin/zsh
# Stray uawake.app copies steal the uawake:// scheme and clutter Spotlight/Launchpad.
#   clean-apps.sh              unregister from Launch Services AND delete every stray copy
#   clean-apps.sh --unregister unregister only (build products stay on disk)
#   clean-apps.sh --tmp        delete build.noindex/tmp (throwaway test/perf copies) and unregister them
# Quit running copies first. Never deleted: /Applications/uawake.app (never touched) and the
# current build products (DerivedData Build/Products/<config>/uawake.app) — only unregistered.
set -u
cd "${0:A:h}/.."
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mode=${1:-all}

# Copies Launch Services knows about, plus any on disk in the usual build places.
paths=(${(f)"$( { $lsr -dump | sed -n -E 's/^path: +(.*uawake\.app)( |\/).*/\1/p'
                  find $PWD/build $PWD/build.noindex ~/Library/Developer/Xcode/DerivedData/uawake-* -name uawake.app -prune 2>/dev/null
                } | sort -u )"})
[[ $mode == --tmp ]] && paths=(${(M)paths:#$PWD/build.noindex/tmp/*})
paths=(${paths:#/Applications/*})
keep=($PWD/build.noindex/DerivedData/Build/Products/*/uawake.app(N)
      ~/Library/Developer/Xcode/DerivedData/uawake-*/Build/Products/*/uawake.app(N))
(( $+commands[pgrep] )) && pgrep -x uawake >/dev/null && echo "warning: a uawake is running; quit it first"

for p in $paths; do
  $lsr -u "$p" 2>/dev/null
  if [[ $mode == --unregister ]] || (( ${keep[(Ie)$p]} )); then echo "unregistered $p"; else rm -rf "$p"; echo "removed $p"; fi
done
[[ $mode == --tmp ]] && rm -rf build.noindex/tmp
(( ${#paths} )) || echo "no stray copies"
exit 0
