#!/usr/bin/env hy
"ISIC classification backfill for the wiki-valueflow-crawl bot.

Existing GLEIF legal entities carry NO industry field. This job classifies a
batch of legal entities (name + jurisdiction + legal_form) into an ISIC section
using gpt-oss-120b direct via OpenRouter, then aggregates the classified
entities into industry x jurisdiction valueflow recipe shapes and writes them
as an EDN proposal for wiki.yataverse.com.

Decidable parts (GLEIF read, ISIC call, aggregation, EDN write) live here; the
agent's only job is to read the SCANNED/MEASURE output and propose ONE finding.

Run with a batch size. The full 127k-entity backfill fits under a 10B
token/day budget (250 tok/entity => 32M token total => under 1 day).
"
(import json)
(import os)
(import re)
(import subprocess)
(import sys)
(import urllib.request)
(import datetime [datetime timezone])
(setv HERE
  ((. os.path dirname) ((. os.path abspath) __file__)))
(setv LEDGER ((. os.path join) HERE ".." "workspace" "valueflow-ledger.jsonl"))
(setv OUT ((. os.path join) HERE ".." "workspace" "gleif-isic-backfill.edn"))
(setv PROGRESS ((. os.path join) HERE ".." "workspace" "gleif-isic-progress.jsonl"))

