class ActiveStorageTest < Spinrail::IntegrationTest
  def upload(name = "pixel.png", type = "image/png")
    post "/documents", params: { document: { title: "Doc", file: fixture_file_upload(name, type) } }
    follow_redirect!
    response.body.split("|")
  end

  def test_uploading_and_serving_a_binary_file
    png = File.binread(File.join(Dir.pwd, "test/fixtures/files/pixel.png"))
    title, filename, type, size, checksum, path, download_path = upload
    assert_equal ["Doc", "pixel.png", "image/png", png.bytesize.to_s], [title, filename, type, size]
    assert_equal Base64.strict_encode64(Digest::MD5.digest(png)), checksum
    assert_match %r{\A/rails/active_storage/blobs/proxy/[^/]+/pixel\.png\z}, path

    get path
    assert_response :success
    assert_equal png, response.body.b
    assert_equal "image/png", response["Content-Type"]
    assert_equal %(inline; filename="pixel.png"), response["Content-Disposition"]
    assert_includes response["Cache-Control"], "immutable"

    get download_path
    assert_equal %(attachment; filename="pixel.png"), response["Content-Disposition"]

    assert_equal 1, stored_files.size
  end

  def test_send_data
    post "/documents", params: { document: { title: "Doc", file: fixture_file_upload("hello.txt", "text/plain") } }
    get "/documents/1/download"
    assert_equal "hello\nfile\n", response.body
    assert_equal "text/plain", response["Content-Type"]
    assert_equal %(attachment; filename="copy.png"), response["Content-Disposition"]
  end

  def test_tampered_ids_are_not_found
    path = upload[5]
    get path.sub(/--(\h)/) { "--#{Regexp.last_match(1) == "0" ? "1" : "0"}" }
    assert_response :not_found
  end

  def test_script_types_download_as_binary
    path = upload("evil.svg", "image/svg+xml")[5]
    get path
    assert_equal "application/octet-stream", response["Content-Type"]
    assert_match(/\Aattachment/, response["Content-Disposition"])
  end

  def test_replacing_and_purging
    first = upload[5]
    patch "/documents/1", params: { document: { file: fixture_file_upload("hello.txt", "text/plain") } }
    follow_redirect!
    assert_equal "hello.txt", response.body.split("|")[1]
    get first
    assert_response :not_found
    assert_equal 1, stored_files.size
    get "/documents/1"
    second = response.body.split("|")[5]
    patch "/documents/1", params: { document: { title: "Renamed" } }
    get "/documents/1"
    assert_equal "Renamed|hello.txt", response.body.split("|")[0, 2].join("|")
    delete "/documents/1"
    get second
    assert_response :not_found
    assert_empty stored_files
  end

  def stored_files = Dir[File.join(storage_root, "**/*")].select { |f| File.file?(f) }

  def test_signed_ids
    post "/documents", params: { document: { title: "Doc" } }
    get "/documents/1/signed"
    assert_equal "Doc|nil|Doc", response.body
  end

  def test_no_attachment
    post "/documents", params: { document: { title: "Empty" } }
    follow_redirect!
    assert_equal "Empty|none", response.body
  end
end
