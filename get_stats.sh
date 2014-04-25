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
	[ "`echo "x$1" | grep "d"`"   ] && UPDATE="yes"
	[ "`echo "x$1" | grep "f"`"   ] && FETCH="yes"
	shift
fi

OLD="$1"
NEW="$2"

# Sanity check

if [ -z "$OLD" ]; then
	echo "usage:"
	echo "   $0 [-df] openSUSE:13.1 [openSUSE:Factory]"
	exit 1
fi

# Should we re-fetch changes

if [ "$FETCH" == yes ]; then

get_changes "$OLD" &
if [ "$NEW" ]; then
get_changes "$NEW" &
fi

wait
if [ "$NEW" ]; then
wait
fi

fi

# Should we recompute differences?

if [ "$UPDATE" == yes ] && [ "$NEW" ]; then

mkdir -p diff
cd "$NEW"
for i in *; do
	cmp "$i"
done

fi
