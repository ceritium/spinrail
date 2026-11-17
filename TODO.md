# TODO

Roughly in priority order within each section.

## Models

- [x] Table, class and association names inflect with Rails' own
      `ActiveSupport::Inflector`, at build time.
- [x] App inflections (`config/initializers/inflections.rb`).
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
- [x] `scope :name, ->(args) { ... }` (chainable), `update_all`; `def self.x`
      (or in `class << self`) also runs on relations, scoped to them; `last(n)` in scope bodies.
- [x] Pagination: `page(n).per(k)`, `current_page`, `total_pages`, `<%= paginate @posts %>`.
- [x] Eager loading: `includes`/`preload` run one query per association.
- [x] `joins(:assoc)` with `where(table: { column: value })`, `group(:col).count`.
- [x] SQL fragments: `where("sql ?", values)`, `joins("sql")` (literal strings),
      `connection.execute(sanitize_sql([sql, *values]))`; `create_virtual_table` in
      db/schema.rb (SQLite FTS5); `find(id)` and `touch` on records and relations.
- [ ] `find_or_create_by`; `last(n)` in `def self.x` (scope bodies only for now);
      named binds (`where("x = :y", y:)`).
- [ ] `left_joins`, `distinct`, `having`, nested includes (`includes(comments: :author)`).
- [x] `where(id: [1, 2])` as `IN`.
- [ ] Subqueries: `where(id: Membership.where(...).select(:room_id))`.
- [x] `has_many :users, through: :memberships` (one hop, as a subquery; no
      `includes`/`joins` of it yet); `find_by` on relations; `order(:col)`.
- [x] Single-table inheritance: `class Rooms::Open < Room` in
      app/models/rooms/open.rb; rows load as their `type`'s class, subclasses
      scope their queries, add methods, callbacks and validations, and
      `becomes`/`becomes!` switch class. Associations, scopes and enums go on
      the base for now.
- [x] `datetime` columns read and take `Time` (TEXT in SQLite, local time to the
      microsecond); `where`, params, `to_json`, `l` and `cache_key` follow.
- [ ] `date` and `time` columns as `Date` and a time of day; they are Strings.
- [x] `config.time_zone` in `config/application.rb` (an IANA name, UTC by
      default): the process runs in it, so `Time.now` and `Time.current` agree
      (Rails keeps `Time.now` in the system zone); the database keeps UTC.
- [x] Rails' friendly zone names (`"Madrid"`, `"Eastern Time (US & Canada)"`).
- [x] `if:`/`unless:`/`on:` on validations and callbacks.
- [x] Halting before_* callbacks with `throw :abort`.
- [x] Nullable columns, the default as in Rails (nil in Ruby, `where(x: nil)` is
      `IS NULL`); `null: false` ones have a single type.
- [ ] `null: false` without a default should reject a missing value instead of
      storing `""`/`0`.
- [x] Text values of any length (fixed in the tep fork).
- [x] Columns added to `db/schema.rb` are added to existing tables at boot.
- [x] Migrations in `db/migrate` (`create_table`, `add/remove/rename_column`,
      `add_reference`, `rename/drop_table`, `add/remove_index`, `execute`), applied
      at boot through `schema_migrations`; `spinrail db:migrate` dumps db/schema.rb;
      `generate migration`. Indexes in db/schema.rb too.
- [x] Reversible `change` (or `up`/`down`), `spinrail db:rollback`.
- [ ] `change_column` (SQLite needs a table rebuild).
- [x] `db/seeds.rb` (`spinrail db:seed`, `spinrail db:reset`).
- [x] PostgreSQL, experimental: `SPINRAIL_DATABASE=postgres` at build time and
      `DATABASE_URL` at run time; an adapter gives tep's PG battery the SQLite
      cursor interface and translates the SQLite-isms. The dummy's 73 request
      tests pass against it (`SPINRAIL_DATABASE=postgres bin/spinrail test`).
