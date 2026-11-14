require_relative "helper"

class SchemaTest < CompilerTest
  def test_columns
    dir = app("db/schema.rb" => <<~RUBY)
      Spinrail::Schema.define do
        create_table :posts do |t|
          t.references :author
          t.boolean :published, default: true
          t.float :rating
          t.string :title, default: "x"
          t.timestamps
        end
      end
    RUBY
    table = Spinrail::Schema.new(File.join(dir, "db/schema.rb")).table("posts")
    assert_equal %w[id author_id published rating title created_at updated_at], table.columns.map(&:name)
    assert_includes table.create_sql, "published INTEGER NOT NULL DEFAULT 1"
    assert_includes table.create_sql, "title TEXT NOT NULL DEFAULT 'x'"
    assert_equal "true", table.column("published").default_literal
  end

  def test_unknown_type
    dir = app("db/schema.rb" => "Spinrail::Schema.define do\n create_table :x do |t|\n t.json :y\n end\nend\n")
    assert_raises(Spinrail::CompileError) { Spinrail::Schema.new(File.join(dir, "db/schema.rb")) }
  end
end
