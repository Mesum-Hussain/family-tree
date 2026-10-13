#!/usr/bin/env bash
# Builds Shajra.html: index.html with every local stylesheet and script inlined,
# so the whole tree can be shared as one file that works offline.
#
#   ./shajra_builder.sh           write Shajra.html
#   ./shajra_builder.sh --check   exit 1 if Shajra.html is missing or out of date
#
# Any problem aborts the build and leaves Shajra.html untouched.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SOURCE=index.html
OUTPUT=Shajra.html

# The only two forms of external reference the build knows how to inline.
STYLE_LINE='^([[:space:]]*)<link[[:space:]]+rel="stylesheet"[[:space:]]+href="([^"]+)"[[:space:]]*/?>[[:space:]]*$'
SCRIPT_LINE='^([[:space:]]*)<script[[:space:]]+src="([^"]+)"></script>[[:space:]]*$'
# Anything else that would make the page depend on another file.
EXTERNAL_LINE='<link[[:space:]>]|[[:space:]](src|srcset|poster)[[:space:]]*='

temporary=
trap '[[ -z $temporary ]] || rm -f "$temporary"' EXIT

fail() {
	echo "build failed: $*" >&2
	exit 1
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

[[ -f $SOURCE ]] || fail "$SOURCE not found."

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
