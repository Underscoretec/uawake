#!/bin/zsh
# Stray uawake.app copies steal the uawake:// scheme and clutter Spotlight/Launchpad.
#   clean-apps.sh              unregister from Launch Services AND delete every copy outside /Applications
#   clean-apps.sh --unregister unregister only (build products stay on disk)
#   clean-apps.sh --tmp        delete build.noindex/tmp (throwaway test/perf copies) and unregister them
# Quit running copies first; /Applications/uawake.app is never touched.
set -u
cd "${0:A:h}/.."
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mode=${1:-all}

# Copies Launch Services knows about, plus any on disk in the usual build places.
paths=(${(f)"$( { $lsr -dump | sed -n -E 's/^path: +(.*uawake\.app)( |\/).*/\1/p'
                  find build build.noindex ~/Library/Developer/Xcode/DerivedData/uawake-* -name uawake.app -prune 2>/dev/null
                } | sort -u )"})
[[ $mode == --tmp ]] && paths=(${(M)paths:#$PWD/build.noindex/tmp/*})
paths=(${paths:#/Applications/*})
(( $+commands[pgrep] )) && pgrep -x uawake >/dev/null && echo "warning: a uawake is running; quit it first"

for p in $paths; do
  $lsr -u "$p" 2>/dev/null
  if [[ $mode != --unregister ]]; then rm -rf "$p"; echo "removed $p"; else echo "unregistered $p"; fi
done
[[ $mode == --tmp ]] && rm -rf build.noindex/tmp
(( ${#paths} )) || echo "no stray copies"
exit 0
