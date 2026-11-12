# GET/POST/PATCH /ombudsman/subjects (ADR 0051; contrato §7): assuntos e
# subassuntos (dois níveis). Leitura: técnico e ouvidor; escrita: só o ouvidor.
# A leitura cria a semente se a tabela está vazia (Q13).
module Ombudsman
  class SubjectsController < BaseController
    before_action :require_staff!, only: :index
    before_action :require_ombudsman_role!, only: %i[create update]
    before_action :query_only!

    def index
      Settings.ensure_defaults!
      subjects = OmbudsmanSubject.includes(:children).where(parent_id: nil).order(:position, :name)
      render json: { items: subjects.map { |subject| json(subject) } }
    end

    def create
      result = SaveSubject.call(subject: nil, attrs: body)
      return render_failure(result) if result.failure?

      render json: json(result.payload[:subject]), status: :created
    end

    def update
      subject = uuid?(params[:id]) ? OmbudsmanSubject.find_by(id: params[:id]) : nil
      return not_found unless subject

      result = SaveSubject.call(subject: subject, attrs: body)
      return render_failure(result) if result.failure?

      render json: json(result.payload[:subject])
    end

    private

    def json(subject)
      item = { id: subject.id, name: subject.name, active: subject.active }
      return item if subject.parent_id

      item.merge(children: subject.children.map { |child| { id: child.id, name: child.name, active: child.active } })
    end
  end
end
