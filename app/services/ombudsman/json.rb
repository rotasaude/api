# Formas JSON da equipe da ouvidoria (ADR 0051; contrato §5, §8; Q4, Q24, Q34).
# O texto da manifestação, dos eventos e dos encaminhamentos só sai no
# detalhe (staff/ouvidor); a identidade segue a regra do §8: só no modo
# `identified`, nos demais "preserved" — nem o ouvidor a recebe fora de
# POST .../identity. Nada de filename dos anexos (Q2): a tela diz "Anexo N".
# Datas e instantes em ISO 8601.
module Ombudsman
  module Json
    module_function

    PRESERVED = "preserved".freeze
    # O que list_item e detail leem, carregado de uma vez (sem N+1).
    LIST_PRELOAD = [ :referred_health_unit, { subject: :parent } ].freeze
    DETAIL_PRELOAD = [
      *LIST_PRELOAD, :citizen, :referred_professional, :duplicate_of, :attachments, :reopen_requests,
      { events: :actor_user, forwardings: %i[department health_unit replied_by_user] }
    ].freeze

    # Item da caixa. `pending_counts`: { manifestation_id => encaminhamentos pending }.
    def list_item(manifestation, settings, today, pending_counts)
      {
        id: manifestation.id, protocol: manifestation.protocol, kind: manifestation.kind,
        identification_mode: manifestation.identification_mode, channel: manifestation.channel, state: manifestation.state,
        subject: subject(manifestation.subject), health_unit: unit(manifestation.referred_health_unit), urgent: manifestation.urgent,
        received_at: manifestation.received_at.iso8601, due_on: Deadlines.due_on(manifestation, settings, today: today).iso8601,
        color: Deadlines.color(manifestation, settings, today: today), pending_forwardings: pending_counts.fetch(manifestation.id, 0)
      }
    end

    # Detalhe da manifestação para a equipe (toda ação de equipe responde com ele, Q32).
    # `reopen_request`: só o pedido PENDENTE (nulo sem pedido a decidir). `can`:
    # as ações que este usuário pode fazer agora (o dashboard não adivinha).
    def detail(manifestation, viewer:, settings:, today:)
      pending = manifestation.forwardings.count(&:pending?)
      pending_reopen = manifestation.reopen_requests.find { |request| request.state == "pending" }
      list_item(manifestation, settings, today, { manifestation.id => pending }).merge(
        body: manifestation.body, ouvidorsus_number: manifestation.ouvidorsus_number,
        referred_professional: professional(manifestation.referred_professional), cycle: manifestation.cycle,
        extended: manifestation.extended, extension_reason: manifestation.extension_reason,
        complement_used: manifestation.complement_used, complement_requested_at: manifestation.complement_requested_at&.iso8601,
        complement_due_on: Deadlines.complement_due_on(manifestation, settings)&.iso8601,
        resolution: manifestation.resolution, archive_reason: manifestation.archive_reason,
        duplicate_of: duplicate_of(manifestation.duplicate_of), external_body_name: manifestation.external_body_name,
        concluded_at: manifestation.concluded_at&.iso8601,
        identity: identity(manifestation), identity_available: identity_available?(manifestation),
        events: manifestation.events.map { |e| event(e) },
        forwardings: manifestation.forwardings.map { |f| forwarding(f, settings, today) },
        attachments: manifestation.attachments.map { |a| attachment(a) },
        reopen_request: reopen_request(pending_reopen),
        can: can(manifestation, viewer, pending: pending, pending_reopen: pending_reopen.present?)
      )
    end

    # Ações do §2 (e as da identidade, §8) permitidas ao usuário no estado. A
    # regra que o comando de cada ação confere de novo sob a trava; aqui só o
    # que se sabe pelos dados (papel, estado, ciclo, modo, pendências).
    # `open_identity` / `record_identity_consent`: o ouvidor, quando há alguém
    # a revelar (identity_available; a anônima nunca).
    def can(manifestation, viewer, pending:, pending_reopen:)
      staff = Access.staff?(viewer)
      ombudsman = Access.ombudsman?(viewer)
      state = manifestation.state
      person = !manifestation.anonymous?
      available = identity_available?(manifestation)
      {
        classify: staff && %w[received in_analysis].include?(state),
        forward: staff && %w[in_analysis forwarded].include?(state),
        cancel_forwarding: staff && pending.positive?,
        request_complement: staff && state == "in_analysis" && !manifestation.complement_used && person,
        complement: staff && state == "awaiting_complement",
        extend: ombudsman && %w[in_analysis forwarded awaiting_complement].include?(state) && !manifestation.extended,
        interim_response: staff && manifestation.open? && person,
        final_response: staff && state == "in_analysis" && pending.zero?,
        archive: ombudsman && %w[received in_analysis awaiting_complement].include?(state),
        reopen: ombudsman && manifestation.final?,
        change_resolution: ombudsman && state == "answered" && Catalog::RESOLUTION_KINDS.include?(manifestation.kind),
        decide_reopen: ombudsman && pending_reopen,
        open_identity: ombudsman && available,
        record_identity_consent: ombudsman && available
      }
    end

    # Linha do tempo da equipe (Q4): actor_name só para o técnico/ouvidor; o
    # cidadão e o sistema não têm nome (o JSON do cidadão nunca leva actor).
    def event(event)
      json = { id: event.id, kind: event.kind, actor: event.actor,
               actor_name: (event.actor == "staff" ? Screenings::Json.staff_name(event.actor_user) : nil),
               at: event.created_at.iso8601, data: event.data, visible_to_citizen: event.visible_to_citizen }
      json[:text] = event.text if event.text.present?
      json
    end

    def forwarding(forwarding, settings, today)
      json = {
        id: forwarding.id, destination: destination(forwarding), extract: forwarding.extract, state: forwarding.state,
        due_on: forwarding.due_on.iso8601, color: Deadlines.forwarding_color(forwarding, settings, today: today),
        extended: forwarding.extended, created_at: forwarding.created_at.iso8601
      }
      json[:extension_reason] = forwarding.extension_reason if forwarding.extension_reason.present?
      if forwarding.reply.present?
        json[:reply] = forwarding.reply
        json[:replied_at] = forwarding.replied_at&.iso8601
        json[:replied_by_name] = Screenings::Json.staff_name(forwarding.replied_by_user)
      end
      json
    end

    # Q34: { id, name, parent: { id, name } | null } — o subassunto leva o pai.
    def subject(subject)
      return nil unless subject

      parent = subject.parent
      { id: subject.id, name: subject.name, parent: parent && { id: parent.id, name: parent.name } }
    end

    # Q34: { kind: "department" | "health_unit", id, name }.
    def destination(forwarding)
      if forwarding.department_id
        { kind: "department", id: forwarding.department_id, name: forwarding.department.name }
      else
        { kind: "health_unit", id: forwarding.health_unit_id, name: forwarding.health_unit.name }
      end
    end

    # Q2: só { id, uploaded_by } — nunca o nome do arquivo.
    def attachment(attachment) = { id: attachment.id, uploaded_by: attachment.uploaded_by }

    # Q24 (ruling): há alguém a revelar — cidadão ligado ou qualquer manifestant_*.
    def identity_available?(manifestation)
      manifestation.citizen_id.present? ||
        [ manifestation.manifestant_name, manifestation.manifestant_contact, manifestation.manifestant_cpf ].any?(&:present?)
    end

    # §8: só `identified` mostra a identidade (CPF e telefone mascarados);
    # preserved e anonymous → "preserved" (nenhum nome, CPF, telefone, contato).
    def identity(manifestation)
      return PRESERVED unless manifestation.identification_mode == "identified"

      citizen = manifestation.citizen
      name = manifestation.manifestant_name.presence || citizen&.display_name
      return { name: name, cpf_masked: citizen.cpf_masked, phone_masked: CitizenIdentity::Phone.mask(citizen.phone) } if citizen

      { name: name, cpf_masked: mask_cpf(manifestation.manifestant_cpf), phone_masked: nil, contact: manifestation.manifestant_contact }
    end

    def mask_cpf(value)
      digits = value.to_s.gsub(/\D/, "")
      digits.present? ? CitizenIdentity::Cpf.mask(digits) : nil
    end

    def unit(unit) = unit && { id: unit.id, name: unit.name }
    def professional(professional) = professional && { id: professional.id, name: professional.professional_name }
    def duplicate_of(other) = other && { id: other.id, protocol: other.protocol }

    def reopen_request(request)
      return nil unless request

      json = { id: request.id, cycle: request.cycle, state: request.state, reason: request.reason,
               created_at: request.created_at.iso8601 }
      json[:decision_text] = request.decision_text if request.decision_text.present?
      json[:decided_at] = request.decided_at.iso8601 if request.decided_at
      json
    end

    # POST .../identity (§8): a identidade completa, só para o ouvidor, depois
    # da trilha. `name` segue a regra do U1 (o nome declarado vale sobre o do
    # cidadão); CPF e telefone do cidadão sem máscara; os três manifestant_*.
    def full_identity(manifestation)
      citizen = manifestation.citizen
      { name: manifestation.manifestant_name.presence || citizen&.display_name, cpf: citizen&.cpf, phone: citizen&.phone,
        manifestant_name: manifestation.manifestant_name, manifestant_contact: manifestation.manifestant_contact,
        manifestant_cpf: manifestation.manifestant_cpf }
    end

    private_class_method :mask_cpf, :unit, :professional, :duplicate_of, :reopen_request
  end
end
