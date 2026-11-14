class UploadsTest < Spinrail::IntegrationTest
  def test_a_file_field_makes_the_form_multipart
    get "/uploads/new"
    assert_select "form[enctype='multipart/form-data']"
    assert_select "input[type=file][name='doc[file]'][id=doc_file][accept='text/plain']"
  end

  def test_uploaded_files_reach_request_files
    post "/uploads", params: { "doc[title]" => "Notes", "doc[file]" => fixture_file_upload("hello.txt", "text/plain") }
    assert_response :success
    assert_equal "Notes: hello.txt (text/plain, 11 bytes)", response.body
  end

  def test_a_missing_file
    post "/uploads", params: { "doc[title]" => "Notes" }
    assert_response 422
  end
end
