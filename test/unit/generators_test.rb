require_relative "helper"
require "stringio"
require_relative "../../lib/spinrail/fixtures"

class GeneratorsTest < CompilerTest
  def test_new_app_with_a_scaffold_passes_the_build_checks
    dir = File.join(Dir.mktmpdir("spinrail-gen"), "blog")
    (@dirs ||= []) << File.dirname(dir)
    out = StringIO.new
    Spinrail::Generators.new(dir, out).new_app(bundle: false)
    Spinrail::Generators.new(dir, out).generate("scaffold", "Article", %w[title:string body:text published:boolean author:references])
    Spinrail::Generators.new(dir, out).generate("model", "Author", %w[name:string])
    Spinrail::Generators.new(dir, out).generate("authentication", nil, [])
    Spinrail::Generators.new(dir, out).generate("mailer", "Notifications", %w[weekly])
    ruby = Spinrail::Build.new(dir).send(:generate)
    assert_includes ruby, "class ArticlesController"
    assert_includes ruby, "def edit_article_path(id)"
    assert_includes File.read(File.join(dir, "db/schema.rb")), "t.references :author"
    assert_includes File.read(File.join(dir, ".rubocop.yml")), "spinrail/rubocop"
    assert_includes File.read(File.join(dir, "config/application.rb")), %(config.time_zone = "UTC")
    assert_includes File.read(File.join(dir, "app/models/article.rb")), "belongs_to :author"
    assert_includes ruby, "class SessionsController"
    assert_includes ruby, "class NotificationsMailer"
    digest = Spinrail::Fixtures.rows(dir)["users"]["one"].password_digest
    assert_match(/\Apbkdf2-sha256\$1000\$[\w-]+\$[\w-]{43}\z/, digest)
  end

  def test_new_app_inits_a_git_repo_unless_skipped
    root = Dir.mktmpdir("spinrail-git")
    (@dirs ||= []) << root
    Spinrail::Generators.new(File.join(root, "a"), StringIO.new).new_app(bundle: false)
    assert File.directory?(File.join(root, "a/.git"))
    Spinrail::Generators.new(File.join(root, "b"), StringIO.new).new_app(git: false, bundle: false)
    refute File.exist?(File.join(root, "b/.git"))
    Spinrail::Generators.new(File.join(root, "a/nested"), StringIO.new).new_app(bundle: false)
    refute File.exist?(File.join(root, "a/nested/.git"))
  end

  def test_model_fields_take_not_null_and_index_modifiers
    dir = File.join(Dir.mktmpdir("spinrail-mod"), "app")
    (@dirs ||= []) << File.dirname(dir)
    Spinrail::Generators.new(dir, StringIO.new).new_app(git: false, bundle: false)
    Spinrail::Generators.new(dir, StringIO.new).generate("model", "User", %w[name email_address:string!:uniq bio:text role:integer:index team:references])
    schema = File.read(File.join(dir, "db/schema.rb"))
    assert_includes schema, "t.string :email_address, null: false"
    assert_includes schema, "t.text :bio\n"
    assert_includes schema, "t.references :team, null: false"
    assert_includes schema, "add_index :users, [:email_address], unique: true"
    assert_includes schema, "add_index :users, [:role]\n"
    tables = Spinrail::Schema.new(File.join(dir, "db/schema.rb"))
    assert_equal 2, tables.indexes.size
  end
end
