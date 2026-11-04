# GET/POST/PATCH /psychosocial/beds[/:id] (contrato §3): leitos do
# acolhimento noturno, só do municipal_admin; escrita com step-up. A lista
# exige `?health_unit_id=` e vem por rótulo; leito de outro id → 404.
module Psychosocial
  class BedsController < BaseController
    before_action { forbid unless admin? }
    before_action :require_step_up!, only: %i[create update]

    def index
      return unless query_only!("health_unit_id")

      id = params[:health_unit_id]
      unit = uuid?(id) ? HealthUnit.find_by(id: id, kind: "caps") : nil
      return render_refusal("health_unit_id") unless unit

      beds = PsychosocialBed.where(health_unit_id: unit.id).order(:label, :id)
      render json: { items: beds.map { |bed| Json.bed(bed) } }
    end

    def create
      result = SaveBed.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.bed(result.payload.fetch(:bed)), status: :created
    end

    def update
      bed = uuid?(params[:id]) ? PsychosocialBed.find_by(id: params[:id]) : nil
      return not_found unless bed

      result = SaveBed.call(attrs: body, by: Current.user, bed: bed)
      return render_failure(result) if result.failure?

      render json: Json.bed(result.payload.fetch(:bed))
    end
  end
end
