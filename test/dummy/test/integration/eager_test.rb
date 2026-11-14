class EagerTest < Spinrail::IntegrationTest
  LOG = File.join(Dir.tmpdir, "spinrail-eager-#{Process.pid}.log")
  server_env "SPINRAIL_LOG_FILE" => LOG, "SPINRAIL_LOG_LEVEL" => "debug"

  def setup
    File.delete(LOG) if File.exist?(LOG)
    super
    get "/models/seed"
  end

  def test_includes_preloads_each_association_once
    File.write(LOG, "")
    get "/models/eager"
    expected = <<~TEXT.chomp
      First:Ana:2:c1|c2
      Second:Ana:0:
      Third:Bea:0:
    TEXT
    assert_equal expected, response.body
    sleep 0.05
    log = File.read(LOG)
    assert_equal 1, log.scan("Comment Load").size, log
    assert_equal 0, log.scan("Comment Pluck").size, log
    assert_equal 1, log.scan("Author Load").size, log
  end
end
