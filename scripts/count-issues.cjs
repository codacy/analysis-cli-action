#!/usr/bin/env node
// Prints the number of issues in a Codacy Analysis CLI report.
// Usage: count-issues.cjs <report> <sarif|json>
// SARIF holds one run per tool, each with its results; the CLI's JSON report
// is the AnalysisResult, whose `issues` array is already flat.
"use strict";

const fs = require("fs");

const [report, format] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(report, "utf8"));
const count =
  format === "sarif"
    ? (data.runs ?? []).reduce((sum, run) => sum + (run.results ?? []).length, 0)
    : (data.issues ?? []).length;
process.stdout.write(String(count));
