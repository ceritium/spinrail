class DocumentsController < ApplicationController
  layout false
  before_action :set_document, only: %i[show update destroy download signed]

  def create
    document = Document.create!(document_params)
    redirect_to document_path(document)
  end

  def show
    file = @document.file
    if file.attached?
      render plain: [@document.title, file.filename, file.content_type, file.byte_size, file.checksum, rails_blob_path(file), rails_blob_path(file, disposition: "attachment")].join("|")
    else
      render plain: @document.title + "|none"
    end
  end

  def update
    @document.update!(document_params)
    redirect_to document_path(@document)
  end

  def destroy
    @document.destroy
    head :no_content
  end

  def signed
    signed_id = @document.signed_id(purpose: :share)
    found = Document.find_signed(signed_id, purpose: :share)
    other = Document.find_signed(signed_id)
    render plain: found.title + "|" + (other.nil? ? "nil" : "found") + "|" + Document.find_signed!(@document.signed_id).title
  end

  def download
    send_data @document.file.download, type: @document.file.content_type, filename: "copy.png"
  end

  private

  def set_document
    @document = Document.find(params[:id])
  end

  def document_params
    params.require(:document).permit(:title, :file)
  end
end
