require_relative "helper"
require "stringio"
require_relative "../../lib/rieles/fixtures"

class GeneratorsTest < CompilerTest
  def test_new_app_with_a_scaffold_passes_the_build_checks
    dir = File.join(Dir.mktmpdir("rieles-gen"), "blog")
    (@dirs ||= []) << File.dirname(dir)
    out = StringIO.new
    Rieles::Generators.new(dir, out).new_app
    Rieles::Generators.new(dir, out).generate("scaffold", "Article", %w[title:string body:text published:boolean author:references])
    Rieles::Generators.new(dir, out).generate("model", "Author", %w[name:string])
    Rieles::Generators.new(dir, out).generate("authentication", nil, [])
    Rieles::Generators.new(dir, out).generate("mailer", "Notifications", %w[weekly])
    ruby = Rieles::Build.new(dir).send(:generate)
    assert_includes ruby, "class ArticlesController"
    assert_includes ruby, "def edit_article_path(id)"
    assert_includes File.read(File.join(dir, "db/schema.rb")), "t.references :author"
    assert_includes File.read(File.join(dir, "app/models/article.rb")), "belongs_to :author"
    assert_includes ruby, "class SessionsController"
    assert_includes ruby, "class NotificationsMailer"
    digest = Rieles::Fixtures.rows(dir)["users"]["one"].password_digest
    assert_match(/\Apbkdf2-sha256\$1000\$[\w-]+\$[\w-]{43}\z/, digest)
  end
end
