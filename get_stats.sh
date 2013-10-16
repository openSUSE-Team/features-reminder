#!/bin/sh

# Fetch all changes files from selected repo
get_changes() {
	mkdir -p "$1"
	cd "$1"
	osc ls "$1" | while read pkg; do
		echo getting "$pkg"
		mkdir -p "$pkg"
		osc cat "$1/$pkg/$pkg.changes" >  $pkg/$pkg.changes || rm -rf "$pkg"
	done
	cd ..
}

# Creates files with additions to the new version
cmp() {
	pushd . > /dev/null
	cd ..
	echo "Getting diff for $1"
	diff -Nar -u0 "$OLD/$1/$1.changes" "$NEW/$1/$1.changes" | tail -n +4 | sed -n 's|^+||p' > diff/$1
	popd > /dev/null
}


# Parse cmd line arguments

if [ "`echo "x$1" | grep "^x-"`" ]; then
	[ "`echo "x$1" | grep "u"`"   ] && UPDATE="yes"
	[ "`echo "x$1" | grep "f"`"   ] && FETCH="yes"
	shift
fi

OLD="$1"
NEW="$2"

# Sanity check

if [ -z "$OLD" ] || [ -z "$NEW" ]; then
	echo "usage:"
	echo "   $0 [-uf] openSUSE:12.3 openSUSE:Factory"
	exit 1
fi

# Should we re-fetch changes

if [ "$FETCH" == yes ]; then

get_changes "$OLD" &
get_changes "$NEW" &

wait
wait

fi

# Should we recompute differences?

if [ "$UPDATE" == yes ]; then

mkdir -p diff
cd "$NEW"
for i in *; do
	cmp "$i"
done

fi
