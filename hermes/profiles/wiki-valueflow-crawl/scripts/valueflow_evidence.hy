#!/usr/bin/env hy
"Measurements for the wiki-valueflow-crawl bot.

Decision-free. Runs the actual valueflow algorithms (ws-valueflo-algorithms +
ws-valueflo-vocabulary via kbb) against real economic wage observations
(BLS QCEW NAICS industry weekly wage), prints a SCANNED line + the analysis
output, and appends an immutable row to the valueflow ledger. REFUSED banner
on any failure so the bot is told it is blind, never that analysis is done.

This is an ANALYSIS bot, not a source-crawl bot: there is no verify_source
proposal gate. The agent's only job is to read this measurement and propose
ONE valueflow analysis finding for wiki.yataverse.com. publish is NOT granted.
"
(import json)
(import os)
(import subprocess)
(import sys)
(import datetime [datetime timezone])
(setv VFA
  ((. os.environ get) "VALUE_FLO_WORKTREE" ((. os.path expanduser) "~/github/com-junkawasaki/orgs/kotoba-lang/ws-valueflo-algorithms")))
(setv VOCAB
  ((. os.environ get) "VALUE_FLO_VOCAB" ((. os.path expanduser) "~/github/com-junkawasaki/orgs/kotoba-lang/ws-valueflo-vocabulary")))
(setv KBB ((. os.environ get) "VALUE_FLO_KBB" "/opt/homebrew/bin/kbb"))
(setv LEDGER
  ((. os.path join) ((. os.path dirname) ((. os.path abspath) __file__))
    ".."
    "workspace"
    "valueflow-ledger.jsonl"))
(setv POC
  ((. os.path join) ((. os.path dirname) ((. os.path abspath) __file__))
    ".."
    "workspace"
    "valueflow_analysis.cljs"))

(defn refuse [why]
  (print "REFUSED — no valueflow analysis was measured this run.")
  (print why)
  (print)
  (print "Do not propose anything. An analysis built on an unmeasurable tree is an analysis built on nothing. Report this refusal and stop.")
  (sys.exit 0))

(defn main []
  (for [p #(VFA VOCAB)]
   (when (not ((. os.path isdir) p)) (refuse f"missing checkout: {p}")))
  (when (not ((. os.path isfile) POC)) (refuse f"missing analysis source: {POC}"))
  (setv proc
    (subprocess.run [KBB "--backend" "sci" "--classpath" f"{VFA}/src:{VOCAB}/src" POC]
      :capture_output True
      :text True
      :timeout 180))
  (when (!= proc.returncode 0)
    (refuse
      (%
        "the analysis script exited %d:\n%s"
        #(proc.returncode
          (cut
  (or ((. proc.stderr strip)) ((. proc.stdout strip)))
  800)))))
  (setv stdout ((. proc.stdout strip)))
  (when (or (= stdout "") (not-in "SCANNED\t" stdout)) (refuse "the analysis produced no SCANNED line"))
  (setv now ((. (datetime.now timezone.utc) isoformat) :timespec "seconds"))
  (setv row
    {"measured_at" now
     "head"        (get ((. (get (stdout.splitlines) 0) split) "\t") -1)})
  (with [f (open LEDGER "a")]
    (f.write (+ (json.dumps row) "\n")))
  (print f"worktree\t{VFA}")
  (print f"ledger\t{LEDGER}")
  (print stdout))

(when (= __name__ "__main__") (main))