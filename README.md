# rieles

A Rails-inspired web framework for [spinel](https://github.com/matz/spinel),
built on [tep](https://github.com/OriPekelman/tep). Working name; prototype.

Apps keep the Rails layout and conventions. Spinel can't do the runtime
metaprogramming Rails relies on (`method_missing`, `define_method` with
computed names, autoloading), so `rieles build` resolves the conventions at
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
db/schema.rb                 → CREATE TABLE IF NOT EXISTS at boot
app/assets/*                 → embedded in the binary
```

Endpoints can also be written Hanami-style, mixed freely with controllers:

```
get "/stats", to: Actions::Stats::Show

app/actions/stats/show.rb             class Actions::Stats::Show < Rieles::Action
                                        def handle(request, response)
                                          response.render(view, count: Entry.count, ...)
app/views/stats/show.rb               class Views::Stats::Show < Rieles::View; expose :count, ...
app/templates/stats/show.html.erb     reads `count` as a local
```

A controller can render the same view with
`render view: Views::Stats::Show, count: ..., latest: ...`. Either way, the build
checks that `render` passes exactly the view's exposures.

## Try it

New app:

```sh
bin/rieles new ~/code/blog
cd ~/code/blog
bin/rieles generate scaffold Article title:string body:text published:boolean
bin/rieles server
```

The example:

```sh
cd examples/guestbook
bin/rieles server   # http://localhost:3000; first run builds ../../../vendor (~1 min)
bin/rieles routes
bin/rieles test     # test/**/*_test.rb against the compiled binary
bin/rieles          # all commands: server, build, routes, test, clean, setup
```

The generated source lands in `tmp/rieles/app.rb`, which is the place to look
when something doesn't compile.

## Tests

`bin/rieles test [FILES] [minitest options]` builds the app if needed and runs
Minitest in CRuby. `Rieles::IntegrationTest` starts the binary for every test
with an empty database and talks to it over HTTP; the server log goes to
`log/test.log`.

```ruby
class EntriesTest < Rieles::IntegrationTest
  def test_create
    post "/entries", params: { name: "Ana", body: "hi" }
    assert_redirected_to "/entries/1"
    follow_redirect!
    assert_body_includes "Ana"
  end
end
```

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
  `boolean`, `datetime`, `references`, `timestamps`, `default:`); `all`,
  `where`, `where.not`, `order`, `limit`, `offset`, `first`, `last`, `count`,
  `exists?`, `pluck`, `find`, `find_by`, `create`, `save`, `update`,
  `destroy` and their `!` forms, `transaction`; validations (`presence`,
  `length`, `numericality`, `format`, `inclusion`, `exclusion`, `uniqueness`,
  `validate :method`); callbacks; `belongs_to`, `has_many`, `has_one`.
- Controllers: `params[:x]`, strong params, `render :action, status:`,
  `render plain:`, `render json:`, `head`, `render view: Views::Stats::Show,
  exposure: value`, `redirect_to path, status:, notice:`, implicit render;
  `before_action`/`after_action`/`skip_*`, `rescue_from`, `session`, `flash`,
  CSRF protection, `_method` override.
- Views: layout with `yield`, partials (`render "entry", entry: entry`),
  `<%= %>` escapes, `<%== %>` and `raw` don't, `form_with` and field
  helpers, `link_to`, `button_to`, `csrf_meta_tags`, `pluralize`.
- Request log: Rails-style by default (filtered params, SQL, rendered
  templates, timings); one line per request with `RIELES_LOG_FORMAT=logfmt`
  or `json`. Each response carries `X-Request-Id`.
- Database: `db/schema.rb` (new columns are added at boot), or migrations in
  `db/migrate` applied at boot (`rieles generate migration AddXToPosts x:string`,
  `rieles db:migrate` also rewrites db/schema.rb); `db/seeds.rb`.
- Static files in `public/` and assets in `app/assets/`.
- i18n: `config/locales/*.yml`, `t(".title")`, `t("greeting", name: x)`,
  `I18n.locale = params[:locale]`, translated validation messages.

## Configuration

| Variable | Default | |
|---|---|---|
| `RIELES_ENV` | `development` | `production` hides error details and needs `SECRET_KEY_BASE` |
| `SECRET_KEY_BASE` | `tmp/local_secret.txt` | signs the session cookie |
| `DATABASE_PATH` | `db/development.sqlite3` | |
| `RIELES_LOG_FORMAT` | `dev` (`logfmt` in production) | `dev`, `logfmt`, `json` |
| `RIELES_LOG_LEVEL` | `debug` (`info` in production) | SQL and templates only at `debug` |
| `RIELES_LOG_FILE` | stdout | |
| `RIELES_SERVER` (build) | `scheduled` | `prefork` for production: tep's default server handles bursts better but ignores Ctrl+C on idle keep-alive connections ([OriPekelman/tep#277](https://github.com/OriPekelman/tep/issues/277)) |
| `RIELES_FILTER_PARAMETERS` | `password,token,secret,...` | substrings, comma-separated |

## Not yet

See [TODO.md](TODO.md).
