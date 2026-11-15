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
app/assets/*                 → embedded in the binary
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
  `member`, `collection`), `namespace`, `get/post/... "path", to:`; `_path`
  and `_url` helpers.
- Models: columns from `create_table` (`string`, `text`, `integer`, `float`,
  `boolean`, `datetime`, `references`, `timestamps`, `default:`); `datetime`
  and `timestamps` read and take `Time`, stored in UTC and read in
  `config.time_zone` (`date` and `time` are still Strings). Columns
  are nullable unless `null: false`, as in Rails. A `null: false` column gets a
  zero default (`""`, `0`, `false`, the epoch) and its reader never returns nil, which
  spinel compiles to a single type; declare it wherever nil can't happen. `all`,
  `where`, `where.not`, `order`, `limit`, `offset`, `first`, `last`, `count`,
  `exists?`, `pluck`, `find`, `find_by`, `create`, `save`, `update`,
  `destroy` and their `!` forms, `transaction`; validations (`presence`,
  `length`, `numericality`, `format`, `inclusion`, `exclusion`, `uniqueness`,
  `validate :method`); callbacks; `belongs_to`, `has_many`, `has_one`;
  `has_secure_password` with `authenticate_by`, `has_secure_token`. Plain classes
  (no superclass) in app/models compile as written. `Current <
  ActiveSupport::CurrentAttributes` keeps one instance per fiber, reset for each
  request, with `Current.set { }` and reset callbacks; `belongs_to` takes
  `default: -> { Current.user }`; `delegate` (methods without arguments).
- Controllers: `params[:x]`, `params[:post][:title]`, strong params,
  `request.files["post[avatar]"]` for uploads, `render :action, status:`,
  `render plain:`, `render json:`, `head`, `render view: Views::Stats::Show,
  exposure: value`, `redirect_to path, status:, notice:`, implicit render;
  `before_action`/`after_action`/`skip_*`, `rescue_from`, `session`, `flash`,
  CSRF protection, `_method` override.
- Views: layout with `yield`, partials (`render "entry", entry: entry`),
  `<%= %>` escapes, `<%== %>` and `raw` don't, `form_with` and field
  helpers (`file_field` makes the form multipart), `link_to`, `button_to`, `csrf_meta_tags`, `pluralize`.
- Request log: Rails-style by default (filtered params, SQL, rendered
  templates, timings); one line per request with `SPINRAIL_LOG_FORMAT=logfmt`
  or `json`. Each response carries `X-Request-Id`.
- Database: `db/schema.rb` (new columns are added at boot), or migrations in
  `db/migrate` applied at boot (`spinrail generate migration AddXToPosts x:string`,
  `spinrail db:migrate` also rewrites db/schema.rb); `db/seeds.rb`.
- Static files in `public/` and assets in `app/assets/`.
- Mailers: `app/mailers` with `mail(to:, subject:)`, `.text.erb`/`.html.erb`
  templates, `deliver_now`/`deliver_later`; delivered to the log, or to files
  with `SPINRAIL_MAIL_DELIVERY=file` (request tests read them via `deliveries`), or
  to an HTTP API with `SPINRAIL_MAIL_DELIVERY=http`, `SPINRAIL_MAIL_URL` and
  `SPINRAIL_MAIL_TOKEN` (JSON `{from, to, subject, text, html}`, as Resend takes).
- Jobs: `app/jobs/*_job.rb` with `perform(arg)`, `perform_later` into a SQLite
  queue drained by `spinrail jobs` (3 attempts with backoff); inline in tests.
  `spinrail jobs -c N` works N at once on spinel threads, each with its own
  connection.
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
