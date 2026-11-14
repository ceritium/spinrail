require_relative "helper"

class MigrationsTest < CompilerTest
  def test_replays_migrations_into_sql_and_schema
    dir = app(
      "db/migrate/20260101000000_create_posts.rb" => <<~RUBY,
        class CreatePosts < Spinrail::Migration
          def change
            create_table :posts do |t|
              t.string :title
              t.timestamps
            end
            add_index :posts, :title, unique: true
          end
        end
      RUBY
      "db/migrate/20260102000000_change_posts.rb" => <<~RUBY
        class ChangePosts < Spinrail::Migration
          def change
            add_column :posts, :views, :integer, default: 0
            add_column :posts, :subtitle, :string, null: true
            rename_column :posts, :title, :headline
            remove_column :posts, :subtitle
          end
        end
      RUBY
    )
    m = Spinrail::Migrations.new(File.join(dir, "db/migrate"))
    assert_equal %w[20260101000000 20260102000000], m.migrations.map(&:version)
    assert_match(/\ACREATE TABLE posts \(id INTEGER PRIMARY KEY, title TEXT/, m.migrations[0].statements[0])
    assert_equal "CREATE UNIQUE INDEX IF NOT EXISTS index_posts_on_title ON posts (title)", m.migrations[0].statements[1]
    assert_includes m.migrations[1].statements, "ALTER TABLE posts RENAME COLUMN title TO headline"
    assert_equal %w[id headline created_at updated_at views], m.tables["posts"].columns.map(&:name)
    schema = m.schema_rb
    assert_includes schema, "Spinrail::Schema.define(version: 20260102000000) do"
    assert_includes schema, "t.integer :views, default: 0"
    reread = Spinrail::Schema.new(File.join(app("db/schema.rb" => schema), "db/schema.rb"))
    assert_equal %w[id headline views created_at updated_at], reread.table("posts").columns.map(&:name)
  end

  def test_down_statements
    dir = app(
      "db/migrate/20260101000000_create_posts.rb" => "class A < Spinrail::Migration\n def change\n create_table :posts do |t|\n t.string :title\n end\n add_index :posts, :title\n end\nend\n",
      "db/migrate/20260102000000_tweak.rb" => "class B < Spinrail::Migration\n def change\n add_column :posts, :views, :integer\n remove_column :posts, :title\n end\nend\n",
      "db/migrate/20260103000000_data.rb" => "class C < Spinrail::Migration\n def change\n execute \"UPDATE posts SET views = 1\"\n end\nend\n",
      "db/migrate/20260104000000_manual.rb" => "class D < Spinrail::Migration\n def up\n drop_table :posts\n end\n\n def down\n create_table :posts do |t|\n t.string :x, null: false\n end\n end\nend\n"
    )
    m = Spinrail::Migrations.new(File.join(dir, "db/migrate")).migrations
    assert_equal ["DROP INDEX IF EXISTS index_posts_on_title", "DROP TABLE posts"], m[0].down
    assert_equal ["ALTER TABLE posts ADD COLUMN title TEXT", "ALTER TABLE posts DROP COLUMN views"], m[1].down
    assert_nil m[2].down
    assert_equal ["CREATE TABLE posts (id INTEGER PRIMARY KEY, x TEXT NOT NULL DEFAULT '')"], m[3].down
  end

  def test_unknown_table
    dir = app("db/migrate/20260101000000_x.rb" => "class X < Spinrail::Migration\n def change\n add_column :nope, :a, :string\n end\nend\n")
    assert_raises(Spinrail::CompileError) { Spinrail::Migrations.new(File.join(dir, "db/migrate")) }
  end
end
