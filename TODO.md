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
- [x] Building through associations: `post.comments.create(...)`, `.new`, `.build`.
- [x] `scope :name, ->(args) { ... }` (chainable), `update_all`.
- [x] Eager loading: `includes`/`preload` run one query per association.
- [x] `joins(:assoc)` with `where(table: { column: value })`, `group(:col).count`.
- [ ] `left_joins`, `distinct`, `having`, nested includes (`includes(comments: :author)`).
- [x] `if:`/`unless:`/`on:` on validations and callbacks.
- [x] Halting before_* callbacks with `throw :abort`.
- [x] Nullable columns with `null: true` (nil in Ruby, `where(x: nil)` is `IS NULL`).
- [ ] Text values over 64 KB: tep's C bridge copies each into a fixed buffer.
      Reading one now raises instead of returning it cut; fix upstream.
- [x] Columns added to `db/schema.rb` are added to existing tables at boot.
- [x] Migrations in `db/migrate` (`create_table`, `add/remove/rename_column`,
      `add_reference`, `rename/drop_table`, `add/remove_index`, `execute`), applied
      at boot through `schema_migrations`; `rieles db:migrate` dumps db/schema.rb;
      `generate migration`. Indexes in db/schema.rb too.
- [x] Reversible `change` (or `up`/`down`), `rieles db:rollback`.
- [ ] `change_column` (SQLite needs a table rebuild).
- [x] `db/seeds.rb` (`rieles db:seed`, `rieles db:reset`).
- [ ] PostgreSQL (tep ships an opt-in `PG` battery).

## Controllers

- [x] `before_action` / `after_action` / `skip_*` with `only:`/`except:`;
      what before filters assign counts for the template check.
- [x] Strong params (`require`/`permit`/`expect`) over nested form names
      (`entry[name]`); `Model.new(params)`, `create`, `update`, typed per column.
- [x] Sessions on tep's signed cookie (`SECRET_KEY_BASE`, a dev secret in
      `tmp/local_secret.txt`).
- [x] `cookies[:x]`, `cookies[:x] = v`, `cookies.delete(:x)`.
- [x] `cookies.signed` (HMAC with the session secret) / `cookies.permanent`.
- [ ] `cookies.encrypted`.
- [x] `flash`, `flash.now`, `redirect_to ..., notice:/alert:`, `notice`/`alert` in views.
- [x] CSRF protection (form param or `X-CSRF-Token`), `skip_forgery_protection`,
      `csrf_meta_tags`; off in tests unless `forgery_protection!`.
- [x] `render json:` (literals encoded at build time, models and relations
      have `to_json`), `head :no_content`.
- [x] `respond_to` with `format.html` / `format.json` (Accept or `?format=`).
- [x] PATCH/PUT/DELETE from HTML forms (`_method` override).
- [x] Only public methods are actions.
- [x] `rescue_from`; `RecordInvalid` answers 422.

## Views

- [x] Helpers: `link_to`, `button_to`, `form_with` and field helpers.
- [x] `truncate`, `simple_format`, `number_with_delimiter`, `dom_id`.
- [x] `link_to` with a block, `collection_select`, `field_with_errors`,
      `number_to_currency`, `time_ago_in_words`.
- [x] Helpers returning `.html_safe` are emitted raw (decided at build time).
- [x] `content_for` (value or block), `content_for?`, `yield :title`.
- [x] Collection partials (`render @entries`, `render partial:, collection:, as:`).
- [x] Strict partial locals with defaults (`<%# locals: (post:, compact: false) %>`).
- [x] `app/helpers` modules, available in every view.
- [x] Layout per controller (`layout "x"`, `layout false`, layouts/<controller>).
- [x] `layout:` option on `render`.
- [x] Partials drop their trailing newline.

## Actions and views

- [x] Hanami-style endpoints alongside controllers (`to: Actions::Stats::Show`).
- [x] View classes with methods and computed exposures (`expose :x do |a| ... end`).
- [x] `response.status=`, `halt`.
- [x] `request.params` with `require`/`permit` in actions.
- [x] Hanami-style params validation (`required`/`optional`, `filled`/`maybe`,
      `:string`/`:integer`/`:float`/`:bool`, one level of `.hash do`).

