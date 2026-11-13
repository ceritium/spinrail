class EntriesController < ApplicationController
  def index
    @entries = Entry.order(id: :desc).limit(50)
    @entry = Entry.new
  end

  def show
    @entry = Entry.find(params[:id])
  end

  def create
    @entry = Entry.new(name: params[:name], body: params[:body])
    if @entry.save
      redirect_to entry_path(@entry), status: :see_other
    else
      @entries = Entry.order(id: :desc).limit(50)
      render :index, status: :unprocessable_entity
    end
  end
end
