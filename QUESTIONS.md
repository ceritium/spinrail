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
- Tep::SQLite cuts text values at 64 KB (fixed C buffer). Open an issue/PR
  upstream? Rieles raises on such reads meanwhile.
- tep's scheduled server (our default, for Ctrl+C) drops connections under
  a burst of 40; the prefork server doesn't. Report upstream? Default
  production builds to prefork?
- The gemspec says MIT and lists you as author; the repo has no LICENSE
  yet. Confirm before publishing anything.
- Jobs take a single argument, passed as a String (perform(id) gets "3").
  Enough, or encode several typed arguments?
