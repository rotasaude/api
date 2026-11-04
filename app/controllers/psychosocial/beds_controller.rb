# GET/POST/PATCH /psychosocial/beds[/:id] (contrato §3): leitos do
# acolhimento noturno, só do municipal_admin; escrita com step-up. A lista
# exige `?health_unit_id=` e vem por rótulo; leito de outro id → 404.
# GET /psychosocial/beds/board?health_unit_id&date (contrato §5): o mapa da
# equipe lotada no CAPS — os leitos ativos, o ocupante da noite de `date`
# (padrão: hoje) só como <patient-ref>, as noites usadas na janela que termina
# em `date` e o limite. Nada clínico e sem trilha (a trilha é do detalhe).
module Psychosocial
  class BedsController < BaseController
    before_action(except: :board) { forbid unless admin? }
    before_action :require_step_up!, only: %i[create update]

    def index
      return unless query_only!("health_unit_id")

      id = params[:health_unit_id]
      unit = uuid?(id) ? HealthUnit.find_by(id: id, kind: "caps") : nil
      return render_refusal("health_unit_id") unless unit

      beds = PsychosocialBed.where(health_unit_id: unit.id).order(:label, :id)
      render json: { items: beds.map { |bed| Json.bed(bed) } }
    end

    def board
      return unless query_only!("health_unit_id", "date")

      unit = staff_unit!(params[:health_unit_id])
      return unless unit
      return render_refusal("health_unit_id", "caps_without_beds") unless unit.night_capable?

      date = params.key?(:date) ? Input.date(params[:date]) : Time.zone.today
      return render_refusal("date") unless date

      beds = PsychosocialBed.where(health_unit_id: unit.id, active: true).order(:label, :id).to_a
      stays = occupants(beds, date)
      settings = Settings.current
      render json: {
        date: Json.date(date), window_days: settings.night_limits.dig(unit.caps_modality, "window_days"),
        items: beds.map { |bed| board_item(bed, stays[bed.id], unit, date, settings) }
      }
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

    private

    # { bed_id => a permanência na noite de `date` } — a aberta que começou até
    # essa noite, ou a fechada que tem essa noite; havendo duas no dia, a que
    # entrou por último.
    def occupants(beds, date)
      from = date.in_time_zone.beginning_of_day
      PsychosocialNightStay.includes(:patient).where(psychosocial_bed_id: beds.map(&:id)).where(started_at: ...(from + 1.day))
                           .where("ended_at IS NULL OR ended_at > ?", from).order(:started_at).to_a
                           .select { |stay| stay.open? || NightLimit.nights(stay).include?(date) }
                           .index_by(&:psychosocial_bed_id)
    end

    def board_item(bed, stay, unit, date, settings)
      usage = stay && NightLimit.used(patient_id: stay.patient_id, modality: unit.caps_modality, date: date, settings: settings)
      { bed: Json.bed(bed), stay: stay && Json.board_stay(stay), nights_used: usage&.dig(:used), limit: usage&.dig(:limit) }
    end
  end
end