- [ ] PostgreSQL: three model tests fail when run after the others (an INSERT
      raises PG::ServerError with no message and nothing in the server log);
      they pass alone. The model test binary shares one connection.

- [x] `enum :status, { draft: 0, published: 1 }`: names in Ruby, integers in the
      database; `draft?`, `draft!`, `Post.draft`, `Post.statuses`. On a string
      column each name stores itself; `prefix:`/`suffix:`.
- [x] `confirmation` and `acceptance` validations (virtual attributes).
- [x] `has_secure_password` (PBKDF2 via `Tep::Password`); `authenticate` returns
      true/false instead of the record. `authenticate_by` on the model and relations.
- [x] `has_secure_token` (alphanumeric, not base58), `regenerate_<attr>`.
- [x] Plain classes (no superclass) in app/models.
- [x] `Current < ActiveSupport::CurrentAttributes`: `attribute`, overridable
      writers with `super`, one instance per fiber, reset around each request
      and before each job and model test; `before_reset`/`after_reset`/`resets`;
      `Current.set(user: u) { }` (a nil value leaves the attribute as it is).
- [x] `delegate :a, :b=, to: :x, prefix:, allow_nil:` (methods without
      arguments, and writers).
- [x] `belongs_to ..., default: -> { ... }`.

## Controllers

- [x] `before_action` / `after_action` / `skip_*` with `only:`/`except:`;
      what before filters assign counts for the template check.
- [x] Strong params (`require`/`permit`/`expect`) over nested form names
      (`entry[name]`); `Model.new(params)`, `create`, `update`, typed per column.
- [x] Sessions on tep's signed cookie (`SECRET_KEY_BASE`, a dev secret in
      `tmp/local_secret.txt`).
- [x] `cookies[:x]`, `cookies[:x] = v`, `cookies.delete(:x)`.
- [x] `cookies.signed` (HMAC with the session secret) / `cookies.permanent`, in
      either order; `{ value:, httponly:, same_site: }` values.
- [ ] `cookies.encrypted`.
- [x] Repeated `ids[]` params (form body or query), read with `params.fetch(:ids, [])`.
- [x] `request.raw_post`.
- [x] `flash`, `flash.now`, `redirect_to ..., notice:/alert:`, `notice`/`alert` in views.
- [x] CSRF protection (form param or `X-CSRF-Token`), `skip_forgery_protection`,
      `csrf_meta_tags`; off in tests unless `forgery_protection!`.
- [x] `render json:` (literals encoded at build time, models and relations
      have `to_json`), `head :no_content`.
- [x] `respond_to` with `format.html` / `format.json` (Accept or `?format=`).
- [x] Turbo Streams: `format.turbo_stream` (with a block, or rendering
      `<action>.turbo_stream.erb`), `render turbo_stream:` (one or a list),
      `turbo_stream.append/prepend/replace/update/remove/before/after` with a
      partial or HTML.
- [x] Live Turbo Streams over ActionCable's protocol (turbo-rails' client):
      `turbo_stream_from` in views, `broadcast_<action>_to` in models, a
      `/cable` route when the app uses either. Stream names are signed per
      channel. No `broadcasts_to` / `_later` variants yet.
- [x] Channels (app/channels): `ApplicationCable::Connection` with
      `identified_by`, `connect`, `cookies.signed`,
      `reject_unauthorized_connection`; channels with `subscribed`,
      `stream_from`, `reject`, `verified_stream_name_from_params`, picked by
      `turbo_stream_from ..., channel:`. No `perform`/`transmit` or
      client-sent actions yet.
- [x] Action Text: `has_rich_text` over `action_text_rich_texts`, rendered
      through a safe-list sanitizer (`<%= post.content %>`), `to_plain_text`,
      `form.rich_text_area` as Lexxy's `<lexxy-editor>`. No attachments,
      embeds or eager loading (`with_rich_text_*` loads one row per record).
- [x] File uploads (tep fork): `f.file_field` makes `form_with` multipart,
      `request.files["post[avatar]"]` (`original_filename`, `content_type`,
      `read`, `size`), `fixture_file_upload` in tests. Held in memory.
