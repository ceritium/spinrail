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
- A tep server binary that uses Thread anywhere breaks: the first request
  gets 400 and later ones a reset, before any thread starts. Spinel's
  threaded runtime vs tep's request parsing; not investigated further.
  `rieles jobs -c N` builds its own binary, so the server is unaffected.
- tep's scheduled server (our default, for Ctrl+C) drops connections under
  a burst of 40; the prefork server doesn't. It also makes CI flaky now and
  then (a request test times out). Draining accept() in a loop was not the
  fix (it stopped serving at all). Report upstream? Default production
  builds to prefork?
- The gemspec says MIT and lists you as author; the repo has no LICENSE
  yet. Confirm before publishing anything.
- Jobs take a single argument, passed as a String (perform(id) gets "3").
  Enough, or encode several typed arguments?
- Spinel segfaulted (exit 139, in unrelated requests) when a subclass of
  Rieles::Controller redefined initialize with a different arity; mailers
  now share a ViewContext base instead. Worth a minimal repro for matz/spinel?
