#!/usr/bin/env bash
# ship-gate's first mutmut run on a module. Sourced by gauntlet-selftest.sh after the scope cases.
# A first run with no baseline mutated the whole API: over 30 minutes to ship one changed file.

baseline_is() {  # baseline_is <label> <exact baseline content>
  N=$((N+1))
  got=$(cat apps/api/.mutmut-baseline 2>/dev/null)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want:\n%s\n       got:\n%s\n' "$1" "$2" "$got"; fi
}

echo "ship-gate mutmut first run"
scoped_repo sg_first
rm -f apps/api/.mutmut-baseline
printf '    app.slugs.x_old__mutmut_1: survived\n    app.auth.login.x_check__mutmut_1: survived\n' > survivors
sg "a first run records what survives, and blocks nothing" \
   "first run for app.orders.__init__ app.slugs: 1 existing survivor(s) recorded" 2
baseline_is "and names each module it ran" "# module app.orders.__init__
# module app.slugs
app.slugs.x_old__mutmut_1"

printf '    app.slugs.x_old__mutmut_1: survived\n    app.slugs.x_new__mutmut_2: survived\n' > survivors
sg "the next run fails on a new survivor only" "app.slugs.x_new__mutmut_2" 1

echo "x=1" > apps/api/app/pay.py
printf '    app.slugs.x_old__mutmut_1: survived\n    app.pay.x_charge__mutmut_1: survived\n' > survivors
sg "a module the baseline never ran is recorded, not charged" "first run for app.pay: 1 existing survivor(s)" 2

echo "x=1" > apps/api/app/ship.py
printf '    app.slugs.x_new__mutmut_2: survived\n    app.ship.x_go__mutmut_1: survived\n' > survivors
sg "a known module's new survivor still fails beside a first-run one" "app.slugs.x_new__mutmut_2" 1
baseline_is "and the first-run module is recorded all the same" "# module app.orders.__init__
# module app.pay
# module app.ship
# module app.slugs
app.pay.x_charge__mutmut_1
app.ship.x_go__mutmut_1
app.slugs.x_old__mutmut_1"

# A baseline from before module lines came from a whole-repo run, so it already covers everything.
scoped_repo sg_first_legacy
printf 'app.slugs.x_old__mutmut_1\n' > apps/api/.mutmut-baseline
printf '    app.slugs.x_new__mutmut_2: survived\n' > survivors
sg "an older baseline still charges a new survivor" "app.slugs.x_new__mutmut_2" 1
baseline_is "and is left as it was" "app.slugs.x_old__mutmut_1"
