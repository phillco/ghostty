#!/bin/bash
case "${1-}" in
    -h|--help)
        printf 'Usage: %s\nPrint a detected URL and an OSC 8 hyperlink.\n' "$0"
        exit 0
        ;;
    '') ;;
    *) printf 'Usage: %s [-h|--help]\n' "$0" >&2; exit 2 ;;
esac

printf 'URL: https://example.com\n'
printf 'OSC 8: \033]8;;https://example.org\033\\Example link\033]8;;\033\\\n'
