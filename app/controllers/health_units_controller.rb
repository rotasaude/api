# Cadastro de unidades de saúde (spec 2026-09-24-citizen-attendance-check-in
# §4, §6): leitura para citizen_verifier, health_professional e
# municipal_admin; escrita só para municipal_admin.
class HealthUnitsController < ApplicationController
  include Authentication
  include AttendanceAccess

  # Endereço da unidade (ADR 0023; spec 2026-09-28-module-11-territory §4.1).
  ADDRESS_FIELDS = %w[address_street address_number address_complement address_zip neighborhood_id].freeze

  before_action :require_unit_reader, only: %i[index]
  before_action :require_admin, only: %i[all create update deactivate activate drain]
  before_action :set_unit, only: %i[update deactivate activate drain]

  def index
    render json: { units: HealthUnit.active_units.map { |u| unit_json(u) } }
  end

  # Para o admin: cada unidade com quantos pedidos vivos e horários marcados
  # ainda a prendem (o que "Esvaziar unidade" moveria; api#29).
  def all
    requests = AppointmentRequest.live_requests.group(:target_unit_id).count
    appointments = Appointment.live.group(:health_unit_id).count
    render json: { units: HealthUnit.order(:name).map do |u|
      unit_json(u, include_active: true).merge(live_requests_count: requests[u.id] || 0,
                                               live_appointments_count: appointments[u.id] || 0)
    end }
  end

  # POST /attendance/units/:id/drain { target_unit_id, reason } (api#29; F-09.3)
  def drain
    return render json: { error: "not_found" }, status: :not_found unless @unit

    result = HealthUnits::Drain.call(unit: @unit, target_unit_id: params[:target_unit_id], reason: params[:reason],
                                     by: Current.user)
    return render json: { error: result.reason.to_s }, status: :unprocessable_entity if result.failure?

    render json: { drain: { id: result.payload[:drain].id, requests_count: result.payload[:requests],
                            appointments_count: result.payload[:appointments] } }
  end

  def create
    unit = HealthUnit.new(name: params[:name], kind: params[:kind])
    error = assign_address(unit) || assign_cnes(unit) || assign_screening_scope(unit) ||
            assign_collects_samples(unit) || assign_notifying(unit)
    return render(json: { error: error }, status: :unprocessable_entity) if error
    return render_invalid(unit) unless unit.save

    render json: { unit: unit_json(unit, include_active: true) }, status: :created
  rescue ActiveRecord::RecordNotUnique => e
    render json: { error: e.message.include?("idx_health_units_cnes") ? "cnes_taken" : "unit_name_taken" },
           status: :unprocessable_entity
  end

  def update
    return render json: { error: "not_found" }, status: :not_found unless @unit

    @unit.assign_attributes(name: params[:name], kind: params[:kind])
    error = assign_address(@unit) || assign_cnes(@unit) || assign_screening_scope(@unit) ||
            assign_collects_samples(@unit) || assign_notifying(@unit)
    return render(json: { error: error }, status: :unprocessable_entity) if error
    return render_invalid(@unit) unless @unit.save

    render json: { unit: unit_json(@unit, include_active: true) }
  rescue ActiveRecord::RecordNotUnique => e
    render json: { error: e.message.include?("idx_health_units_cnes") ? "cnes_taken" : "unit_name_taken" },
           status: :unprocessable_entity
  end

  def deactivate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    # FOR UPDATE na unidade: espera o check-in ou encaminhamento em curso
    # (HealthUnit.lock_active!) e só então confere o que está aberto.
    conflict = nil
    @unit.with_lock do
      conflict = deactivation_conflict
      @unit.update!(active: false) unless conflict
    end
    return render json: { error: conflict }, status: :conflict if conflict

    render json: { unit: unit_json(@unit, include_active: true) }
  end

  def activate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    @unit.update!(active: true)
    render json: { unit: unit_json(@unit, include_active: true) }
  end

  private

  def deactivation_conflict
    return "unit_has_open_attendances" if Attendance.open_attendances.where(health_unit: @unit).exists?

    return "unit_has_open_requests" if AppointmentRequest.live_requests.where(target_unit: @unit).exists?

    "pharmacy_pending" if pharmacy_pending?
  end

  # H14 (módulo 27a): a farmácia da unidade com transferência `sent` (origem
  # ou destino) ou ajuste `pending` prende a unidade ativa, senão o recebimento
  # ficaria em location_inactive para sempre. Só com o interruptor `pharmacy`
  # utilizável. Roda sob o FOR UPDATE da unidade: quem grava `sent`/`pending`
  # toma FOR SHARE nela (Pharmacy::Ledger.lock_location!), então uma leitura
  # simples basta e nenhum lote é travado depois da unidade.
  def pharmacy_pending?
    return false unless Pharmacy::Gate.usable?(Current.city)

    location = StockLocation.find_by(kind: "unit", health_unit_id: @unit.id)
    location.present? && Pharmacy::PendingWork.any?(location)
  end

  def require_unit_reader
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid unless policy.verify? || policy.care? || policy.manage?
  end

  def set_unit
    @unit = HealthUnit.find_by(id: params[:id])
  end

  # Só as chaves presentes no corpo mudam: um cliente que ainda não manda o
  # endereço (dashboard anterior ao módulo 11) não o apaga ao salvar nome e
  # tipo. Valor não escalar é recusado com o código do campo. Bairro precisa
  # existir (inativo é aceito: é onde a unidade fica, não uma escolha nova).
  def assign_address(unit)
    ADDRESS_FIELDS.each do |field|
      next unless params.key?(field)

      value = params[field]
      return address_error(field) unless value.nil? || value.is_a?(String)
      if field == "neighborhood_id" && value.present? && !Neighborhood.exists?(id: value)
        return "invalid_neighborhood"
      end

      unit.public_send("#{field}=", value.presence)
    end
    nil
  end

  # CNES da unidade (ADR 0028): só muda quando a chave vem no corpo; null e ""
  # limpam. Formato e unicidade ficam com o modelo (render_invalid).
  def assign_cnes(unit)
    return nil unless params.key?("cnes")

    value = params["cnes"]
    return "invalid_cnes" unless value.nil? || value.is_a?(String)

    unit.cnes = value.presence
    nil
  end

  # ADR 0030: para quem a escuta é obrigatória. Só muda quando a chave vem.
  def assign_screening_scope(unit)
    return nil unless params.key?("screening_scope")

    value = params["screening_scope"]
    return "invalid_screening_scope" unless value.is_a?(String) && HealthUnit::SCREENING_SCOPES.include?(value)

    unit.screening_scope = value
    nil
  end

  # ADR 0037: a unidade coleta amostras para o laboratório municipal.
  def assign_collects_samples(unit)
    return nil unless params.key?("collects_samples")
    return "invalid_collects_samples" unless [ true, false ].include?(params["collects_samples"])

    unit.collects_samples = params["collects_samples"]
    nil
  end

  # ADR 0043: a unidade notifica doença de notificação compulsória. Só muda
  # quando a chave vem; ausente na criação, o modelo decide (APS = sim).
  def assign_notifying(unit)
    return nil unless params.key?("notifying")
    return "invalid_notifying" unless [ true, false ].include?(params["notifying"])

    unit.notifying = params["notifying"]
    nil
  end

  def address_error(field)
    { "address_zip" => "invalid_zip", "neighborhood_id" => "invalid_neighborhood" }.fetch(field, "invalid_unit")
  end

  def render_invalid(unit)
    if unit.errors.details[:name]&.any? { |e| e[:error] == :taken }
      render json: { error: "unit_name_taken" }, status: :unprocessable_entity
    elsif unit.errors.details[:cnes]&.any? { |e| e[:error] == :taken }
      render json: { error: "cnes_taken" }, status: :unprocessable_entity
    elsif unit.errors.details[:cnes].present?
      render json: { error: "invalid_cnes" }, status: :unprocessable_entity
    elsif unit.errors.details[:kind].present?
      render json: { error: "invalid_kind" }, status: :unprocessable_entity
    elsif unit.errors.details[:address_zip].present?
      render json: { error: "invalid_zip" }, status: :unprocessable_entity
    else
      render json: { error: "invalid_unit" }, status: :unprocessable_entity
    end
  end

  def unit_json(unit, include_active: false)
    json = { id: unit.id, name: unit.name, kind: unit.kind, cnes: unit.cnes, screening_scope: unit.screening_scope,
             collects_samples: unit.collects_samples, notifying: unit.notifying }
           .merge(unit.slice(*ADDRESS_FIELDS).symbolize_keys)
    json[:active] = unit.active if include_active
    json
  end
end
