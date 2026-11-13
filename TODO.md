# TODO

Roughly in priority order within each section.

## Models

- [ ] Associations: `belongs_to`, `has_many`, `has_one`.
- [ ] Own SQLite adapter: `Tep::SQLite` allows one open cursor per process, so a
      query inside another query's loop (associations in a view) breaks it.
      Reuse the connection and cache prepared statements.
- [ ] `count` with `SELECT COUNT(*)` instead of loading every row.
- [ ] Query API: `find_by`, `first`, `last`, `exists?`, `pluck`, `offset`,
      `where.not`, string `order`.
- [ ] `create`, `update(attrs)`, `update!`/`save!` raising on invalid records.
- [ ] Validations: `numericality`, `format`, `inclusion`, `uniqueness`,
      custom `validate :method`, validations on integer columns.
- [ ] Callbacks: `before_save`, `after_create`, ...
- [ ] Column types: boolean, float/decimal.
- [ ] Nullable columns. Today every column is `NOT NULL` with a default,
      because spinel can't hold nil where a String is expected.
- [ ] Migrations in `db/migrate` with a schema version, instead of
      `CREATE TABLE IF NOT EXISTS` at boot.
- [ ] `db/seeds.rb`.
- [ ] Transactions.
- [ ] PostgreSQL (tep ships an opt-in `PG` battery).

## Controllers

- [ ] `before_action` / `after_action` / `skip_before_action`.
- [ ] Strong params, `params.require(:entry).permit(...)`, and nested form
      names (`entry[name]`).
- [ ] Sessions and cookies (tep has signed cookie sessions).
- [ ] `flash` / `notice:` / `alert:`.
- [ ] CSRF protection (authenticity token).
- [ ] `render json:`, `head :no_content`, `respond_to`.
- [ ] PATCH/PUT/DELETE from HTML forms (`_method` override).
- [ ] Only public methods are actions (ignore methods after `private`).
- [ ] `rescue_from`.

## Views

- [ ] Helpers: `link_to`, `button_to`, `form_with` and field helpers.
- [ ] `html_safe` strings instead of deciding at build time which output is raw.
- [ ] `content_for` / `yield :title`.
- [ ] Collection partials (`render @entries`) and partial locals with defaults.
- [ ] `app/helpers` modules.
- [ ] Layout per controller and `layout` option on `render`.
- [ ] Trim the blank line left after `<%= render ... %>` in loops.

## Routing

- [ ] Nested resources, `member`/`collection`, `namespace`, singular `resource`.
- [ ] Path helpers that accept ids as well as records; `_url` helpers.

## Tooling

- [ ] `rieles new` (app skeleton) and `rieles generate model|controller|scaffold`.
- [ ] `rieles server`: rebuild and restart on file changes.
- [ ] Map compile errors in `tmp/rieles/app.rb` back to the source `.rb`/`.erb` line.
- [ ] Tests for the compiler, and request tests for apps.
- [ ] CI.
- [ ] Package as a gem or spin package; stop requiring `TEP` in the environment.

## Runtime

- [ ] Environments (development/production): hide error messages and log
      levels in production.
- [ ] Static files from `public/` (binary files can't be embedded as assets).
- [ ] i18n for validation messages and views.
- [ ] Prefork workers on Linux.

## Upstream

- [ ] Drop `set :scheduler, :scheduled` once
      [OriPekelman/tep#277](https://github.com/OriPekelman/tep/issues/277) is fixed.
- [ ] tep answers every status with the reason phrase `OK` (`303 OK`, `422 OK`);
      worth an issue.
- [ ] Compare notes with [rubys/roundhouse](https://github.com/rubys/roundhouse),
      which lowers real Rails apps for spinel.
