class Actions::Signups::Create < Rieles::Action
  params do
    required(:user).hash do
      required(:name).filled(:string)
      optional(:age).maybe(:integer)
    end
    optional(:newsletter).maybe(:bool)
  end

  def handle(request, response)
    halt 422, request.params.errors.full_messages.join(", ") unless request.params.valid?
    response.status = 201
    response.render(view, name: request.params[:user].to_s)
  end
end
