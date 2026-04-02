#!/usr/bin/env bash
# problems.sh — Inline PG problem sources for CI tests.
# Each variable holds a complete PG problem as a string.

# PROBLEM_BASIC: One numeric answer (42), no randomization.
read -r -d '' PROBLEM_BASIC << 'PGEOF' || true
DOCUMENT();
loadMacros('PGstandard.pl', 'MathObjects.pl', 'PGML.pl');
Context("Numeric");
$answer = Compute("42");
BEGIN_PGML
What is the answer to everything?
[_____]{$answer}
END_PGML
ENDDOCUMENT();
PGEOF

# PROBLEM_MULTI: Two answer blanks (3 and 5).
read -r -d '' PROBLEM_MULTI << 'PGEOF' || true
DOCUMENT();
loadMacros('PGstandard.pl', 'MathObjects.pl', 'PGML.pl');
Context("Numeric");
$a = Compute("3");
$b = Compute("5");
BEGIN_PGML
What is 1+2? [_____]{$a}
What is 2+3? [_____]{$b}
END_PGML
ENDDOCUMENT();
PGEOF

# PROBLEM_RANDOM: Uses random(), answer = $n^2. Seed-sensitive.
read -r -d '' PROBLEM_RANDOM << 'PGEOF' || true
DOCUMENT();
loadMacros('PGstandard.pl', 'MathObjects.pl', 'PGML.pl');
Context("Numeric");
$n = random(2, 20);
$answer = Compute("$n^2");
BEGIN_PGML
What is [$n]^2?
[_____]{$answer}
END_PGML
ENDDOCUMENT();
PGEOF
