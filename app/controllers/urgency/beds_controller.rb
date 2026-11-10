# GET/POST/PATCH /urgency/beds[/:id] (contrato §3; ADR 0050): leitos da
# observação da UPA, só do municipal_admin (403 missing_role); escrita com
# step-up. A lista exige `?health_unit_id=` de uma UPA e vem por rótulo. Sem
# paciente: sem trilha.
module Urgency
  class BedsController < BaseController
    before_action { forbid unless Current.user.has_role?("municipal_admin") }
    before_action :require_step_up!, only: %i[create update]

    def index
      return unless query_only!("health_unit_id")

      id = params[:health_unit_id]
      unit = uuid?(id) ? HealthUnit.find_by(id: id, kind: "upa") : nil
      return render_refusal("health_unit_id") unless unit

      beds = UrgencyBed.where(health_unit_id: unit.id).order(:label, :id).to_a
      occupied = UrgencyBedStay.open_stays.where(urgency_bed_id: beds.map(&:id)).pluck(:urgency_bed_id).to_set
      render json: { items: beds.map { |bed| bed_json(bed, occupied.include?(bed.id)) } }
    end

    def create
      result = SaveBed.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: { bed: bed_json(result.payload.fetch(:bed), false) }, status: :created
    end

    def update
      bed = uuid?(params[:id]) ? UrgencyBed.find_by(id: params[:id]) : nil
      return not_found unless bed

      result = SaveBed.call(attrs: body, by: Current.user, bed: bed)
      return render_failure(result) if result.failure?

      bed = result.payload.fetch(:bed)
      render json: { bed: bed_json(bed, bed.bed_stays.open_stays.exists?) }
    end

    private

    def bed_json(bed, occupied)
      { id: bed.id, health_unit_id: bed.health_unit_id, label: bed.label, active: bed.active, occupied: occupied }
    end
  end
end
