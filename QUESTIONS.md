# Open questions

Decisions made while working through the TODO without the owner; each one
is easy to revisit.

- Name: "rieles" is a working name.
- Default branch: `master` or `main`?
- `presence` on non-string columns is a compile error instead of Rails'
  always-valid behaviour for integers/floats. Keep it strict?
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
- Schema changes are applied at boot (only added columns). Real migrations
  or keep db/schema.rb as the only source of truth?