- [x] Active Storage: `has_one_attached`, disk service, signed proxy route.
- [ ] Active Storage: `has_many_attached`, variants (image processing),
      `image_tag record.avatar`, direct uploads, S3.
- [ ] `send_data` with binary data: tep writes inline bodies as C strings,
      so a NUL truncates them (`send_file` is binary-safe).
- [x] `render formats: :svg` (`<action>.svg.erb`); other formats still to do.
- [x] Nested params reads: `params[:post][:title]`.
- [x] JSON request bodies become params (`{"post": {"title": ...}}` -> `post[title]`).
- [x] PATCH/PUT/DELETE from HTML forms (`_method` override).
- [x] Only public methods are actions.
- [x] Controller concerns (app/controllers/concerns): `included do`, methods,
      pasted where included. No `class_methods` or nested `include` yet.
- [x] `rescue_from`; `RecordInvalid` answers 422.
- [x] `http_basic_authenticate_with name:, password:, only:/except:`.

## Views

- [x] Helpers: `link_to`, `button_to` (both with a block too), `form_with` and field helpers.
- [x] Path helpers take extra keywords as the query string: `searches_path(q: x)`.
- [x] `truncate`, `simple_format`, `number_with_delimiter`, `dom_id` (with a prefix).
- [x] `stylesheet_link_tag`, `javascript_include_tag`, `image_tag`.
- [x] Asset fingerprinting: app/assets files are also served as name-<digest>.ext,
      which the tag helpers use.
