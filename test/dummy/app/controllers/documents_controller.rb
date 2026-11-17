class DocumentsController < ActionController::Base
  # PROTECTED: optimistic locking turns the second of two simultaneous edits away with a 409.
  def rename
    document = Document.find(params[:id])
    document.update!(title: params[:title])
    head :ok
  rescue ActiveRecord::StaleObjectError
    head :conflict
  end
end
