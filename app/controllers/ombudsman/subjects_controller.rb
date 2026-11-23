# GET/POST/PATCH /ombudsman/subjects (ADR 0051; contrato §7): assuntos e
# subassuntos (dois níveis). Leitura: técnico e ouvidor; escrita: só o ouvidor.
# A leitura cria a semente se a tabela está vazia (Q13).
# Módulo 35b (§4, Q14): com o zoonoses e a ouvidoria utilizáveis
# (Zoonoses::Gate.ombudsman_usable?, lido aqui, fora da transação), a leitura
# garante também os assuntos reservados (Ombudsman::Subjects) e a edição
# recusa desativá-los (409 reserved_subject). Todo item traz `code` (nulo no
# assunto da cidade).
module Ombudsman
  class SubjectsController < BaseController
    before_action :require_staff!, only: :index
    before_action :require_ombudsman_role!, only: %i[create update]
    before_action :query_only!

    def index
      Settings.ensure_defaults!
      Subjects.ensure_zoonoses! if zoonoses?
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

      result = SaveSubject.call(subject: subject, attrs: body, zoonoses: zoonoses?)
      return render_failure(result) if result.failure?

      render json: json(result.payload[:subject])
    end

    private

    def zoonoses? = Zoonoses::Gate.ombudsman_usable?(Current.city)

    def json(subject)
      item = item(subject)
      return item if subject.parent_id

      item.merge(children: subject.children.map { |child| item(child) })
    end

    def item(subject) = { id: subject.id, name: subject.name, active: subject.active, code: subject.code }
  end
end