- [x] Digested assets are served with a year-long, immutable Cache-Control.
- [x] Propshaft load paths: app/assets, each app/assets/* dir, app/javascript,
      vendor/javascript; `stylesheet_link_tag :all`.
- [x] `config/importmap.rb` (`pin`, `pin_all_from`) and `javascript_importmap_tags`,
      resolved at build time.
- [x] Binary assets (with NUL bytes, which tep can't embed) are served from
      tmp/spinrail/public, next to the copied `public/`; the binary needs that dir.
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
- [x] `button_to url, params: { ids: [1] }` renders hidden fields.
- [ ] A form builder passed to a partial (`render "form", form: form`).
- [ ] `form_with model: @bot` names fields after the variable (`bot[name]`), not
      the model class (`user[name]`); pass `scope:` for now.
- [ ] JSON templates (`index.json.erb`, jbuilder).

## Actions and views

- [x] Hanami-style endpoints alongside controllers (`to: Actions::Stats::Show`).
- [x] View classes with methods and computed exposures (`expose :x do |a| ... end`).
- [x] `response.status=`, `halt`.
- [x] `request.params` with `require`/`permit` in actions.
- [x] Hanami-style params validation (`required`/`optional`, `filled`/`maybe`,
      `:string`/`:integer`/`:float`/`:bool`, one level of `.hash do`).

## Routing

- [x] Nested resources, `member`/`collection` (also `on:`), `namespace` (controllers in
      `app/controllers/admin/`), singular `resource`.
- [x] `shallow`, `scope` (path, `module:`, `as:`), `concern`/`concerns:`,
      `form_with model: [@post, @comment]`.
- [x] `.json` suffix on any path sets `format=json`.
- [x] `scope path: ":bot_key"` adds the segment to the nested helpers' arguments.
- [x] Route globbing (`*path`) and `constraints: { id: /\d+/ }`.
- [x] `get "up" => "rails/health#show"` (the `path => endpoint` form and Rails' health check).
- [x] Path helpers that accept ids as well as records (`to_param`); `_url` helpers.

## Tooling

- [x] `spinrail new` (app skeleton) and `spinrail generate model|controller|scaffold`.
- [x] `spinrail server` rebuilds when sources changed.
- [x] `spinrail server` rebuilds on change and swaps the binary once it compiles.
- [x] Point spinel/C errors at the app file and line (controllers, actions, helpers;
      generated code names its source file).
- [x] Build errors in templates point at the .erb file and line.
- [ ] Line mapping for generated model code (today it names the model file).
- [x] Unit tests for the compiler (`rake unit`; `rake` also runs both apps).
- [x] Framework request tests in `test/dummy` (`bin/spinrail test` there).
- [x] Tests: fixtures, `assert_select` (with a count, range or false as in Rails),
      cookies/session across requests.
- [x] Model tests (`test/models`): compiled into a test build of the binary, one
      rolled-back transaction per test, Minitest assertions lowered at build time.
- [x] CI (self-hosted runner).
- [x] Package as a gem (`gem build spinrail.gemspec`); the toolchain goes to
      `SPINRAIL_VENDOR` or `~/.cache/spinrail/vendor` outside a checkout.
- [x] Gems from the app's Gemfile, resolved by Bundler and spliced into the
      generated source (tep has no `-I`).
- [ ] Publish the gem (name, license and ownership to decide).
- [ ] A console, once spinel can compile a line against a program that is already
      running: see `docs/internals/interactive-design.md` on the `interactive-spinel` branch of
      ceritium/spinel.
- [ ] Compiled dependencies through spin (spinel's package manager): tep and
      spinel_kit as git deps in a `spin.toml` with `spin.lock`, `spin flags` for the
      `-I`/`--link` list instead of cloning them into `vendor/`; spinel itself stays
      pinned in `toolchain.mk`. Then `spinrail new` writes an app `spin.toml` for its
      runtime deps (and `allocator = "jemalloc"`). The Gemfile stays for the CRuby CLI.
      Check first whether `tep build` takes spin's flags.

## Mailers

- [x] `app/mailers` with `mail(to:, subject:, from:)`, `default from:`, `.text.erb`
      (unescaped) and `.html.erb` templates, `deliver_now`/`deliver_later`, log or
      file delivery, `deliveries` in request tests, `generate mailer`.
- [x] HTTP API delivery (`SPINRAIL_MAIL_DELIVERY=http`, JSON in the shape Resend takes).
- [ ] SMTP, attachments, mailer layouts, previews.

## Caching

- [x] `Rails.cache.fetch/read/write/delete/clear` with `expires_in` (in memory, per
      process), fragment caching `<% cache @post do %>`, `cache_key`, `5.minutes`.
- [x] A shared store (`SPINRAIL_CACHE_STORE=sqlite`) so workers see the same cache.
- [x] Timestamps with microseconds, so two writes in one second get new cache keys.

## Jobs

- [x] `app/jobs` with `perform_later`/`perform_now`, `spinrail jobs`; inline in tests.
- [x] `spinrail jobs -c N`: N threads in a binary of its own (the server keeps
      the single-threaded runtime), a connection each.
- [x] Solid Queue's tables (`spinrail_queue_jobs` plus ready, scheduled, claimed
      and failed executions), named queues polled in order with prefixes,
      priorities, `set(wait:, wait_until:, queue:, priority:)`, `queue_as`,
      `queue_with_priority`, several arguments (Strings, optional ones too).
- [x] `retry_on`/`discard_on`, ApplicationJob's too, the last declared first.
- [ ] `retry_on`/`discard_on` with a block, `jitter:` (ignored), `queue:`/`priority:`, `after_discard`.
- [x] Processes with heartbeats (`SPINRAIL_JOBS_HEARTBEAT_INTERVAL`, 60s),
      pruned after `SPINRAIL_JOBS_ALIVE_THRESHOLD` (300s) with their claimed
      jobs failed; TERM/INT stops after the jobs at hand; `spinrail jobs status`.
- [ ] A single-threaded worker heartbeats between jobs: one running longer
      than the alive threshold gets it pruned. `-c N` heartbeats from the main
      thread.
- [x] Hostname of a process (spinel has no Socket; `HOSTNAME` if set, else
      `/proc/sys/kernel/hostname` or `/etc/hostname`).
- [x] Queue pauses, retrying and discarding failed jobs, clearing finished
      ones (by hand, and after `SPINRAIL_JOBS_CLEAR_FINISHED_AFTER`, a day).
- [x] Recurring tasks (`config/recurring.yml`): cron and Fugit's common
      phrasings, `class:`/`args:` or `command:`, once per slot across workers.
- [x] Fugit's other phrasings (`every 2 days`, `every 2 weeks`,
      `every weekday`, `every weekend`), cron with seconds (a sixth field
      first, as Fugit reads it), ERB in recurring.yml. A hash argument
      still isn't one (perform takes positional Strings).
- [x] `limits_concurrency` (semaphores and blocked executions; `on_conflict:
      :discard`); semaphores expire after `duration:` (3 minutes).
- [x] Retried jobs take a semaphore slot again; pruned workers' jobs give
      theirs back. A stopped worker's jobs keep theirs, as in Solid Queue.
- [ ] A dashboard (Mission Control).
- [ ] Threaded jobs on PostgreSQL (the PG battery's state hasn't been checked
      for threads).
- [ ] Typed arguments (Strings today); `perform_all_later`.
- [x] The old `spinrail_jobs` table goes at boot: its still queued and
      running rows move to the new queue, the rest go with the table.

## Runtime

- [x] Environments (`SPINRAIL_ENV`): error details only in development, logfmt
      and info level in production, `SECRET_KEY_BASE` required there.
- [x] Log levels (`SPINRAIL_LOG_LEVEL`): SQL and rendered templates only at debug.
- [x] Log: request id, also sent as `X-Request-Id` (an incoming one is kept).
- [x] Log: client IP; `request.ip` / `request.remote_ip` (tep fork).
- [ ] Log: backtraces for 500s. Blocked: spinel exceptions carry an empty backtrace.
- [x] Log: configurable filtered params (`SPINRAIL_FILTER_PARAMETERS`).
- [x] Log: SQL bind values at debug level.
- [x] Log: a failure inside the logger must not take the server down.
- [x] Log: write to a file (`SPINRAIL_LOG_FILE`).
- [x] Quieter `spinrail build`: one summary line, only warnings and errors.
- [x] Static files from `public/`, served from disk.
- [x] i18n: `config/locales/*.yml`, `t`/`I18n.t` with lazy `.keys` and interpolation,
      `I18n.locale =` per request, translated validation messages and attribute names.
- [x] i18n: pluralization (`count:` with zero/one/other), `l` with `time.formats`.
- [ ] i18n: number formats, Accept-Language.
- [x] Workers (`-w N`): the boot connection is closed before forking; SQLite
      runs in WAL with a busy timeout. `SPINRAIL_SERVER=prefork` builds tep's
      default server.
- [x] tep's scheduled server dropped connections in bursts (fixed in the fork).

## Upstream

- [x] Default to the prefork server? No: keep `scheduled` (issue #33).
      [OriPekelman/tep#277](https://github.com/OriPekelman/tep/issues/277)
      (idle keep-alive clients blocked Ctrl+C) is fixed and scheduled no longer
      drops bursts, but prefork still waits out its 5 s keep-alive timeout behind
      an idle client and returns 501 for WebSocket upgrades, which Action
      Cable/Turbo Streams need. Prefork stays opt-in with
      `SPINRAIL_SERVER=prefork`; the build warns when an app with live streams
      asks for it.
- [x] Reason phrases: the fork carries
      [OriPekelman/tep#278](https://github.com/OriPekelman/tep/pull/278).
- [x] Compare notes with [rubys/roundhouse](https://github.com/rubys/roundhouse)
      (summary in README). Ideas worth taking:
- [x] `spinrail check`: the build's static checks without compiling.
- [x] `spinrail runner FILE` / `runner -e CODE`: compiled into a one-off binary.
- [x] `spinrail generate authentication` (Rails 8 style) and `<%= password_digest("x") %>`
      in ERB fixtures.
- [ ] Differential tests: the same requests against a Rails app and the spinrail build.
- [x] N+1 warnings: an association read inside a loop over records without
      `includes` (the block variable's name picks the model).
