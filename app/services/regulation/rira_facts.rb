module Regulation
  # Fatos do documento RIRA de um pedido de regulação (módulo 26c; Valor 8, Q6,
  # Q12, Q15, Q18). TODA leitura de banco do documento mora aqui: o RiraBundle,
  # o RiraSkeleton e a RndsValidation são puros sobre estes fatos. Um fato
  # ausente fica nulo, nunca levanta (pré-voo I9): o esqueleto e a conferência
  # é que acusam.
  #
  # - Paciente: CPF e CNS do paciente do pedido.
  # - `requester_cnes`: CNES da unidade solicitante; `author_cnes` e
  #   `requester_id`: da credencial `rnds_regulation` (nula → nulos).
  # - SIGTAP: alvo `procedure` → o próprio código; `specialty` →
  #   `settings.specialty_sigtap[CBO] || DEFAULT_SIGTAP`. `sigtap_valid` (Q9,
  #   pré-voo M16): só no alvo `specialty`, o SIGTAP resolvido precisa passar no
  #   `CareRegulation::Targets.resolve` da competência de hoje.
  # - Executante: rede própria → CNES da unidade do horário vivo/último da
  #   cadeia (ou da unidade do prestador); externo → CNES do prestador (da
  #   oferta da autorização vigente, ou `care_provider_id` do pedido).
  # - CBO do executante (Q12), nesta ordem: o CBO do alvo `specialty`; o CBO do
  #   vínculo do turno do horário (rede própria); o `performer_cbo` da oferta;
  #   o `default_performer_cbo` do prestador.
  # - Caráter (Q15, pré-voo B4): `settings.priority_by_color[effective_color]`
  #   (`color || suggested_color`); sem cor, nulo.
  # - `scheduled_at` e `scheduled_ends_at` (Q20): rede própria → o horário
  #   vivo/último da cadeia (fim = `effective_ends_at`; legado, +15 min) ou o
  #   do pedido; externo → o do pedido, com fim em `+ Appointment::LEGACY_SPAN`.
  # - `absences` (Q18, Q22, Q24): uma `Slot(starts_at, ends_at, cnes,
  #   missed_at)` por linha `missed` do andamento, na ordem. A rede é a do
  #   horário faltado, não a da autorização vigente:
  #   - rede própria: o horário `no_show` da cadeia com a data da linha (ou, na
  #     linha sem data — falta de antes da Q24 —, o último `no_show` ainda não
  #     usado até ela): datas do horário e CNES da unidade dele;
  #   - externo: a data, o fim e o prestador gravados na linha (sem fim, a
  #     data + LEGACY_SPAN; CNES do prestador);
  #   - linha sem data e sem `no_show` (falta externa de antes da Q24): sem
  #     horário (a conferência barra com `external_absence_without_schedule`).
  #   O `expired` não é falta (volta a `authorized` no 26a).
  # - `status_times`: { situação MIRA => instante da última linha do andamento
  #   que leva a ela } (a `pending` cai no `requested_at` sem linha).
  #
  # Dado sensível (CPF, CNS, CID, CIAP, identificador do solicitante): nunca
  # sai em inspect, to_s, pretty_print nem as_json.
  RiraFacts = Data.define(
    :patient_cpf, :patient_cns, :requester_cnes, :author_cnes, :requester_id, :target_type, :target_code,
    :sigtap, :sigtap_valid, :performer_cnes, :performer_cbo, :priority, :cid10, :ciap2, :requested_at,
    :authorized_at, :scheduled_at, :scheduled_ends_at, :absences, :status_times, :own_network
  )

  class RiraFacts
    ACTIVE_APPOINTMENTS = %w[scheduled confirmed checked_in].freeze
    MISSED_APPOINTMENT = "no_show".freeze
    # Um horário faltado: datas e o CNES da unidade dele (executante da falta).
    # `missed_at`: o instante da linha `missed` (padrão: o início do horário).
    Slot = Data.define(:starts_at, :ends_at, :cnes, :missed_at) do
      def initialize(starts_at:, ends_at:, cnes:, missed_at: starts_at)
        super(starts_at: starts_at, ends_at: ends_at, cnes: cnes, missed_at: missed_at)
      end
    end
    # andamento da 26a => situação MIRA (a mesma tabela do RndsStatus; `closed`
    # depende das faltas).
    EVENT_STATUS = RndsStatus::RULES.values.each_with_object({ "missed" => RndsStatus::ABSENCE }) do |(mira, events), map|
      events.each { |event| map[event] = mira }
    end.freeze

    def self.for(request:, settings:, credential:, today: Time.zone.today)
      authorization = request.current_authorization
      offer = authorization&.care_offer
      provider = offer&.care_provider || request.care_provider
      own = !request.state_regulated && (provider.nil? || provider.kind == "own")
      appointments = chain_appointments(request)
      current = own ? appointments.select { |a| ACTIVE_APPOINTMENTS.include?(a.status) }.last : nil
      sigtap = sigtap_for(request, settings)
      patient = request.patient
      scheduled_at = (own && current&.scheduled_at) || request.scheduled_at
      ends_at = own && current ? current.effective_ends_at : scheduled_at && scheduled_at + Appointment::LEGACY_SPAN

      new(
        patient_cpf: patient&.cpf.presence, patient_cns: patient&.cns.presence,
        requester_cnes: request.requester_unit&.cnes.presence,
        author_cnes: credential&.requester_cnes.presence, requester_id: credential&.requester_id.presence,
        target_type: request.target_type, target_code: request.target_code,
        sigtap: sigtap, sigtap_valid: request.target_type != "specialty" || regulable?(sigtap, today),
        performer_cnes: current&.health_unit&.cnes.presence || provider&.cnes.presence,
        performer_cbo: performer_cbo(request, current, offer, provider),
        priority: request.effective_color && (settings.priority_by_color || {})[request.effective_color].presence,
        cid10: request.cid10.presence, ciap2: request.ciap2.presence,
        requested_at: request.requested_at, authorized_at: authorization&.created_at,
        scheduled_at: scheduled_at, scheduled_ends_at: ends_at,
        absences: absences(request, appointments),
        status_times: status_times(request).freeze, own_network: own
      )
    end

    # Os horários de todas as cadeias do pedido (cada autorização abre uma; o
    # Drain copia a origem), do mais antigo ao mais novo, sem empate pelo uuid.
    def self.chain_appointments(request)
      Appointment.joins(:request).where(appointment_requests: { origin_regulation_request_id: request.id })
                 .includes(:health_unit, shift: :professional_link)
                 .order(:scheduled_at, :created_at, :id).to_a
    end

    def self.absences(request, appointments)
      no_shows = appointments.select { |a| a.status == MISSED_APPOINTMENT }.sort_by(&:scheduled_at)
      used = []
      request.events.select { |e| e.status == "missed" }.filter_map do |row|
        appointment = if row.scheduled_at
                        no_shows.find { |a| a.scheduled_at == row.scheduled_at }
                      else
                        (no_shows - used).select { |a| a.scheduled_at <= row.created_at }.last
                      end
        if appointment
          used << appointment
          Slot.new(starts_at: appointment.scheduled_at, ends_at: appointment.effective_ends_at,
                   cnes: appointment.health_unit&.cnes.presence, missed_at: row.created_at)
        elsif row.scheduled_at
          Slot.new(starts_at: row.scheduled_at, ends_at: row.ends_at || row.scheduled_at + Appointment::LEGACY_SPAN,
                   cnes: row.care_provider&.cnes.presence, missed_at: row.created_at)
        end
      end.freeze
    end

    def self.sigtap_for(request, settings)
      return request.target_code if request.target_type == "procedure"

      (settings.specialty_sigtap || {})[request.target_code].presence || RndsLimits::DEFAULT_SIGTAP
    end

    def self.regulable?(sigtap, today) = CareRegulation::Targets.resolve(type: "procedure", code: sigtap, on: today).ok?

    def self.performer_cbo(request, current, offer, provider)
      return request.target_code if request.target_type == "specialty"

      current&.shift&.professional_link&.cbo_code.presence || offer&.performer_cbo.presence ||
        provider&.default_performer_cbo.presence
    end

    def self.status_times(request)
      request.events.each_with_object({}) do |event, times|
        status = if event.status == "closed"
                   request.misses >= CareRegulation::Catalog::MAX_MISSES ? RndsStatus::ABSENCE : "cancelled"
                 else
                   EVENT_STATUS[event.status]
                 end
        times[status] = event.created_at if status && (times[status].nil? || event.created_at > times[status])
      end.tap { |times| times["pending"] ||= request.requested_at if request.requested_at }
    end
    private_class_method :chain_appointments, :absences, :sigtap_for, :regulable?, :performer_cbo, :status_times

    def inspect = "#<Regulation::RiraFacts [FILTERED]>"
    def to_s = inspect
    def pretty_print(pp) = pp.text(inspect)
    def as_json(*) = { "target_type" => target_type, "own_network" => own_network }
  end
end
