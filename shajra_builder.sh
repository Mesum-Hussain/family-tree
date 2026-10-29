#!/usr/bin/env bash
# Builds Shajra.html: index.html with every local stylesheet and script inlined,
# so the whole tree can be shared as one file that works offline.
#
#   ./shajra_builder.sh               update the libraries, then write Shajra.html
#   ./shajra_builder.sh --no-update   write Shajra.html with the libraries as they are
#   ./shajra_builder.sh --check       exit 1 if Shajra.html is missing or out of date
#
# Any problem aborts the build and leaves Shajra.html untouched.
#
# Libraries (js/resources):
#   d3.custom.min.js  rebuilt from npm with the newest d3 7 release. Staying on d3 7 keeps
#                     dTree working; a newer major version is only reported.
#   dTree.min.js      patched by hand for d3 7, and upstream (npm d3-dtree) stopped at 2.4.1,
#                     so it is only checked: a newer release is reported for porting by hand.
#   lodash-shim.js    our own code, nothing to update.
# Without npm or a network connection the update is skipped and the build goes on.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SOURCE=index.html
OUTPUT=Shajra.html

D3_FILE=js/resources/d3.custom.min.js
D3_MAJOR=7
D3_MODULES=(d3-selection d3-zoom d3-hierarchy d3-shape d3-transition)
DTREE_VERSION=2.4.1

# The only two forms of external reference the build knows how to inline.
STYLE_LINE='^([[:space:]]*)<link[[:space:]]+rel="stylesheet"[[:space:]]+href="([^"]+)"[[:space:]]*/?>[[:space:]]*$'
SCRIPT_LINE='^([[:space:]]*)<script[[:space:]]+src="([^"]+)"></script>[[:space:]]*$'
# Anything else that would make the page depend on another file.
EXTERNAL_LINE='<link[[:space:]>]|[[:space:]](src|srcset|poster)[[:space:]]*='

temporary=
workdir=
trap '[[ -z $temporary ]] || rm -f "$temporary"; [[ -z $workdir ]] || rm -rf "$workdir"' EXIT

fail() {
	echo "build failed: $*" >&2
	exit 1
}

skip_update() {
	echo "note: $*; building with the libraries as they are." >&2
}

version_of() {
	node -p "require('$workdir/node_modules/$1/package.json').version"
}

# The d3 and module versions named in the first two lines of the bundle, one per line.
bundle_versions() {
	head -n 2 "$1" | grep -oE 'd3(-[a-z]+)? v?[0-9]+\.[0-9]+\.[0-9]+' | sed 's/ v/ /'
}

# Rebuild the d3 bundle from the newest d3 $D3_MAJOR release on npm. The file is only
# replaced when a version changed, so a newer esbuild alone does not rewrite it.
update_d3() {
	local d3_version modules= module wanted bundle latest
	(cd "$workdir" && npm init -y && npm install --no-audit --no-fund "d3@$D3_MAJOR" esbuild) \
		>/dev/null 2>&1 || { skip_update "could not download d3 from npm (offline?)"; return 0; }

	d3_version=$(version_of d3)
	wanted="d3 $d3_version"
	for module in "${D3_MODULES[@]}"; do
		modules+="$module $(version_of "$module"), "
		wanted+=$'\n'"$module $(version_of "$module")"
	done

	if [[ $(bundle_versions "$D3_FILE") == "$wanted" ]]; then
		echo "Libraries up to date (d3 $d3_version, dTree $DTREE_VERSION)."
	else
		printf 'import "d3-transition";\nexport { select, zoom, zoomIdentity, hierarchy, tree, line, curveStepAfter } from "d3";\n' \
			> "$workdir/entry.js"
		bundle=$workdir/d3.custom.min.js
		{
			printf '// d3 v%s, only the parts dTree uses:\n// %s. Copyright 2010-2023 Mike Bostock, ISC license.\n' \
				"$d3_version" "${modules%, }"
			printf '// Rebuilt by shajra_builder.sh: esbuild (--bundle --minify --format=iife --global-name=d3) of an entry file\n'
			printf '// that imports "d3-transition" and exports select, zoom, zoomIdentity, hierarchy, tree, line, curveStepAfter.\n'
			"$workdir/node_modules/.bin/esbuild" "$workdir/entry.js" --bundle --minify --format=iife \
				--global-name=d3 --legal-comments=none --log-level=warning
		} > "$bundle" || fail "could not bundle d3 $d3_version with esbuild."
		node --check "$bundle" || fail "the rebuilt d3 bundle has a syntax error (see above)."
		# Copy next to the target and rename, so a failure never leaves half a file.
		temporary=$(mktemp "$D3_FILE.XXXXXX")
		cp "$bundle" "$temporary"
		chmod 644 "$temporary"
		mv "$temporary" "$D3_FILE"
		temporary=
		echo "Updated $D3_FILE to d3 $d3_version ($(bundle_versions "$D3_FILE" | tail -n +2 | paste -sd, - | sed 's/,/, /g'))."
	fi

	latest=$(npm view d3 version 2>/dev/null) || latest=
	if [[ -n $latest && ${latest%%.*} != "$D3_MAJOR" ]]; then
		echo "note: d3 $latest is out; it is a new major version, so dTree may need changes before it can use it." >&2
	fi
}

