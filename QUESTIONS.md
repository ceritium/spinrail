# Open questions

Decisions made while working through the TODO without the owner; each one
is easy to revisit.

- Name: "spinrail" is a working name.
- Default branch: `master` or `main`?
- `presence` on a NOT NULL integer/float/boolean column is a compile error
  (it could never fail). Keep it strict?
- Timestamps are set in Ruby (`Time.now`, local time, `%Y-%m-%d %H:%M:%S`),
  not by SQLite. UTC instead?
- `belongs_to` reader returns nil when the parent is gone (`find_by`), like
  Rails; `find` would raise instead.
- Framework tests live in `test/dummy`, a Rails-style dummy app, and run
  through the same `bin/spinrail test` apps use.
- Session values are Strings (`session[:visits] = 1` reads back "1");
  Rails' cookie store keeps JSON types.
- CSRF is on by default outside tests, so plain `curl -d` POSTs get 422;
  APIs need `skip_forgery_protection`.
- Both db/schema.rb (auto-added columns) and db/migrate work; with
  migrations present they win. Keep both modes?
- SQL bind values are logged at debug level without filtering (the
  binds don't carry column names yet). Fine for development?
- tep fixes live in a fork, ceritium/tep: the `fixes` branch on top of
  upstream main, tagged `fixes-N` (toolchain.mk's TEP_REF). Nothing
  proposed upstream yet.
- Fixes so far: fix/sqlite-per-handle-cursor (threads, text over
  64 KB) and fix/threaded-runtime (a tep app using Thread got 400 on every
  request: non-blocking accepted sockets, and sp_ffi_bin_len is
  thread-local in Spinel's threaded runtime) and fix/scheduled-burst (the
  scheduled server left connections unanswered in bursts: each connection
  fiber closed over the accept loop's shared `client`),
  fix/prefork-idle-keepalive (tep#277), fix/stale-prebuilt-objects (bin/tep
  linked a helper .o older than its .c), fix/reason-phrases
  (tep#278, cherry-picked), fix/sqlite-null (bind_null, col_null?),
  fix/sqlite-rowid-64 (last_rowid past 2^31) and fix/pg-long-values (PG
  values cut at 64 KB, binds capped at 256 KB in total), and keeping
  `require "securerandom"` (and other packages bundled with spinel), which
  tep used to drop. Candidates for
  upstream PRs.
- Keep `scheduled` as the default server. Prefork was better on bursts at
  first, but scheduled no longer drops them; prefork still waits its 5 s
  keep-alive timeout behind an idle client and returns 501 for WebSocket
  upgrades, which Action Cable/Turbo Streams need. Prefork stays opt-in with
  `SPINRAIL_SERVER=prefork`.
- The gemspec says MIT and lists you as author; the repo has no LICENSE
  yet. Confirm before publishing anything.
- Jobs take several arguments, but as Strings (perform(id) gets "3"). Typing
  them needs the lowering to convert by perform's signature. Worth it?
- Spinel segfaulted (exit 139, in unrelated requests) when a subclass of
  Spinrail::Controller redefined initialize with a different arity; mailers
  now share a ViewContext base instead. Worth a minimal repro for matz/spinel?
- tep bakes `set :public_dir, './public'` as an absolute path from the
  build directory, so a binary built elsewhere looks in the wrong place
  (hit by the spinelgems mirror; worked around by building in its final
  path). Fix in the fork by keeping relative paths relative to the cwd at
  run time, or leave upstream's behaviour?
- `require "json"` and `JSON.generate`/`JSON.parse` (spinel's json package)
  need two spinel fixes, on the `fixes/to-json-dispatch-reopened-builtin`
  branch of ceritium/spinel (vendor/spinel is on it; pushed there):
  (1) the json reflect bridge composed `sp_Time_to_json` for a reopened
  builtin, but the method is emitted as `sp_Time_oc_to_json`, so the
  program didn't compile; (2) once `JSON.generate` was reachable, the same
  bridge emitted arms for primitives (Integer, Float, true/false, nil,
  Array) that cast `v.v.p` to structs that don't exist (`sp_Integer`).
  A fresh `vendor/` from `make setup` builds the pinned matz/spinel without
  them; decide between an upstream PR and pinning the fork in toolchain.mk.
- tep's `fixes-4` tag (https://github.com/ceritium/tep) raises outbound
  HTTP responses from the 64 KiB static buffer to 4 MiB (heap, thread-local
  under SP_THREADS), and `COOP_RESPONSE_MAX` follows. `TEP_REF` now
  defaults to it; gitlab-style providers fetching whole files need it.
