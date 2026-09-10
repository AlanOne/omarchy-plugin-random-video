#!/bin/bash
# Example "Cmd" source for the Random Video plugin. ytroulette.com picks a
# random YouTube video entirely client-side: its own JS calls
# rndCategoria()/rndVideo() to get a random category + position, then POSTs
# those to its own roulette.php and gets back {"idVideo": "...", ...}. The
# raw page itself has nothing to fetch (confirmed: yt-dlp's generic
# extractor fails on it directly) -- this script just replicates that same
# POST and prints a plain YouTube watch URL, which the plugin then resolves
# with yt-dlp like any other source.
#
# Paste the full path to this script as a "Cmd" source in the popup, e.g.:
#   bash /path/to/resolvers/ytroulette.sh
set -euo pipefail

# Mirrors the site's own numVideos array (video count per category) as of
# 2026-09 -- if ytroulette.com changes these, picks will just clamp to
# fewer/more videos than actually exist for a category; harmless either way
# since roulette.php doesn't appear to validate strictly, but re-check the
# live page's own `numVideos`/`categorias` JS if this stops returning results.
counts=(37854 13851 7511 8141 9189 10832 14322 7908)

# Matches the site's own rndCategoria(): Math.floor(random() * (len-1)),
# deliberately excluding the last ("ZERO(rare)") category from rotation.
cat=$(( RANDOM % (${#counts[@]} - 1) ))
max=${counts[$cat]}
pos=$(( RANDOM % (max - 1) ))

id=$(curl -s -A "Mozilla/5.0" -e "https://ytroulette.com/" \
  -X POST "https://ytroulette.com/roulette.php" \
  -d "pos=$pos&cat=$cat" | sed -n 's/.*"idVideo":"\([^"]*\)".*/\1/p')

[[ -n $id ]] || exit 1
echo "https://www.youtube.com/watch?v=$id"