(defn _load_env []
  "Read this profile's .env (runtime injects it; manual runs need it)."
  (setv env_path ((. os.path join) HERE ".." ".env"))
  (when (and
          ((. os.path isfile) env_path)
          (not ((. os.environ get) "OPENROUTER_API_KEY")))
    (for [line (open env_path)]
      (setv line (line.strip))
      (when (and line (not (line.startswith "#")) (in "=" line))
        (setv #(k v) (line.split "=" 1))
        ((. os.environ setdefault) k
          ((. ((. (v.strip) strip) "\"") strip) "'"))))))

(_load_env)
(setv BATCH (int ((. os.environ get) "VF_BACKFILL_BATCH" "50")))
(setv API "https://openrouter.ai/api/v1/chat/completions")
(setv KEY ((. os.environ get) "OPENROUTER_API_KEY" ""))
(setv MODEL ((. os.environ get) "VF_CLASSIFY_MODEL" "openai/gpt-oss-120b"))
(setv ISIC_SECTIONS
  ["A Agriculture, forestry and fishing"
   "B Mining and quarrying"
   "C Manufacturing"
   "D Electricity, gas, steam and air conditioning supply"
   "E Water supply; sewerage, waste management"
   "F Construction"
   "G Wholesale and retail trade; repair of motor vehicles"
   "H Transportation and storage"
   "I Accommodation and food service activities"
   "J Information and communication"
   "K Financial and insurance activities"
   "L Real estate activities"
   "M Professional, scientific and technical activities"
   "N Administrative and support service activities"
   "O Public administration and defence"
   "P Education"
   "Q Human health and social work activities"
   "R Arts, entertainment and recreation"
   "S Other service activities"])

(defn refuse [why]
  (print "REFUSED — no backfill measurement this run.")
  (print why)
  (print "Report this refusal and stop.")
  (sys.exit 0))

(defn read_gleif_batch [limit]
  "Read the next unprocessed batch of GLEIF legal entities from R2.

    Deterministic. Skips LEIs already recorded in the progress ledger so each
    run classifies NEW entities (no re-classifying the same firm). Returns
    [] (refuse-worthy) only if everything is processed or read fails.
    "
  (setv seen (set))
  (when ((. os.path isfile) PROGRESS)
    (for [line (open PROGRESS)]
      (setv line (line.strip))
      (when line
        (try
          (seen.add ((. (json.loads line) get) "lei"))
          (except [Exception])))))
  (setv code "\nimport sys\nsys.path.insert(0, 'scripts')\nimport datalake_catalog\ncat = datalake_catalog.connect()\nt = cat.load_table(('cloud_itonami','gleif_lei_joined'))\ndf = t.scan().to_arrow().to_pylist()\nimport json\nprint(json.dumps(df))\n")
  (setv env (dict os.environ))
  (setv (get env "CF_CATALOG_TOKEN") ((. ((. (os.popen "security find-generic-password -s gftd.cf -a API_TOKEN -w 2>/dev/null") read)) strip)))
  (setv r
    (subprocess.run ["/opt/homebrew/bin/python3" "-c" code]
      :capture_output True
      :text True
      :cwd ((. os.path expanduser) "~/github/com-junkawasaki")
      :env env
      :timeout 120))
  (when (!= r.returncode 0)
    (refuse (+ "GLEIF R2 read failed: " (cut ((. r.stderr strip)) 300))))
  (setv ents
    (json.loads (get ((. ((. r.stdout strip)) split) "\n") -1)))
  (setv fresh
    (lfor e ents
      :if (not-in (e.get "lei") seen)
      e))
  (print f"MEASURE\tbackfill.total\t{(len ents)}")
  (print f"MEASURE\tbackfill.processed-so-far\t{(len seen)}")
  (print f"MEASURE\tbackfill.pending\t{(len fresh)}")
  (return (cut fresh limit)))

(defn classify [entity]
  "ISIC section for one legal entity via gpt-oss-120b. "
  (setv name (entity.get "legal_name" ""))
  (setv juris (entity.get "jurisdiction" ""))
  (setv lf (entity.get "legal_form" ""))
  (setv prompt
    (+
      (+ f"Classify this legal entity into exactly one ISIC section (letter + title), based on the company name.\nName: {name}\nJurisdiction: {juris}\nLegal form code: {lf}\nISIC sections:\n" ((. "\n" join) ISIC_SECTIONS))
      "\nReply with ONLY the section letter (A-S), nothing else."))
  (setv body
    ((. (json.dumps {"model" MODEL  "messages" [{"role" "user"  "content" prompt}]  "max_tokens" 512  "temperature" 0})
       encode)))
  (setv req
    ((. urllib.request Request) API
      :data body
      :headers {"Authorization" f"Bearer {KEY}"  "Content-Type" "application/json"}))
  (try
    (with [resp ((. urllib.request urlopen) req :timeout 30)]
      (setv data (json.loads (resp.read)))
      (setv msg (get (get (get data "choices") 0) "message"))
      (setv content ((. (or (msg.get "content") "") strip)))
      (when (and (not content) (msg.get "reasoning"))
        (setv content ((. (get msg "reasoning") strip))))
      (setv m (re.search "\\b([A-S])\\b" content))
      (return
        (if m (m.group 1) (+ "X:" (cut content -20 None)))))
    (except [e Exception] (return (+ "ERR:" (cut (repr e) 80))))))

(defn main []
  (when (not KEY) (refuse "OPENROUTER_API_KEY not set in this profile's .env"))
  (setv ents (read_gleif_batch BATCH))
  (when (not ents)
    (print "SCANNED\t0")
    (print "MEASURE\tbackfill.status\tALL-PROCESSED")
    (print "No unprocessed GLEIF entities remain. The 4-month backfill is complete. Do not open a PR proposing re-classification.")
    (with [f (open LEDGER "a")]
      (f.write (+
                (json.dumps {"measured_at" ((. (datetime.now timezone.utc) isoformat) :timespec "seconds")
                             "job"         "backfill"
                             "status"      "complete"})
                "\n")))
    (sys.exit 0))
  (setv results [])
  (for [e ents]
    (setv sec (classify e))
    (results.append {"lei"          (get e "lei")
                     "legal_name"   (get e "legal_name")
                     "jurisdiction" (get e "jurisdiction")
                     "isic"         sec})
    (with [f (open PROGRESS "a")]
      (f.write (+
                (json.dumps {"lei"  (get e "lei")
                             "isic" sec
                             "at"   ((. (datetime.now timezone.utc) isoformat) :timespec "seconds")})
                "\n"))))
  (import collections [Counter])
  (setv agg (Counter (gfor r results #((get r "isic") (get r "jurisdiction")))))
  (with [f (open OUT "w")]
    (f.write (% ";; gleif-isic backfill proposal (generated %s)\n[\n" ((. (datetime.now timezone.utc) isoformat) :timespec "seconds")))
    (setv lines [])
    (for [#(#(isic juris) n) (agg.most_common)]
      (lines.append f"  {{:isic \"{isic}\" :jurisdiction \"{juris}\" :entities {n}}}"))
    (f.write (+ ((. ",\n" join) lines) "\n]\n")))
  (setv row
    {"measured_at" ((. (datetime.now timezone.utc) isoformat) :timespec "seconds")
     "job"         "backfill"
     "batch"       (len results)
     "classified"  (sum
  (gfor r results
    :if (not ((. (get r "isic") startswith) "ERR"))
    1))})
  (with [f (open LEDGER "a")]
    (f.write (+ (json.dumps row) "\n")))
  (print f"SCANNED\t{(len results)}")
  (print f"MEASURE\tbackfill.classified\t{(get row "classified")}")
  (print f"MEASURE\tbackfill.batch\t{(len results)}")
  (print f"MEASURE\tbackfill.proposal\t{OUT}")
  (import collections [Counter :as C])
  (for [#(#(isic juris) n) (agg.most_common 10)]
    (print f"MEASURE\tbackfill.agg.{isic}/{juris}\t{n}"))
  (print (+ "EDN proposal written to " OUT)))

(when (= __name__ "__main__") (main))