#!/bin/sh

test_description='Run "stg squash"'

. ./test-lib.sh

test_expect_success 'Initialize StGit stack' '
    test_commit_bulk --start=0 --filename=foo.txt --contents="foo %s" --message="p%s" 6 &&
    stg uncommit -n 6 &&
    for i in 0 1 2 3 4 5; do
        git notes add -m "note$i" $(stg id p$i) || return 1
    done
'

test_expect_success 'Too few arguments' '
    command_error stg squash p0 2>err &&
    grep -e "need at least two patches" err
'

test_expect_success 'Attempt duplicate patch name' '
    command_error stg squash -n p3 -- p0 p1 2>err &&
    grep -e "patch name \`p3\` already taken" err
'

test_expect_success 'Attempt invalid patch name' '
    general_error stg squash -n invalid..name -- p0 p1 2>err &&
    grep -e "invalid value .invalid..name. for .--name <name>.: invalid patch name" err
'

test_expect_success 'Attempt out of order' '
    conflict stg squash --name=q4 p5 p4 &&
    stg undo --hard
'

test_expect_success 'Squash out of order no conflict' '
    echo hello >bar.txt &&
    stg add bar.txt &&
    stg new -m bar-patch &&
    stg refresh &&
    stg squash -n q5 bar-patch p5 &&
    [ "$(echo $(stg series --applied --noprefix))" = "p0 p1 p2 p3 p4 q5" ]
'

test_expect_success 'Squash out of order no conflict no name' '
    echo hello >baz.txt &&
    stg add baz.txt &&
    stg new -m baz-patch &&
    stg refresh &&
    stg squash -m q6 baz-patch q5 &&
    [ "$(echo $(stg series --applied --noprefix))" = "p0 p1 p2 p3 p4 q6" ]
'

test_expect_success 'Save template' '
    stg squash --save-template mytemplate p1 p2 &&
    test_path_is_file mytemplate &&
    [ "$(echo $(stg series --applied --noprefix))" = "p0 p1 p2 p3 p4 q6" ] &&
    echo "squashed patch" >mytemplate &&
    stg squash --file=mytemplate p1 p2 &&
    [ "$(echo $(stg series --applied --noprefix))" = "p0 squashed-patch p3 p4 q6" ]
'

test_expect_success 'Squash some patches' '
    stg squash --message="wee woo" p3 p4 q6 &&
    [ "$(echo $(stg series --applied --noprefix))" = "p0 squashed-patch wee-woo" ] &&
    [ "$(echo $(stg series --unapplied --noprefix))" = "" ]
'

test_expect_success 'Squash at stack top' '
    stg squash --name=q1 --message="wee woo wham" squashed-patch wee-woo &&
    [ "$(echo $(stg series --applied --noprefix))" = "p0 q1" ] &&
    [ "$(echo $(stg series --unapplied --noprefix))" = "" ]
'

test_expect_success 'Squash patches with all non-default author' '
    echo "a" >>baz.txt &&
    stg new -rm "a-patch" --author "Other Contributor <another@example.com>" &&
    echo "b" >>baz.txt &&
    stg new -rm "b-patch" --author "Other Contributor <another@example.com>" &&
    echo "c" >>baz.txt &&
    stg new -rm "c-patch" --author "Other Contributor <another@example.com>" &&
    stg squash -m "abc-patch" a-patch b-patch c-patch &&
    test_when_finished "stg delete abc-patch" &&
    stg show abc-patch | grep "Author:" >out &&
    cat >expected <<-\EOF &&
	Author: Other Contributor <another@example.com>
	EOF
    test_cmp expected out
'

test_expect_success 'Squash patches with some non-default author' '
    echo "a" >>baz.txt &&
    stg new -rm "a-patch" &&
    echo "b" >>baz.txt &&
    stg new -rm "b-patch" --author "Other Contributor <another@example.com>" &&
    echo "c" >>baz.txt &&
    stg new -rm "c-patch" &&
    stg squash -m "abc-patch" a-patch b-patch c-patch &&
    test_when_finished "stg delete abc-patch" &&
    stg show abc-patch | grep "Author:" >out &&
    cat >expected <<-\EOF &&
	Author: A Ú Thor <author@example.com>
	EOF
    test_cmp expected out
