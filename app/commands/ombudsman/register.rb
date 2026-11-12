# Registro de manifestação no canal web (ADR 0051; contrato §3; §16 U1, Q8,
# Q46; preflight F-1, F-3, F-18). Um caminho só de protocolo e evento para
# toda manifestação do canal web:
#
# - pela sessão do telefone (`citizen_session`): `identified | preserved`, com
#   o cidadão da sessão (`citizen:`, já conferido pelo controlador: 403
#   not_own_citizen) OU o par declarado `{ cpf, full_name }` — o par nasce (ou
#   é achado) por Citizens::RegisterPerson, sem consentimento nem perfil, e o
#   nome declarado vai a `manifestant_name`, nunca a `citizens.full_name` (o
#   nome conferido em documento, ADR 0031);
# - `anonymous_web: true` (só Ombudsman::RegisterAnonymous, Task 9): a
#   denúncia anônima, `report` + `anonymous`, sem pessoa e sem anexo.
#
# Tudo numa transação (savepoint quando há uma de fora): o par declarado, a
# trava do cidadão (FOR KEY SHARE, a ordem do Ombudsman::Lock e do
# Citizens::Erase), o protocolo, a manifestação `received`, o evento
# `received` visível, a ligação dos anexos da sessão (Attachments.link!, que
# consome os arquivos) e `ombudsman.manifestation_received` (só o id). Qualquer
# recusa desfaz tudo, inclusive o par declarado. Sem aviso: o cidadão já vê o
# protocolo. `now` vale para received_at, cycle_started_on e created_at. Nada
# do texto, do nome nem do CPF em erro ou log.
module Ombudsman
  module Register
    SESSION_MODES = %w[identified preserved].freeze
    ANONYMOUS_FORBIDDEN = %w[cpf full_name citizen_id attachment_ids].freeze

    module_function

    # -> Result.ok(manifestation:)
    #  | fail(:invalid_request, details: { path:, problems: }) | fail(:invalid_cpf, details: { path: "cpf", ... })
    #  | fail(:too_many_people) | fail(:too_many_attachments) | fail(:not_own_citizen)
    # O canal da equipe (in_person, phone, ouvidorsus) entra na Task 10.
    def call(attrs:, channel:, citizen: nil, citizen_session: nil, anonymous_web: false, now: Time.current)
      raise ArgumentError, "Ombudsman::Register: só o canal web por enquanto" unless channel == "web"
      raise ArgumentError, "Ombudsman::Register: a denúncia anônima não tem cidadão" if anonymous_web && citizen
      raise ArgumentError, "Ombudsman::Register: o canal web exige a sessão" unless anonymous_web || citizen_session

      attrs = attrs.to_h.stringify_keys
      form = anonymous_web ? anonymous_form(attrs) : session_form(attrs, citizen)
      return form if form.failure?

      persist(form.payload, attrs, citizen_session, now)
    end

    def session_form(attrs, citizen)
      identity = identity(attrs, citizen)
      return identity if identity.failure?

      common = common_form(attrs, SESSION_MODES)
      return common if common.failure?

      Result.ok(identity.payload.merge(common.payload))
    end

    def anonymous_form(attrs)
      present = ANONYMOUS_FORBIDDEN.find { |key| !attrs[key].nil? }
      return refuse(present) if present
      return refuse("kind") unless attrs["kind"] == "report"

      common_form(attrs, %w[anonymous])
    end

    # Exatamente um: o cidadão da sessão ou `{ cpf, full_name }`.
    def identity(attrs, citizen)
      cpf_given = !attrs["cpf"].nil?
      return refuse("cpf") if citizen && cpf_given
      return refuse("full_name") if !attrs["full_name"].nil? && !cpf_given
      return Result.ok(citizen: citizen) if citizen
      return refuse("citizen_id") unless cpf_given

      digits = attrs["cpf"].is_a?(String) ? CitizenIdentity::Cpf.normalize(attrs["cpf"]) : nil
      return refuse("cpf", :invalid_cpf) unless digits

      name = Input.text(attrs["full_name"], Catalog::MANIFESTANT_NAME)
      return refuse("full_name") unless name

      Result.ok(cpf: digits, manifestant_name: name)
    end

    def common_form(attrs, modes)
      return refuse("kind") unless Catalog::KINDS.include?(attrs["kind"])
      return refuse("identification_mode") unless modes.include?(attrs["identification_mode"])

      body = Input.text(attrs["body"], Catalog::BODY)
      return refuse("body") unless body

      unit_id = attrs["health_unit_id"]
      unless unit_id.nil?
        valid = unit_id.is_a?(String) && unit_id.match?(BaseController::UUID) && HealthUnit.active_units.exists?(id: unit_id)
        return refuse("health_unit_id") unless valid
      end

      Result.ok(kind: attrs["kind"], identification_mode: attrs["identification_mode"], body: body, health_unit_id: unit_id)
    end

    def persist(form, attrs, citizen_session, now)
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        person = person!(form, citizen_session)
        if person.failure?
          result = person
          raise ActiveRecord::Rollback
        end

        citizen = person.payload[:citizen]
        manifestation = OmbudsmanManifestation.create!(
          protocol: OmbudsmanManifestation.next_protocol(now), kind: form[:kind], identification_mode: form[:identification_mode],
          channel: "web", citizen: citizen, manifestant_name: form[:manifestant_name], body: form[:body],
          referred_health_unit_id: form[:health_unit_id], state: "received", cycle: 1, received_at: now,
          cycle_started_on: now.in_time_zone.to_date, created_at: now, updated_at: now
        )
        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "received", actor: "citizen",
                               visible_to_citizen: true, created_at: now)
        if citizen_session
          linked = Attachments.link!(ids: attrs["attachment_ids"], manifestation: manifestation, owner: citizen_session)
          if linked.failure?
            result = linked
            raise ActiveRecord::Rollback
          end
        end
        DomainEvents.publish("ombudsman.manifestation_received", manifestation_id: manifestation.id)
        result = Result.ok(manifestation: manifestation)
      end
      result
    end

    # O cidadão da manifestação, travado FOR KEY SHARE (a exclusão LGPD trava
    # FOR UPDATE e espera); o par declarado nasce antes da trava. A lápide
    # (excluído no intervalo) → not_own_citizen. A denúncia anônima não tem.
    def person!(form, citizen_session)
      citizen = form[:citizen]
      if form[:cpf]
        pair = Citizens::RegisterPerson.call(phone: citizen_session.phone, cpf: form[:cpf])
        return pair if pair.failure?

        citizen = pair.payload.fetch(:citizen)
      end
      return Result.ok(citizen: nil) unless citizen

      locked = Citizen.lock("FOR KEY SHARE").where(erased_at: nil).find_by(id: citizen.id)
      locked ? Result.ok(citizen: locked) : Result.fail(:not_own_citizen)
    end

    def refuse(path, error = :invalid_request)
      Result.fail(error, details: { path: path, problems: [ { error: error.to_s, path: path } ] })
    end

    private_class_method :session_form, :anonymous_form, :identity, :common_form, :persist, :person!, :refuse
  end
end
