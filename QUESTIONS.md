# Open questions

Decisions made while working through the TODO without the owner; each one
is easy to revisit.

- Name: "rieles" is a working name.
- Default branch: `master` or `main`?
- Columns are NOT NULL with a default unless `null: true`, the opposite of
  Rails (nullable unless `null: false`). Nullable works now; flip the
  default? It would make `post.title.length` raise on unset titles, as in
  Rails.
- `presence` on a NOT NULL integer/float/boolean column is a compile error
  (it could never fail). Keep it strict?
- Timestamps are set in Ruby (`Time.now`, local time, `%Y-%m-%d %H:%M:%S`),
  not by SQLite. UTC instead?
- `belongs_to` reader returns nil when the parent is gone (`find_by`), like
  Rails; `find` would raise instead.
- Framework tests live in `test/dummy`, a Rails-style dummy app, and run
  through the same `bin/rieles test` apps use.
- Session values are Strings (`session[:visits] = 1` reads back "1");
  Rails' cookie store keeps JSON types.
- CSRF is on by default outside tests, so plain `curl -d` POSTs get 422;
  APIs need `skip_forgery_protection`.
- Both db/schema.rb (auto-added columns) and db/migrate work; with
  migrations present they win. Keep both modes?
- SQL bind values are logged at debug level without filtering (the
  binds don't carry column names yet). Fine for development?
- tep fixes live in a private fork, ceritium/tep: a branch per fix
  off v0.12.0, merged into `rieles` and tagged `rieles-N` (toolchain.mk's
  TEP_REF). Nothing proposed upstream yet. CI can't clone it until a
  TEP_TOKEN secret (read access to the fork) exists.
- Fork branches so far: fix/sqlite-per-handle-cursor (threads, text over
  64 KB) and fix/threaded-runtime (a tep app using Thread got 400 on every
  request: non-blocking accepted sockets, and sp_ffi_bin_len is
  thread-local in Spinel's threaded runtime) and fix/scheduled-burst (the
  scheduled server left connections unanswered in bursts: each connection
  fiber closed over the accept loop's shared `client`),
  fix/prefork-idle-keepalive (tep#277), fix/stale-prebuilt-objects (bin/tep
  linked a helper .o older than its .c) and fix/reason-phrases (your
  tep#278, cherry-picked). Candidates for upstream PRs.
- Default production builds to the prefork server? The scheduled one no
  longer drops connections in bursts (fixed in the fork).
- The gemspec says MIT and lists you as author; the repo has no LICENSE
  yet. Confirm before publishing anything.
- Jobs take a single argument, passed as a String (perform(id) gets "3").
  Enough, or encode several typed arguments?
- Spinel segfaulted (exit 139, in unrelated requests) when a subclass of
  Rieles::Controller redefined initialize with a different arity; mailers
  now share a ViewContext base instead. Worth a minimal repro for matz/spinel?
