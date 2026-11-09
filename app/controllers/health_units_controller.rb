# Cadastro de unidades de saúde (spec 2026-09-24-citizen-attendance-check-in
# §4, §6): leitura para citizen_verifier, health_professional e
# municipal_admin; escrita só para municipal_admin. ADR 0049 (contrato P9,
# P26, P27): o CAPS com modalidade e classificação, e o telefone da unidade,
# pelas mesmas rotas e sem step-up novo.
class HealthUnitsController < ApplicationController
  include Authentication
  include AttendanceAccess

  # Endereço da unidade (ADR 0023; spec 2026-09-28-module-11-territory §4.1).
  ADDRESS_FIELDS = %w[address_street address_number address_complement address_zip neighborhood_id].freeze

  before_action :require_unit_reader, only: %i[index]
  before_action :require_admin, only: %i[all create update deactivate activate drain]
  before_action :set_unit, only: %i[update deactivate activate drain]

  def index
    render json: { units: HealthUnit.active_units.includes(:ceo_profile).map { |u| unit_json(u) } }
  end

  # Para o admin: cada unidade com quantos pedidos vivos e horários marcados
  # ainda a prendem (o que "Esvaziar unidade" moveria; api#29).
  def all
    requests = AppointmentRequest.live_requests.group(:target_unit_id).count
    appointments = Appointment.live.group(:health_unit_id).count
    render json: { units: HealthUnit.includes(:ceo_profile).order(:name).map do |u|
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
            assign_collects_samples(unit) || assign_notifying(unit) || assign_caps(unit) || assign_phone(unit) ||
            assign_waiting_room(unit)
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
    # ADR 0046 (D10): o perfil do CEO nunca some; a unidade que o tem segue `ceo`.
    if @unit.kind_changed? && @unit.kind_was == "ceo" && @unit.ceo_profile
      return render json: { error: "unit_has_ceo_profile" }, status: :conflict
    end
    error = assign_address(@unit) || assign_cnes(@unit) || assign_screening_scope(@unit) ||
            assign_collects_samples(@unit) || assign_notifying(@unit) || assign_caps(@unit) || assign_phone(@unit) ||
            assign_waiting_room(@unit)
    return render(json: { error: error }, status: :unprocessable_entity) if error

    conflict = caps_change_conflict(@unit)
    return render json: { error: conflict }, status: :conflict if conflict
    return render_invalid(@unit) unless @unit.save

    render json: { unit: unit_json(@unit, include_active: true) }
  rescue ActiveRecord::RecordNotUnique => e
    render json: { error: e.message.include?("idx_health_units_cnes") ? "cnes_taken" : "unit_name_taken" },
           status: :unprocessable_entity
  end

  def deactivate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    # O interruptor `pharmacy` é lido ANTES da trava: Platform::Features abre
    # outra conexão e lê credenciais e perfil; um StatementInvalid resgatado
    # ali dentro abortaria a transação da unidade (500 em qualquer cidade).
    pharmacy = Pharmacy::Gate.usable?(Current.city)

    # FOR UPDATE na unidade: espera o check-in ou encaminhamento em curso
    # (HealthUnit.lock_active!) e só então confere o que está aberto.
    conflict = nil
    @unit.with_lock do
      conflict = deactivation_conflict(pharmacy:)
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

  def deactivation_conflict(pharmacy:)
    return "unit_has_open_attendances" if Attendance.open_attendances.where(health_unit: @unit).exists?

    return "unit_has_open_requests" if AppointmentRequest.live_requests.where(target_unit: @unit).exists?

    "pharmacy_pending" if pharmacy && pharmacy_pending?
  end

  # H14 (módulo 27a): a farmácia da unidade com transferência `sent` (origem
  # ou destino) ou ajuste `pending` prende a unidade ativa, senão o recebimento
  # ficaria em location_inactive para sempre. Só com o interruptor `pharmacy`
  # utilizável, lido pelo chamador antes da trava (deactivate). Roda sob o FOR
  # UPDATE da unidade: quem grava `sent`/`pending` toma FOR SHARE nela
  # (Pharmacy::Ledger.lock_location!), então uma leitura simples basta e
  # nenhum lote é travado depois da unidade.
  def pharmacy_pending?
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

  # ADR 0049 (contrato §3, P9): o CAPS sempre com a modalidade; a modalidade
  # e a classificação do serviço (3 dígitos do CNES) só no CAPS. Sem a chave,
  # o CAPS mantém o que tem; sair do CAPS limpa as duas; entrar no CAPS exige
  # a modalidade. Roda depois do kind atribuído. Classificação null ou ""
  # limpa (como o CNES).
  def assign_caps(unit)
    unless unit.caps?
      return "caps_modality_mismatch" if params["caps_modality"].present?
      return "invalid_service_classification" if params["service_classification"].present?

      unit.caps_modality = nil
      unit.service_classification = nil
      return nil
    end

    unit.caps_modality = params["caps_modality"] if params.key?("caps_modality")
    return "caps_modality_mismatch" unless HealthUnit::CAPS_MODALITIES.include?(unit.caps_modality)
    return nil unless params.key?("service_classification")

    value = params["service_classification"].presence
    return "invalid_service_classification" unless value.nil? || (value.is_a?(String) && value.match?(HealthUnit::SERVICE_CLASSIFICATION))

    unit.service_classification = value
    nil
  end

  # ADR 0049 (fix round 1 da Task 3), no padrão do unit_has_ceo_profile:
  # - CAPS com qualquer registro do CAPS não sai do kind `caps` (o registro
  #   ficaria numa unidade que não é CAPS);
  # - CAPS com leito ativo, ou com permanência noturna aberta (mesmo com o
  #   leito já desativado: a saída grava as noites e a crítica recusa a noite
  #   em CAPS sem leito — fix round 1 do P61), não passa a uma modalidade sem
  #   acolhimento noturno;
  # - unidade com histórico de atendimento (atendimento, e a consulta que nasce
  #   dele; horário marcado; pedido de agendamento) não vira CAPS: o nome dela
  #   já está no histórico do cidadão e passaria a ser o de um CAPS.
  def caps_change_conflict(unit)
    was_caps = unit.kind_was == "caps"
    if was_caps && !unit.caps?
      "unit_has_caps_records" if Psychosocial::UnitRecords.any?(unit.id)
    elsif was_caps && HealthUnit::NIGHT_MODALITIES.include?(unit.caps_modality_was) && !unit.night_capable?
      "caps_has_beds" if PsychosocialBed.where(health_unit_id: unit.id, active: true).exists? ||
                         PsychosocialNightStay.open_stays.where(health_unit_id: unit.id).exists?
    elsif !was_caps && unit.caps?
      "unit_has_attendances" if attendance_history?(unit)
    end
  end

  # Também a cobertura de bairro e o prestador próprio da regulação (P51): eles
  # levam pedidos da agenda automaticamente à unidade.
  def attendance_history?(unit)
    Attendance.where(health_unit_id: unit.id).or(Attendance.where(referral_unit_id: unit.id)).exists? ||
      Appointment.where(health_unit_id: unit.id).exists? ||
      AppointmentRequest.where(target_unit_id: unit.id).or(AppointmentRequest.where(origin_unit_id: unit.id)).exists? ||
      NeighborhoodCoverage.where(health_unit_id: unit.id).exists? || CareProvider.where(health_unit_id: unit.id).exists?
  end

  # Contrato P27: telefone da unidade, 10 ou 11 dígitos (a máscara sai na
  # normalização do modelo), ou nulo. Só muda quando a chave vem.
  def assign_phone(unit)
    return nil unless params.key?("phone")

    value = params["phone"]
    return "invalid_phone" unless value.nil? || value.is_a?(String)

    unit.phone = value
    unit.phone.nil? || unit.phone.match?(HealthUnit::PHONE) ? nil : "invalid_phone"
  end

  # Módulo 32a (contrato §1; Valor fixado 4): prefixo da senha (1 a 3 letras
  # maiúsculas) e tempos de espera na TV. Só mudam quando a chave vem; ausentes
  # na criação, o modelo decide (UPA: U/true; demais: A/false).
  def assign_waiting_room(unit)
    if params.key?("ticket_prefix")
      value = params["ticket_prefix"]
      return "invalid_ticket_prefix" unless value.is_a?(String) && value.match?(HealthUnit::TICKET_PREFIX)

      unit.ticket_prefix = value
    end
    return nil unless params.key?("show_wait_times")
    return "invalid_show_wait_times" unless [ true, false ].include?(params["show_wait_times"])

    unit.show_wait_times = params["show_wait_times"]
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

  def ceo_profile_json(profile)
    profile && { ceo_type: profile.ceo_type, specialties: profile.specialties }
  end

  def unit_json(unit, include_active: false)
    json = { id: unit.id, name: unit.name, kind: unit.kind, cnes: unit.cnes, screening_scope: unit.screening_scope,
             collects_samples: unit.collects_samples, notifying: unit.notifying, caps_modality: unit.caps_modality,
             service_classification: unit.service_classification, phone: unit.phone,
             ticket_prefix: unit.ticket_prefix, show_wait_times: unit.show_wait_times }
           .merge(unit.slice(*ADDRESS_FIELDS).symbolize_keys)
    json[:active] = unit.active if include_active
    json[:ceo_profile] = ceo_profile_json(unit.ceo_profile) if unit.kind == "ceo"
    json
  end
end
