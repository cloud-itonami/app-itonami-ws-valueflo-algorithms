#!/usr/bin/env hy
"Measurements for the wiki-valueflow-crawl ECON job.

Decision-free. Runs the econ valueflow analysis (valueflow_econ.cljs) via kbb.
Prints SCANNED + MEASURE lines, appends an immutable ledger row.

Runs monthly (CPI) / quarterly (QCEW): these sources change on a month/quarter
cadence. Daily pings would be wasted tokens.
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
(setv HERE
  ((. os.path dirname) ((. os.path abspath) __file__)))
(setv LEDGER ((. os.path join) HERE ".." "workspace" "valueflow-ledger.jsonl"))
(setv SRC ((. os.path join) HERE ".." "workspace" "valueflow_econ.cljs"))

(defn refuse [why]
  (print "REFUSED — no econ valueflow analysis was measured this run.")
  (print why)
  (print)
  (print "Do not propose anything. Report this refusal and stop.")
  (sys.exit 0))

(defn main []
  (for [p #(VFA VOCAB)]
   (when (not ((. os.path isdir) p)) (refuse f"missing checkout: {p}")))
  (when (not ((. os.path isfile) SRC)) (refuse f"missing analysis source: {SRC}"))
  (setv proc
    (subprocess.run [KBB "--backend" "sci" "--classpath" f"{VFA}/src:{VOCAB}/src" SRC]
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
  (setv out ((. proc.stdout strip)))
  (when (not-in "SCANNED\t" out) (refuse "the analysis produced no SCANNED line"))
  (setv row
    {"measured_at" ((. (datetime.now timezone.utc) isoformat) :timespec "seconds")
     "job"         "econ"})
  (with [f (open LEDGER "a")]
    (f.write (+ (json.dumps row) "\n")))
  (print f"worktree\t{VFA}")
  (print f"ledger\t{LEDGER}")
  (print out))

(when (= __name__ "__main__") (main))