## Routing

- [x] Nested resources, `member`/`collection`, `namespace` (controllers in
      `app/controllers/admin/`), singular `resource`.
- [x] `shallow`, `scope` (path, `module:`, `as:`), `concern`/`concerns:`,
      `form_with model: [@post, @comment]`.
- [x] `.json` suffix on any path sets `format=json`.
- [ ] Route `constraints`, globbing.
- [x] Path helpers that accept ids as well as records (`to_param`); `_url` helpers.

## Tooling

- [x] `rieles new` (app skeleton) and `rieles generate model|controller|scaffold`.
- [x] `rieles server` rebuilds when sources changed.
- [x] `rieles server` rebuilds on change and swaps the binary once it compiles.
- [x] Point spinel/C errors at the app file and line (controllers, actions, helpers;
      generated code names its source file).
- [x] Build errors in templates point at the .erb file and line.
- [ ] Line mapping for generated model code (today it names the model file).
- [x] Unit tests for the compiler (`rake unit`; `rake` also runs both apps).
- [x] Framework request tests in `test/dummy` (`bin/rieles test` there).
- [x] Tests: fixtures, `assert_select`, cookies/session across requests.
- [x] Model tests (`test/models`): compiled into a test build of the binary, one
      rolled-back transaction per test, Minitest assertions lowered at build time.
- [ ] CI.
- [x] Package as a gem (`gem build rieles.gemspec`); the toolchain goes to
      `RIELES_VENDOR` or `~/.cache/rieles/vendor` outside a checkout.
- [ ] Publish the gem (name, license and ownership to decide).

## Runtime

- [x] Environments (`RIELES_ENV`): error details only in development, logfmt
      and info level in production, `SECRET_KEY_BASE` required there.
- [x] Log levels (`RIELES_LOG_LEVEL`): SQL and rendered templates only at debug.
- [x] Log: request id, also sent as `X-Request-Id` (an incoming one is kept).
- [ ] Log: client IP (tep has no peer address yet).
- [ ] Log: backtraces for 500s. Blocked: spinel exceptions carry an empty backtrace.
- [x] Log: configurable filtered params (`RIELES_FILTER_PARAMETERS`).
- [x] Log: SQL bind values at debug level.
- [x] Log: a failure inside the logger must not take the server down.
- [x] Log: write to a file (`RIELES_LOG_FILE`).
- [x] Quieter `rieles build`: one summary line, only warnings and errors.
- [x] Static files from `public/`, served from disk.
- [x] i18n: `config/locales/*.yml`, `t`/`I18n.t` with lazy `.keys` and interpolation,
      `I18n.locale =` per request, translated validation messages and attribute names.
- [x] i18n: pluralization (`count:` with zero/one/other), `l` with `time.formats`.
- [ ] i18n: number formats, Accept-Language.
- [x] Workers (`-w N`): the boot connection is closed before forking; SQLite
      runs in WAL with a busy timeout. `RIELES_SERVER=prefork` builds tep's
      default server.
- [ ] tep's scheduled server drops some connections under a burst (2/40 with one
      worker, 5-10/40 with four; prefork serves 40/40). Report upstream.

## Upstream

- [ ] Drop `set :scheduler, :scheduled` once
      [OriPekelman/tep#277](https://github.com/OriPekelman/tep/issues/277) is fixed.
- [ ] Drop the `Tep.reason` override in runtime/rieles.rb once
      [OriPekelman/tep#278](https://github.com/OriPekelman/tep/pull/278) is released.
- [x] Compare notes with [rubys/roundhouse](https://github.com/rubys/roundhouse)
      (summary in README). Ideas worth taking:
- [x] `rieles check`: the build's static checks without compiling.
- [ ] Differential tests: the same requests against a Rails app and the rieles build.
- [x] N+1 warnings: an association read inside a loop over records without
      `includes` (the block variable's name picks the model).
