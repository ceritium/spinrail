class UploadsController < ApplicationController
  def new
  end

  def create
    file = request.files["doc[file]"]
    if file.nil?
      render plain: "no file", status: :unprocessable_entity
    else
      title = params[:doc][:title]
      render plain: "#{title}: #{file.original_filename} (#{file.content_type}, #{file.size} bytes)"
    end
  end
end
