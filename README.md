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

```sh
cd examples/guestbook
bin/rieles server   # http://localhost:3000; first run builds ../../../vendor (~1 min)
bin/rieles routes
bin/rieles          # all commands: server, build, routes, clean, setup
```

The generated source lands in `tmp/rieles/app.rb`, which is the place to look
when something doesn't compile.

## Supported so far

- Routes: `root`, `resources` (with `only:`/`except:`), `get/post/... "path", to:`.
- Models: columns from `create_table` (`string`, `text`, `integer`, `datetime`,
  `references`, `timestamps`); `all`, `where`, `order`, `limit`, `count`,
  `find` (404 when missing), `save`, `destroy`; `validates` with `presence`
  and `length`; `errors.any?`, `errors.full_messages`, `errors[:attr]`.
- Controllers: `params[:x]`, `render :action, status:`, `render plain:`,
  `render view: Views::Stats::Show, exposure: value`,
  `redirect_to path, status:`, implicit render of `controller/action`.
- Views: layout with `yield`, partials (`render "entry", entry: entry`),
  `<%= %>` escapes, `<%== %>` and `raw` don't, `pluralize`.
- Request log: Rails-style by default (params with `password`/`token`/`secret`
  filtered, SQL, rendered templates, timings); one line per request with
  `RIELES_LOG_FORMAT=logfmt` or `RIELES_LOG_FORMAT=json`.

## Not yet

See [TODO.md](TODO.md).