check_dtree() {
	local latest
	latest=$(npm view d3-dtree version 2>/dev/null) || return 0
	if [[ -n $latest && $latest != "$DTREE_VERSION" ]]; then
		echo "note: dTree $latest is out (we have $DTREE_VERSION, patched for d3 $D3_MAJOR); js/resources/dTree.min.js has to be updated by hand." >&2
	fi
}

update_libraries() {
	command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
		|| { skip_update "npm or node not found"; return 0; }
	workdir=$(mktemp -d)
	update_d3
	check_dtree
}

check_local() {
	local reference=$1
	[[ ! $reference =~ ^([A-Za-z][A-Za-z0-9+.-]*:)?// ]] \
		|| fail "$reference is a remote URL; download it into the project so the output works offline."
	[[ $reference != /* && $reference != *..* ]] \
		|| fail "$reference is outside the project folder."
	[[ -f $reference ]] \
		|| fail "$reference is referenced by $SOURCE but does not exist."
}

# Print a file without BOM or carriage returns, always ending in a newline.
clean() {
	sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e '$a\' "$1"
}

inline_style() {
	local indent=$1 reference=$2
	check_local "$reference"
	if grep -Eiq '@import|url\([[:space:]]*["'\'']?[^"'\''d#[:space:]]' "$reference"; then
		fail "$reference loads another file (@import or url()), which would be missing from $OUTPUT."
	fi
	if grep -iq '</style' "$reference"; then
		fail "$reference contains \"</style\", which would cut the inlined stylesheet short."
	fi
	printf '%s<style>\n/* %s */\n' "$indent" "$reference"
	clean "$reference"
	printf '%s</style>\n' "$indent"
}

# Drop the indentation, which is most of the size of the hand-edited tree data.
# Only safe when no string runs over several lines, so anything else is left as it is.
compact() {
	if grep -q -e '`' -e '\\$' "$1"; then
		cat
	else
		sed -E 's/^[[:space:]]+//'
	fi
}

inline_script() {
	local indent=$1 reference=$2 is_data=${3:-}
	check_local "$reference"
	if [[ -n $have_node ]]; then
		node --check "$reference" >&2 || fail "$reference has a JavaScript syntax error (see above)."
	fi
	printf '%s<script>\n/* %s */\n' "$indent" "$reference"
	# A source map comment would point at a file that is not shipped with the output.
	# Inside <script> the HTML parser, not JavaScript, decides where the script ends,
	# so "</script" and "<!--" have to be broken up even within strings and regexes.
	clean "$reference" | if [[ -n $is_data ]]; then compact "$reference"; else cat; fi | sed -E \
		-e '/^[[:space:]]*\/\/[#@][[:space:]]*sourceMappingURL=/d' \
		-e 's#</([sS][cC][rR][iI][pP][tT])#<\\/\1#g' \
		-e 's#<!--#<\\!--#g'
	printf '%s</script>\n' "$indent"
}

build() {
	local line number=0 has_data= is_data
	while IFS= read -r line || [[ -n $line ]]; do
		number=$((number + 1))
		line=${line%$'\r'}
		if [[ $line =~ $STYLE_LINE ]]; then
			inline_style "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		elif [[ $line =~ $SCRIPT_LINE ]]; then
			is_data=
			if grep -Eq '(^|[^A-Za-z0-9_$.])treeData[[:space:]]*=' "${BASH_REMATCH[2]}" 2>/dev/null; then
				has_data=1
				is_data=1
			fi
			inline_script "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$is_data"
		elif [[ $line =~ $EXTERNAL_LINE ]]; then
			fail "$SOURCE line $number: do not know how to inline this, put it on its own line as <script src=\"...\"></script> or <link rel=\"stylesheet\" href=\"...\">: $line"
		else
			printf '%s\n' "$line"
		fi
	done < "$SOURCE"
	[[ -n $has_data ]] || fail "$SOURCE does not load a script that defines treeData, so the tree would be empty."
}

case ${1:-} in
	'' | --check | --no-update) ;;
	*) fail "unknown option ${1}; use --check or --no-update." ;;
esac

[[ -f $SOURCE ]] || fail "$SOURCE not found."

# --check only compares, so it must not change any file.
if [[ -z ${1:-} ]]; then
	update_libraries
fi

have_node=
if command -v node >/dev/null 2>&1; then
	have_node=1
else
	echo "note: node not found, skipping the JavaScript syntax check." >&2
fi

# Build next to the target and rename, so a failed build never leaves half a file.
temporary=$(mktemp "$OUTPUT.XXXXXX")
build > "$temporary"

size="$(( $(wc -c < "$temporary") / 1024 )) KB"

if [[ ${1:-} == --check ]]; then
	if ! cmp -s "$temporary" "$OUTPUT"; then
		echo "$OUTPUT is missing or out of date; run: ./shajra_builder.sh" >&2
		exit 1
	fi
	echo "$OUTPUT is up to date ($size)."
elif cmp -s "$temporary" "$OUTPUT"; then
	echo "$OUTPUT already up to date ($size)."
else
	chmod 644 "$temporary"
	mv "$temporary" "$OUTPUT"
	temporary=
	echo "Wrote $OUTPUT ($size)."
fi
