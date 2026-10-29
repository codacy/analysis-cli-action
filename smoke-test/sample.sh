#!/bin/sh
# Smoke-test input for CI: ShellCheck's SC2086 (unquoted expansion), enabled in
# Codacy's default configuration, fires on the line below.
echo $1
