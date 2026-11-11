# Entrada e troca de leito na observação da UPA (ADR 0050; contrato §4 e §10;
# plano, Desvio 1).
#
# Quem: só quem tem acesso clínico na UPA (Access.clinical_link: enfermagem
# 2235* ou médico 225*); os demais → Access.refusal (missing_role |
# missing_link | cbo_not_allowed — o técnico 3222 lê o mapa, mas não põe no
# leito). `bed_id` malformado ou ausente → 422 invalid_request `bed_id`.
#
# Numa transação, na ordem de trava das escritas clínicas da urgência:
# atendimento FOR SHARE → encontro FOR NO KEY UPDATE → estadia aberta do
# encontro FOR UPDATE → leito FOR SHARE (o cadastro trava o leito FOR UPDATE
# para desativar, Urgency::SaveBed: a desativação espera a entrada, ou é vista
# por ela). Sob as travas: encontro ou atendimento fechado → 409
# encounter_closed; fora de `in_care` → 422 not_in_care; leito inexistente,
# inativo ou de outra unidade → 422 bed_unavailable `bed_id`; o mesmo leito da
# estadia aberta → 422 invalid_request `bed_id`; leito ocupado → 409 bed_taken
# (o Ruby confere antes; a exclusion `excl_urgency_bed_stays_bed` e o índice
# `idx_urgency_bed_stays_open_encounter` são a rede contra a corrida, e viram
# bed_taken).
#
# Sem estadia aberta, é a entrada: abre a estadia em `now` e publica
# `urgency.observation_started`. Com estadia aberta, é a troca: fecha a atual
# com `bed_change` e abre a nova no MESMO `now` (o tsrange meio-aberto não
# sobrepõe), publicando `urgency.observation_ended` (a velha) e
# `urgency.observation_started` (a nova). Os eventos levam só encounter_id e
# stay_id.
#
# Q15 (tela desatualizada): `expected_stay_id` declara o que a tela viu —
# `nil` = entrada (nenhuma estadia aberta), um id = troca a partir daquela
# estadia aberta. Conferido sob a trava do encontro, antes do leito: se não
# bater com a estadia aberta → 409 observation_changed e nada é gravado. Sem a
# chave (`ABSENT`), vale a regra antiga; malformado → 422 invalid_request
# `expected_stay_id`.
module Urgency
  module StartObservation
    BED_EXCLUSION = "excl_urgency_bed_stays_bed".freeze
    OPEN_INDEX = "idx_urgency_bed_stays_open_encounter".freeze
    ABSENT = Object.new.freeze

    module_function

    # -> Result.ok(stay:, ended:) | fail(:missing_role | :missing_link | :cbo_not_allowed | :encounter_closed |
    #    :not_in_care | :bed_taken | :observation_changed) | fail(:invalid_request | :bed_unavailable, details: { path: "bed_id" })
    #    | fail(:invalid_request, details: { path: "expected_stay_id" })
    def call(encounter:, bed_id:, by:, now: Time.current, expected_stay_id: ABSENT)
      unit_id = encounter.attendance.health_unit_id
      return Result.fail(Access.refusal(by, unit_id)) unless Access.clinical_link(by, unit_id)
      return refuse unless Input.uuid?(bed_id)
      return refuse(:invalid_request, "expected_stay_id") unless expected_stay_id.equal?(ABSENT) || expected_stay_id.nil? ||
                                                                Input.uuid?(expected_stay_id)

      expected = expected_stay_id.is_a?(String) ? expected_stay_id.downcase : expected_stay_id
      ApplicationRecord.transaction(requires_new: true) { start(encounter, bed_id.downcase, by, now, expected) }
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.include?(BED_EXCLUSION) || e.message.include?(OPEN_INDEX)

      Result.fail(:bed_taken)
    end

    def start(encounter, bed_id, by, now, expected)
      attendance = Attendance.lock("FOR SHARE").find(encounter.attendance_id)
      locked = UrgencyEncounter.lock("FOR NO KEY UPDATE").find(encounter.id)
      return Result.fail(:encounter_closed) if locked.closed? || attendance.status == "closed"
      return Result.fail(:not_in_care) unless locked.state == "in_care" && attendance.status == "in_care"

      current = UrgencyBedStay.open_stays.lock.find_by(urgency_encounter_id: locked.id)
      return Result.fail(:observation_changed) unless expected.equal?(ABSENT) || current&.id == expected
      bed = UrgencyBed.lock("FOR SHARE").find_by(id: bed_id)
      return refuse(:bed_unavailable) unless bed&.active && bed.health_unit_id == attendance.health_unit_id
      return refuse if current&.urgency_bed_id == bed.id
      return Result.fail(:bed_taken) if occupied?(bed.id, now)

      if current
        current.update!(ended_at: now, end_kind: "bed_change", ended_by_user: by)
        DomainEvents.publish("urgency.observation_ended", encounter_id: locked.id, stay_id: current.id)
      end
      stay = UrgencyBedStay.create!(urgency_encounter: locked, urgency_bed: bed, health_unit_id: attendance.health_unit_id,
                                    started_at: now, started_by_user: by)
      DomainEvents.publish("urgency.observation_started", encounter_id: locked.id, stay_id: stay.id)
      Result.ok(stay: stay, ended: current)
    end

    # A conferência do Ruby antes da rede do banco: o leito com estadia que
    # ainda não acabou em `now` (a nova fica aberta: [now, ∞)).
    def occupied?(bed_id, now)
      UrgencyBedStay.where(urgency_bed_id: bed_id).where("ended_at IS NULL OR ended_at > ?", now).exists?
    end

    def refuse(error = :invalid_request, path = "bed_id")
      Result.fail(error, details: { path: path, problems: [ { path: path, error: error.to_s } ] })
    end

    private_class_method :start, :occupied?, :refuse
  end
end
