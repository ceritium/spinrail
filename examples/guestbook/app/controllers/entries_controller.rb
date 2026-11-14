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
      redirect_to entry_path(@entry), status: :see_other
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
