require_relative "helper"

class SchemaTest < CompilerTest
  def test_columns
    dir = app("db/schema.rb" => <<~RUBY)
      Spinrail::Schema.define do
        create_table :posts do |t|
          t.references :author
          t.boolean :published, default: true, null: false
          t.float :rating
          t.string :title, default: "x"
          t.timestamps
        end
      end
    RUBY
    table = Spinrail::Schema.new(File.join(dir, "db/schema.rb")).table("posts")
    assert_equal %w[id author_id published rating title created_at updated_at], table.columns.map(&:name)
    assert_includes table.create_sql, "published INTEGER NOT NULL DEFAULT 1"
    assert_includes table.create_sql, "title TEXT DEFAULT 'x'"
    assert_includes table.create_sql, "rating REAL,"
    assert table.column("rating").null
    assert_equal "true", table.column("published").default_literal
  end

  def test_datetime_columns_are_times
    dir = app("db/schema.rb" => <<~RUBY)
      Spinrail::Schema.define do
        create_table :memberships do |t|
          t.datetime :unread_at
          t.datetime :connected_at, null: false
          t.date :due_on
          t.timestamps
        end
      end
    RUBY
    table = Spinrail::Schema.new(File.join(dir, "db/schema.rb")).table("memberships")
    assert_equal %i[datetime datetime string datetime datetime], table.columns.drop(1).map(&:type)
    assert_includes table.create_sql, "unread_at TEXT,"
    assert_includes table.create_sql, "connected_at TEXT NOT NULL DEFAULT ''"
    unread = table.column("unread_at")
    assert_equal "(db.col_null?(1) ? nil : Spinrail.parse_time(db.col_str(1)))", unread.read(1)
    assert_equal "(t.nil? ? db.bind_null(1) : db.bind_str(1, Spinrail.format_time(t)))", unread.bind(1, "t")
    assert_equal "nil", unread.default_literal
    assert_equal "Time.at(0)", table.column("connected_at").default_literal
  end

  def test_unknown_type
    dir = app("db/schema.rb" => "Spinrail::Schema.define do\n create_table :x do |t|\n t.json :y\n end\nend\n")
    assert_raises(Spinrail::CompileError) { Spinrail::Schema.new(File.join(dir, "db/schema.rb")) }
  end

  def test_virtual_tables
    dir = app("db/schema.rb" => %(Spinrail::Schema.define do\n create_virtual_table "idx", "fts5", ["body", "tokenize=porter"]\nend\n))
    schema = Spinrail::Schema.new(File.join(dir, "db/schema.rb"))
    assert_equal ["CREATE VIRTUAL TABLE IF NOT EXISTS idx USING fts5(body, tokenize=porter)"], schema.virtual_tables
  end
end
