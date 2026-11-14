require "socket"

class MailApiTest < Spinrail::IntegrationTest
  API = TCPServer.new("127.0.0.1", 0)
  server_env "SPINRAIL_MAIL_DELIVERY" => "http", "SPINRAIL_MAIL_URL" => "http://127.0.0.1:#{API.addr[1]}/emails",
             "SPINRAIL_MAIL_TOKEN" => "re_test"

  def test_mail_goes_to_the_api
    captured = Thread.new do
      client = API.accept
      head = +""
      head << client.gets until head.end_with?("\r\n\r\n")
      length = head[/content-length: (\d+)/i, 1].to_i
      body = client.read(length)
      client.write("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}")
      client.close
      [head, body]
    end
    post "/signup", params: { "user[email]" => "dee@example.com", "user[password]" => "pw" }
    assert_response :success
    head, body = captured.value
    assert_match %r{\APOST /emails}, head
    assert_match(/authorization: Bearer re_test/i, head)
    mail = JSON.parse(body)
    assert_equal "dee@example.com", mail["to"]
    assert_equal "Welcome, dee@example.com", mail["subject"]
    assert_includes mail["text"], "Hi dee@example.com"
  end
end
