#!/bin/sh

test_description='Test stg.main'

. ./test-lib.sh

if test -z "$STG_RUST"; then
test_expect_success 'Test no command' '
    general_error stg 2>err &&
    grep -e "usage:" err
'
else
test_expect_success 'Test no command' '
    general_error stg 2>err &&
    grep -e "USAGE:" err
'
fi

test_expect_success 'Test help/--help equivalence' '
    stg help 2>&1 > h0.txt &&
    stg --help 2>&1 > h1.txt &&
    diff h0.txt h1.txt
'

if test -z "$STG_RUST"; then
test_expect_success 'Test help on invalid command' '
    general_error stg help invalidcmd 2>err &&
    grep -e "Unknown command: invalidcmd" err
'
else
test_expect_success 'Test help on invalid command' '
    general_error stg help invalidcmd 2>err &&
    grep -e "error:  The subcommand .invalidcmd. wasn.t recognized" err
'
fi

if test -z "$STG_RUST"; then
test_expect_success 'Test help on regular command' '
    stg help init | grep -e "Usage: stg init"
'
else
test_expect_success 'Test help on regular command' '
    stg help init | grep -e "stg-init"
'
fi

if test -z "$STG_RUST"; then
test_expect_success 'Test --help on regular command' '
    stg --help refresh | grep -e "Usage: stg refresh"
'
else
    : # --help <cmd> is not valid in rust implementation
fi

if test -z "$STG_RUST"; then
test_expect_success 'Test help on ambiguous command' '
    general_error stg help pu 2>err &&
    grep -e "Ambiguous command: pu" err
'
else
test_expect_success 'Test help on ambiguous command' '
    general_error stg pu 2>err &&
    grep -e "Did you mean .pu... or .pu..." err &&
    general_error stg help pu 2>err &&
    grep -e "The subcommand .pu. wasn.t recognized" err
'
fi

if test -z "$STG_RUST"; then
test_expect_success 'Test version/--version equivalence' '
    stg version > v0.txt &&
    stg --version > v1.txt &&
    diff v0.txt v1.txt &&
    grep -e "Stacked Git" v0.txt &&
    grep -F "$(git --version)" v0.txt &&
    grep -e "Python 3\." v0.txt
'
else
test_expect_success 'Test version/-V/--version differences' '
    stg version > v0.txt &&
    stg --version > v1.txt &&
    stg -V > v2.txt &&
    test_cmp v1.txt v2.txt &&
    !(test_cmp v0.txt v1.txt) &&
    grep -e "Stacked Git" v0.txt &&
    grep -e "git version" v0.txt &&
    grep -e "stg" v1.txt
'
fi

if test -z "$STG_RUST"; then
test_expect_success 'Test copyright' '
    stg copyright | grep -e "This program is free software"
'
fi

if test -n "$STG_RUST"; then
test_expect_success 'Test exec-path and subcommand relationship' '
    stg series -h > series-help.txt &&
    head -n 1 series-help.txt | grep "stg-series" &&
    cat series-help.txt | grep -A1 "USAGE:" | grep "stg series "
'
fi

test_done
