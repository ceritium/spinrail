class EntriesController < ApplicationController
  def index
    @entries = Entry.order(id: :desc).limit(50)
    @entry = Entry.new
  end

  # Controllers can render Hanami-style views too.
  def summary
    render view: Views::Stats::Show, count: Entry.count, latest: Entry.order(id: :desc).limit(3)
  end

  def show
    @entry = Entry.find(params[:id])
  end

  def create
    @entry = Entry.new(entry_params)
    if @entry.save
      respond_to do |format|
        # With Turbo the page stays: the entry is prepended and the form reset.
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.prepend("entries", partial: "entries/entry", locals: { entry: @entry }),
            turbo_stream.update("count", Entry.count.to_s + (Entry.count == 1 ? " message" : " messages")),
            turbo_stream.replace("entry_form", partial: "entries/form", locals: { entry: Entry.new })
          ]
        end
        format.html { redirect_to entry_path(@entry), status: :see_other }
      end
    else
      @entries = Entry.order(id: :desc).limit(50)
      render :index, status: :unprocessable_entity
    end
  end

  private

  def entry_params
    params.require(:entry).permit(:name, :body)
  end
end
