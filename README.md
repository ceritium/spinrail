# spinrail

A Rails-inspired web framework for [spinel](https://github.com/matz/spinel),
built on [tep](https://github.com/OriPekelman/tep). Working name; prototype.

Apps keep the Rails layout and conventions. Spinel can't do the runtime
metaprogramming Rails relies on (`method_missing`, `define_method` with
computed names, autoloading), so `spinrail build` resolves the conventions at
build time and writes plain Ruby: one file that `tep build` and spinel
compile into a single native binary.

Internally each endpoint is action → view with explicit exposures → template.
A controller action is lowered to that: the @ivars its template reads become
the template's parameters, and the build fails if the action doesn't assign
them, instead of rendering nil.

```
app/models/entry.rb          → Entry + EntryRelation, typed from db/schema.rb
app/controllers/*.rb         → same classes; render/redirect_to/params lowered
app/views/**/*.html.erb      → ApplicationView methods; @ivars become parameters
config/routes.rb             → tep routes + path helpers
config/application.rb        → settings read at build time (config.time_zone)
db/schema.rb                 → CREATE TABLE IF NOT EXISTS at boot
app/assets/*, app/javascript → embedded in the binary (binary files served from disk)
config/importmap.rb          → importmap resolved at build time
```

Endpoints can also be written Hanami-style, mixed freely with controllers:

```
get "/stats", to: Actions::Stats::Show

app/actions/stats/show.rb             class Actions::Stats::Show < Spinrail::Action
                                        def handle(request, response)
                                          response.render(view, count: Entry.count, ...)
app/views/stats/show.rb               class Views::Stats::Show < Spinrail::View; expose :count, ...
app/templates/stats/show.html.erb     reads `count` as a local
```

A controller can render the same view with
`render view: Views::Stats::Show, count: ..., latest: ...`. Either way, the build
checks that `render` passes exactly the view's exposures.

## Try it

As a gem (the first build clones and compiles spinel and tep into
`~/.cache/spinrail/vendor`, or `SPINRAIL_VENDOR`):

```sh
gem build spinrail.gemspec && gem install spinrail-0.1.0.gem
spinrail new ~/code/blog
```

From this checkout, `bin/spinrail` works the same way and uses `vendor/`.

New app:

```sh
bin/spinrail new ~/code/blog
cd ~/code/blog
bin/spinrail generate scaffold Article title:string body:text published:boolean
bin/spinrail server
```

Fields are `name:type`, as in Rails, plus `:index` or `:uniq`. `name:string!`
writes `null: false`; references get it anyway, as in Rails.

New apps carry a `.rubocop.yml` whose `Spinel/*` cops flag what spinel won't
compile (`eval` of a String, `method_missing`, `send`/`define_method` with a
computed name, `ObjectSpace`, `binding`) without waiting for a build:
`bundle exec rubocop`. `test/` is left out, since tests run on CRuby.

The example:

```sh
cd examples/guestbook
bin/spinrail server   # http://localhost:3000; first run builds ../../vendor (~1 min)
bin/spinrail routes
bin/spinrail test     # test/**/*_test.rb against the compiled binary
bin/spinrail check    # static checks only, no compile (N+1 warnings too)
bin/spinrail runner -e 'puts Entry.count'   # a script against the app's models
bin/spinrail          # all commands: server, build, routes, test, clean, setup
```

The generated source lands in `tmp/spinrail/app.rb`, which is the place to look
when something doesn't compile.

## Tests

`bin/spinrail test [FILES] [minitest options]` builds the app if needed and runs
Minitest in CRuby. `Spinrail::IntegrationTest` starts the binary for every test
with an empty database and talks to it over HTTP; the server log goes to
`log/test.log`.

```ruby
class EntriesTest < Spinrail::IntegrationTest
  def test_create
    post "/entries", params: { name: "Ana", body: "hi" }
    assert_redirected_to "/entries/1"
    follow_redirect!
    assert_body_includes "Ana"
  end
end
```

Model tests in `test/models` (`class EntryTest < ActiveSupport::TestCase` or
`Spinrail::ModelTest`) are compiled into a separate test build of the binary,
since models only exist there. Each test runs in a transaction that is
rolled back; `assert`, `assert_equal`, `assert_nil`, `assert_includes`,
`assert_empty`, `assert_raises`, `assert_difference` and fixture accessors
are lowered at build time. `-n name` filters them.

Framework tests: `rake unit` (compiler, no spinel) and `rake` (also the
request tests of `test/dummy` and the guestbook).

Helpers: `get/post/put/patch/delete`, `response`, `follow_redirect!`,
`assert_response` (status, `:success`, `:redirect`, `:not_found`...),
`assert_redirected_to`, `assert_select "ul li.item", "Text", count: 2`,
`assert_body_includes`, `cookies`. `fixtures :all` (or table names) loads
`test/fixtures/<table>.yml` into each test's database; `entries(:hello)`
returns the row, with Rails-style stable ids and `author: ana` references.
`forgery_protection!` turns CSRF checks on; `server_env` passes variables
to the server.

## Supported so far

- Routes: `root`, `resources`/`resource` (with `only:`/`except:`, nesting,
  `member`, `collection`), `namespace`, `scope` (with `module:`, `as:`, `defaults:`), `get/post/... "path", to:`; `_path`
  and `_url` helpers.
- Models: columns from `create_table` (`string`, `text`, `integer`, `float`,
  `boolean`, `datetime`, `references`, `timestamps`, `default:`); `datetime`
  and `timestamps` read and take `Time`, stored in UTC and read in
  `config.time_zone` (`date` and `time` are still Strings). Columns
  are nullable unless `null: false`, as in Rails. A `null: false` column gets a
  zero default (`""`, `0`, `false`, the epoch) and its reader never returns nil, which
  spinel compiles to a single type; declare it wherever nil can't happen. `all`,
  `where` (an array value is `IN`), `where.not`, `order`, `limit`, `offset`, `first`, `last`, `count`,
  `exists?`, `pluck`, `find`, `find_by` (and `find_by!`), `create`, `save`, `update`,
  `destroy` and their `!` forms, `transaction`; validations (`presence`,
  `length`, `numericality`, `format`, `inclusion`, `exclusion`, `uniqueness`,
  `validate :method`); callbacks; `belongs_to`, `has_many`, `has_one`;
  `has_secure_password` with `authenticate_by`, `has_secure_token`,
  `generates_token_for` with `find_by_token_for`, `signed_id`/`find_signed`. Plain classes
  (no superclass) in app/models compile as written. `Current <
  ActiveSupport::CurrentAttributes` keeps one instance per fiber, reset for each
  request, with `Current.set { }` and reset callbacks; `belongs_to` takes
  `default: -> { Current.user }`; `delegate` (methods without arguments).
- Controllers: `params[:x]`, `params[:post][:title]`, `params.fetch(:ids, [])`
  for repeated `ids[]`, strong params, `request.raw_post`,
  `request.files["post[avatar]"]` for uploads, `render :action, status:`,
  `render plain:` (with `content_type:`), `render formats: :svg` (`<action>.svg.erb` as `image/svg+xml`), `render json:`, `send_file`, `send_data` (text only), `head`, `expires_in`, `render view: Views::Stats::Show,
  exposure: value`, `redirect_to path, status:, notice:`, implicit render;
  `before_action`/`after_action`/`skip_*`, `rescue_from`, `session`, `flash`,
  CSRF protection, `_method` override.
- Views: layout with `yield`, partials (`render "entry", entry: entry`),
  `<%= %>` escapes, `<%== %>` and `raw` don't, `form_with` and field
  helpers (`file_field` makes the form multipart), `link_to`, `button_to` (`params:` as hidden fields), `csrf_meta_tags`, `pluralize`.
- Active Storage: `has_one_attached` over Rails' tables, files on the local
  disk (`storage/`, Rails' key layout), `attach`, `attached?`, `purge`,
  `download`, `rails_blob_path` (served by a signed proxy route, scriptable types
  as downloads). Variants are accepted and ignored.
- Request log: Rails-style by default (filtered params, SQL, rendered
  templates, timings); one line per request with `SPINRAIL_LOG_FORMAT=logfmt`
  or `json`. Each response carries `X-Request-Id`.
- Database: `db/schema.rb` (new columns are added at boot), or migrations in
  `db/migrate` applied at boot (`spinrail generate migration AddXToPosts x:string`,
  `spinrail db:migrate` also rewrites db/schema.rb); `db/seeds.rb`.
- Static files in `public/`, assets in `app/assets/`, `app/javascript/` and
  `vendor/javascript/`, and importmaps.
- Mailers: `app/mailers` with `mail(to:, subject:)`, `.text.erb`/`.html.erb`
  templates, `deliver_now`/`deliver_later`; delivered to the log, or to files
  with `SPINRAIL_MAIL_DELIVERY=file` (request tests read them via `deliveries`), or
  to an HTTP API with `SPINRAIL_MAIL_DELIVERY=http`, `SPINRAIL_MAIL_URL` and
  `SPINRAIL_MAIL_TOKEN` (JSON `{from, to, subject, text, html}`, as Resend takes).
- Jobs: `app/jobs/*_job.rb`, on Solid Queue's model: `perform_later(a, b)` (or
  `set(queue:, priority:, wait:, wait_until:)` first) writes a job row and a
  ready or scheduled execution to `spinrail_queue_*` tables; `spinrail jobs`
  moves due scheduled jobs to ready, claims them by queue order (`-q
  "real_time,background*"`, `*` by default) then priority (lower first), and
  leaves failures as failed executions. `queue_as` and `queue_with_priority`
  set a job's defaults; `retry_on` (`wait:` seconds, `:polynomially_longer` or
  a lambda; `attempts:`) enqueues a new job with one more execution, and
  `discard_on` drops it. Arguments arrive as Strings. Inline in tests, where
  retries don't wait. Each worker registers in `spinrail_queue_processes` and
  heartbeats; TERM or Ctrl+C finishes the jobs at hand and hands claimed ones
  back, and a worker silent for 5 minutes is pruned, its claimed jobs failed.
  `spinrail jobs status|failed` inspect the queue; `pause QUEUE`/`resume QUEUE`,
  `retry ID|all` and `discard ID|all` (failed jobs) and `clear` (finished ones)
  act on it. Workers delete finished jobs after a day. `limits_concurrency to:,
  key: ->(arg) { ... }, duration:, group:, on_conflict: :block|:discard` keeps
  jobs with the same key from running at once, through semaphores; the rest
  wait as blocked executions.
- Recurring jobs: `config/recurring.yml` as Solid Queue reads it (tasks under
  an environment, or at the top for all), each with `class:` and `args:` or a
  `command:` of app code, and `schedule:` as cron or `every 5 minutes`,
  `every day at 5am`, `every monday at 9am`. Every worker schedules them; a
  unique run per task and time keeps them from running twice.
  `SPINRAIL_JOBS_SKIP_RECURRING=1` leaves a worker out.
  `spinrail jobs -c N` works N at once on spinel threads, each with its own
  connection.
- Gems: the default group of the app's Gemfile is compiled into the binary, as
  `Bundler.require` would load it; a gem marked `require: false` stays out even
  when another gem requires it (rqrcode's PNG export needs `chunky_png`, which
  spinel can't compile). The gem must compile with spinel.
- i18n: `config/locales/*.yml`, `t(".title")`, `t("greeting", name: x)`,
  `I18n.locale = params[:locale]`, translated validation messages.

## Configuration

| Variable | Default | |
|---|---|---|
| `SPINRAIL_ENV` | `development` | `production` hides error details and needs `SECRET_KEY_BASE` |
| `SECRET_KEY_BASE` | `tmp/local_secret.txt` | signs the session cookie |
| `DATABASE_PATH` | `db/development.sqlite3` | |
| `SPINRAIL_LOG_FORMAT` | `dev` (`logfmt` in production) | `dev`, `logfmt`, `json` |
| `SPINRAIL_LOG_LEVEL` | `debug` (`info` in production) | SQL and templates only at `debug` |
| `SPINRAIL_LOG_FILE` | stdout | |
| `SPINRAIL_DATABASE` (build) | `sqlite` | `postgres` (experimental): uses `DATABASE_URL` and libpq from `pg_config` |
| `SPINRAIL_SERVER` (build) | `scheduled` | `prefork` for production: tep's default server handles bursts better but ignores Ctrl+C on idle keep-alive connections ([OriPekelman/tep#277](https://github.com/OriPekelman/tep/issues/277)) |
| `SPINRAIL_FILTER_PARAMETERS` | `password,token,secret,...` | substrings, comma-separated |

`config/application.rb` holds what is fixed at build time:

```ruby
Spinrail.application.configure do
  config.time_zone = "Europe/Madrid" # IANA name; UTC by default
end
```

The binary runs in that zone (it sets `TZ` at boot), so `Time.now` and
`Time.current` both answer in it; `datetime` columns are stored in UTC.

## Prior art

[rubys/roundhouse](https://github.com/rubys/roundhouse) takes unmodified
Rails apps, infers types across the whole program and emits a project for
one of a dozen targets, Spinel-compiled Ruby among them, checked against
live Rails with a conformance oracle. Spinrail is narrower: a Rails-shaped
framework whose idioms are lowered to plain Ruby for tep and spinel, with
no claim of running existing Rails apps.

## Not yet

See [TODO.md](TODO.md).
