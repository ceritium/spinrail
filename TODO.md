# TODO

Roughly in priority order within each section.

## Models

- [x] Associations: `belongs_to` (required unless `optional: true`), `has_many`,
      `has_one`, `dependent: :destroy | :delete_all`.
- [x] One connection per process, statements fixed at build time cached.
- [x] `count` with `SELECT COUNT(*)`.
- [x] Query API: `find_by`, `first`, `last`, `exists?`, `pluck`, `offset`,
      `where.not`, string `order`, `delete_all`; relations are immutable.
- [x] `create`, `create!`, `update`, `update!`, `save!`, `reload`.
- [x] Validations: `numericality`, `format`, `inclusion`, `exclusion`,
      `uniqueness`, `length: { is: }`, custom `validate :method`, `message:`.
- [x] Callbacks: `before/after_validation|save|create|update|destroy`.
- [x] Column types: boolean (`published?`), float/decimal, `default:`.
- [ ] Building through associations: `post.comments.create(...)`, `post.comments.new`.
- [ ] `includes`/eager loading (N+1 today), `joins`, `group`, `update_all`, scopes.
- [ ] `if:`/`unless:`/`on:` on validations and callbacks; halting with `throw :abort`.
- [ ] Nullable columns. Today every column is `NOT NULL` with a default,
      because spinel can't hold nil where a String is expected.
- [ ] Migrations in `db/migrate` with a schema version, instead of
      `CREATE TABLE IF NOT EXISTS` at boot.
- [ ] `db/seeds.rb`.
- [ ] PostgreSQL (tep ships an opt-in `PG` battery).

## Controllers

- [x] `before_action` / `after_action` / `skip_*` with `only:`/`except:`;
      what before filters assign counts for the template check.
- [ ] Strong params, `params.require(:entry).permit(...)`, and nested form
      names (`entry[name]`).
- [x] Sessions on tep's signed cookie (`SECRET_KEY_BASE`, a dev secret in
      `tmp/local_secret.txt`).
- [ ] `cookies[:x]` / `cookies.signed`.
- [x] `flash`, `flash.now`, `redirect_to ..., notice:/alert:`, `notice`/`alert` in views.
- [x] CSRF protection (form param or `X-CSRF-Token`), `skip_forgery_protection`,
      `csrf_meta_tags`; off in tests unless `forgery_protection!`.
- [x] `render json:` (literals encoded at build time, models and relations
      have `to_json`), `head :no_content`.
- [ ] `respond_to` / formats.
- [x] PATCH/PUT/DELETE from HTML forms (`_method` override).
- [x] Only public methods are actions.
- [x] `rescue_from`; `RecordInvalid` answers 422.

## Views

- [ ] Helpers: `link_to`, `button_to`, `form_with` and field helpers.
- [ ] `html_safe` strings instead of deciding at build time which output is raw.
- [ ] `content_for` / `yield :title`.
- [ ] Collection partials (`render @entries`) and partial locals with defaults.
- [ ] `app/helpers` modules.
- [ ] Layout per controller and `layout` option on `render`.
- [ ] Trim the blank line left after `<%= render ... %>` in loops.

## Actions and views

- [x] Hanami-style endpoints alongside controllers (`to: Actions::Stats::Show`).
- [ ] View classes with methods and computed exposures (`expose :x do ... end`).
- [ ] `response.status=`, `request.params` beyond `[:key]`, `halt`.

## Routing

- [ ] Nested resources, `member`/`collection`, `namespace`, singular `resource`.
- [ ] Path helpers that accept ids as well as records; `_url` helpers.

## Tooling

- [ ] `rieles new` (app skeleton) and `rieles generate model|controller|scaffold`.
- [x] `rieles server` rebuilds when sources changed.
- [ ] `rieles server` watching files and restarting on change.
- [ ] Map compile errors in `tmp/rieles/app.rb` back to the source `.rb`/`.erb` line.
- [ ] Unit tests for the compiler (ERB, lowering, routes, models, static checks).
- [x] Framework request tests in `test/dummy` (`bin/rieles test` there).
- [ ] Tests: model tests without HTTP, fixtures, `assert_select` on HTML,
      cookies/session across requests.
- [ ] CI.
- [ ] Package as a gem or spin package; stop requiring `TEP` in the environment.

## Runtime

- [ ] Environments (development/production): hide error messages, pick the
      log format and level per environment.
- [ ] Log levels (`RIELES_LOG_LEVEL`): SQL and rendered templates only at debug.
- [ ] Log: request id, also sent as `X-Request-Id`.
- [ ] Log: client IP (tep has no peer address yet).
- [ ] Log: backtraces for 500s, if spinel can produce useful ones.
- [ ] Log: configurable filtered params; SQL bind values in dev.
- [ ] Log: a failure inside the logger must not take the server down.
- [ ] Log: write to a file or stderr, not only stdout.
- [ ] Quieter `rieles build`: one summary line, only warnings and errors.
- [ ] Static files from `public/` (binary files can't be embedded as assets).
- [ ] i18n for validation messages and views.
- [ ] Prefork workers on Linux.

## Upstream

- [ ] Drop `set :scheduler, :scheduled` once
      [OriPekelman/tep#277](https://github.com/OriPekelman/tep/issues/277) is fixed.
- [ ] Drop the `Tep.reason` override in runtime/rieles.rb once
      [OriPekelman/tep#278](https://github.com/OriPekelman/tep/pull/278) is released.
- [ ] Compare notes with [rubys/roundhouse](https://github.com/rubys/roundhouse),
      which lowers real Rails apps for spinel.
