class StrongParamsTest < Spinrail::IntegrationTest
  def setup
    self.class.server_env("SPINRAIL_LOG_FILE" => File.join(Dir.tmpdir, "spinrail-strong-#{Process.pid}-#{name}.log"),
                          "SPINRAIL_LOG_FORMAT" => "logfmt", "SPINRAIL_LOG_LEVEL" => "info")
    super
    get "/models/seed"
  end

  def test_mass_assignment_without_permit_raises
    post "/posts/unpermitted", params: { "post[title]" => "Injected", "post[author_id]" => "1" }
    assert_response :error
    assert_body_includes "Something went wrong"
    log = File.read(self.class.server_env["SPINRAIL_LOG_FILE"])
    assert_includes log, 'error="Spinrail::ForbiddenAttributesError'
  end

  def test_mass_assignment_with_permit_keeps_working
    post "/posts", params: { "post[title]" => "Fourth", "post[body]" => "text", "post[rating]" => "1.0", "post[author_id]" => "1" }
    assert_redirected_to "/posts/4"
  end
end