'

test_expect_success 'Squash patches with author override' '
    echo "a" >>baz.txt &&
    stg new -rm "a-patch" --author "Other Contributor <another@example.com>" &&
    echo "b" >>baz.txt &&
    stg new -rm "b-patch" --author "Other Contributor <another@example.com>" &&
    echo "c" >>baz.txt &&
    stg new -rm "c-patch" --author "Other Contributor <another@example.com>" &&
    stg squash -m "abc-patch" --author "Override Author <override@example.com>" a-patch b-patch c-patch &&
    test_when_finished "stg delete abc-patch" &&
    stg show abc-patch | grep "Author:" >out &&
    cat >expected <<-\EOF &&
	Author: Override Author <override@example.com>
	EOF
    test_cmp expected out
'

test_expect_success 'Empty commit message aborts the squash' '
    write_script fake-editor <<-\EOF &&
	echo "" >"$1"
	EOF
    test_set_editor "$(pwd)/fake-editor" &&
    test_when_finished test_set_editor false &&
    command_error stg squash --name=p0 p0 q1 2>err &&
    grep -e "aborting due to empty patch description" err &&
    test "$(echo $(stg series))" = "+ p0 > q1"
'

test_expect_success 'Squash with top != head' '
    write_script fake-editor <<-\EOF &&
	#!/bin/sh
	echo "Editor was invoked" | tee editor-invoked
	EOF
    echo blahonga >>foo.txt &&
    git commit -a -m "a new commit" &&
    EDITOR=./fake-editor command_error stg squash --name=r0 p0 q1 &&
    test "$(echo $(stg series))" = "+ p0 > q1" &&
    test_path_is_missing editor-invoked
'

test_expect_success 'Squash patches with multiple authors adds Co-authored-by trailers' '
    echo "a" >>multiple.txt &&
    stg new -rm "multi-patch-1" --author "Author One <author1@example.com>" &&
    echo "b" >>multiple.txt &&
    stg new -rm "multi-patch-2" --author "Author Two <author2@example.com>" &&
    echo "c" >>multiple.txt &&
    stg new -rm "multi-patch-3" --author "Author One <author1@example.com>" &&
    write_script squash-editor <<-\EOF &&
	#!/bin/sh
	# Keep everything up to the Co-authored-by trailers, remove only comment lines
	sed '/^#/d' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
	EOF
    EDITOR=./squash-editor stg squash --name=multi-squashed multi-patch-1 multi-patch-2 multi-patch-3 &&
    test_when_finished "stg delete multi-squashed 2>/dev/null || true" &&
    stg show multi-squashed | grep "Author:" >out &&
    cat >expected <<-\EOF &&
	Author: A Ú Thor <author@example.com>
	EOF
    test_cmp expected out &&
    git log -1 --pretty=format:"%B" >commit_message &&
    grep "Co-authored-by: Author One <author1@example.com>" commit_message &&
    grep "Co-authored-by: Author Two <author2@example.com>" commit_message
'

test_expect_success 'Squash patches with same author does not add Co-authored-by trailers' '
    echo "x" >>same.txt &&
    stg new -rm "same-patch-1" --author "Same Author <same@example.com>" &&
    echo "y" >>same.txt &&
    stg new -rm "same-patch-2" --author "Same Author <same@example.com>" &&
    write_script same-editor <<-\EOF &&
	#!/bin/sh
	# Keep everything, remove only comment lines  
	sed '/^#/d' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
	EOF
    EDITOR=./same-editor stg squash --name=same-squashed same-patch-1 same-patch-2 &&
    test_when_finished "stg delete same-squashed 2>/dev/null || true" &&
    stg show same-squashed | grep "Author:" >out &&
    cat >expected <<-\EOF &&
	Author: Same Author <same@example.com>
	EOF
    test_cmp expected out &&
    git log -1 --pretty=format:"%B" >commit_message &&
    ! grep "Co-authored-by" commit_message
'

test_done
