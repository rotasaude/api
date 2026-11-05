# Formas JSON do CAPS (ADR 0049; contrato §2). Nunca CPF; o CNS só mascarado
# e só dentro do CAPS. Texto clínico nunca em lista (cada task o acrescenta só
# nos detalhes).
module Psychosocial
  module Json
    module_function

    # <patient-ref>: { patient_id, name, cns_masked }; fora do CAPS (caps:
    # false) só { patient_id, name }.
    def patient_ref(patient, caps: true)
      ref = { "patient_id" => patient.id, "name" => patient.display_name }
      caps ? ref.merge("cns_masked" => patient.cns_masked) : ref
    end

    # <pro>: { user_id, name, cbo_code } — o CBO do vínculo no CAPS (ou o gravado na ação).
    def pro(user, cbo_code)
      { "user_id" => user.id, "name" => Screenings::Json.staff_name(user), "cbo_code" => cbo_code }
    end

    # <sigtap>: { code, name, instrument } com o nome da SIGTAP da competência
    # ("YYYYMM" ou a data do mês); sem release ou sem o código, nome "".
    def sigtap(code, instrument, competence, cache: Billing::SigtapCache.new)
      competence = competence.strftime("%Y%m") if competence.respond_to?(:strftime)
      release = cache.release(competence)
      name = release && cache.procedure(release, code)&.name
      { "code" => code, "name" => name.to_s, "instrument" => instrument }
    end

    # <bed> (contrato §3).
    def bed(bed)
      { "id" => bed.id, "health_unit_id" => bed.health_unit_id, "label" => bed.label, "active" => bed.active }
    end

    # O CAPS nas listas (GET /psychosocial/units).
    def unit(unit)
      { "id" => unit.id, "name" => unit.name, "caps_modality" => unit.caps_modality, "night_capable" => unit.night_capable? }
    end

    def time(value) = value&.in_time_zone&.iso8601
    # Hora do dia da grade ("HH:MM"), sem fuso.
    def hour(value) = value&.strftime("%H:%M")
    def date(value) = value&.iso8601

    # Resposta da escrita da UBS (POST /psychosocial/referrals): sem o paciente
    # nem o motivo (quem escreveu já os tem).
    def referral_created(referral)
      { "id" => referral.id, "health_unit_id" => referral.health_unit_id, "priority" => referral.priority, "status" => referral.status,
        "created_at" => time(referral.created_at) }
    end

    # Encaminhamento na fila do CAPS (contrato §4): nunca o motivo.
    def referral_item(referral)
      { "id" => referral.id, "patient" => patient_ref(referral.patient), "priority" => referral.priority, "status" => referral.status,
        "from_unit" => { "id" => referral.from_health_unit_id, "name" => referral.from_health_unit.name },
        "created_at" => time(referral.created_at) }
    end

    # Detalhe (com o motivo; quem lê grava a trilha). Quem encaminhou sem CBO:
    # o encaminhamento não guarda o vínculo.
    def referral(referral)
      referral_item(referral).merge(
        "reason" => referral.reason, "received_at" => time(referral.received_at),
        "referred_by" => { "user_id" => referral.referred_by_user_id, "name" => Screenings::Json.staff_name(referral.referred_by_user) }
      )
    end

    # Matrícula na lista (contrato §4): sem CID, substância, origem ou ESF.
    # cbos: { user_id => CBO no CAPS }; review_on: a revisão do PTS vigente.
    def enrollment_item(enrollment, cbos:, review_on: nil)
      { "id" => enrollment.id, "patient" => patient_ref(enrollment.patient), "started_on" => date(enrollment.started_on),
        "reference" => pro(enrollment.reference_user, cbos[enrollment.reference_user_id]),
        "next_visit_at" => time(enrollment.next_visit_at), "status" => enrollment.open? ? "open" : "closed",
        "care_plan_review_on" => date(review_on) }
    end

    # Detalhe (quem lê grava a trilha; a escrita devolve o mesmo, sem trilha).
    def enrollment(enrollment, cbos:, review_on: nil)
      enrollment_item(enrollment, cbos: cbos, review_on: review_on).merge(
        "health_unit_id" => enrollment.health_unit_id, "origin" => enrollment.origin, "cid_main" => enrollment.cid_main,
        "cid_secondary" => enrollment.cid_secondary || [], "substances" => enrollment.substances || [],
        "esf_covered" => enrollment.esf_covered, "esf_cnes" => enrollment.esf_cnes, "closed_on" => date(enrollment.closed_on),
        "destination" => enrollment.destination, "reception_id" => enrollment.psychosocial_reception_id,
        "created_at" => time(enrollment.created_at)
      )
    end

    # Versão do PTS (contrato §4): texto clínico, só no detalhe da matrícula
    # (quem lê grava a trilha). cbos: { user_id => CBO no CAPS }.
    def care_plan(plan, cbos:)
      { "id" => plan.id, "version" => plan.version, "needs" => plan.needs,
        "goals" => (plan.goals || []).map { |goal| goal.slice("text", "responsible_user_id", "due_on") },
        "intensity" => plan.intensity, "review_on" => date(plan.review_on),
        "created_by" => pro(plan.created_by_user, cbos[plan.created_by_user_id]), "created_at" => time(plan.created_at) }
    end

    # Revisão vencida (care_plans/due): sem texto clínico; review_on nulo = sem PTS.
    def care_plan_due(enrollment, review_on)
      { "enrollment_id" => enrollment.id, "patient" => patient_ref(enrollment.patient), "review_on" => date(review_on) }
    end

    # Grupo da grade (contrato §4): sem texto clínico. cbos: { user_id => CBO no CAPS }.
    def group(group, cbos:)
      { "id" => group.id, "health_unit_id" => group.health_unit_id, "name" => group.name, "kind" => group.kind,
        "weekday" => group.weekday, "starts_at" => hour(group.starts_at), "ends_at" => hour(group.ends_at),
        "responsible" => pro(group.responsible_user, cbos[group.responsible_user_id]), "capacity" => group.capacity,
        "sigtap_code" => group.sigtap_code, "active" => group.active }
    end

    # Ação na lista (contrato §4): sem notas, sem participantes nominais.
    # count: participantes da ação; cache: a SIGTAP memorizada da chamada.
    def action_item(action, count:, cache: Billing::SigtapCache.new)
      { "id" => action.id, "sigtap" => sigtap(action.sigtap_code, action.instrument, action.month, cache: cache),
        "instrument" => action.instrument, "performed_at" => time(action.performed_at), "place" => action.place,
        "quantity" => action.quantity, "professional" => pro(action.professional_user, action.cbo_code),
        "group_id" => action.psychosocial_group_id, "participants_count" => count, "cancelled" => action.cancelled? }
    end

    # Detalhe (com as notas e os participantes; quem lê grava a trilha):
    # `{ enrollment_id, patient: <patient-ref> }` ou `{ family_name }`.
    def action(action, cache: Billing::SigtapCache.new)
      participants = action.psychosocial_action_participants.to_a
      action_item(action, count: participants.size, cache: cache).merge(
        "health_unit_id" => action.health_unit_id, "month" => action.month.strftime("%Y-%m"), "origin" => action.origin,
        "notes" => action.notes, "authorization_number" => action.authorization_number,
        "participants" => participants.map { |p| action_participant(p) },
        "cancelled_at" => time(action.cancelled_at), "cancel_reason" => action.cancel_reason, "created_at" => time(action.created_at)
      )
    end

    # Permanência no mapa de leitos (contrato §5): o ocupante só como
    # <patient-ref>, nada clínico, sem trilha; `ended_at` (P61) é null enquanto
    # aberta — a encerrada que cobre a noite da data aparece com a saída.
    def board_stay(stay)
      { "id" => stay.id, "patient" => patient_ref(stay.patient), "started_at" => time(stay.started_at),
        "expected_end_at" => time(stay.expected_end_at), "ended_at" => time(stay.ended_at) }
    end

    # Detalhe da permanência (quem lê grava a trilha `night_stay`), com as
    # noites (Desvio 1; P62: a aberta além do previsto até a noite de hoje), os
    # motivos da saída e da reavaliação.
    # cbos: { user_id => CBO no CAPS }.
    def night_stay(stay, cbos:)
      by = ->(user) { user && pro(user, cbos[user.id]) }
      reassessment = stay.reassessment_reason && { "reason" => stay.reassessment_reason, "by" => by.call(stay.reassessed_by_user) }
      board_stay(stay).merge(
        "health_unit_id" => stay.health_unit_id, "bed" => bed(stay.psychosocial_bed), "enrollment_id" => stay.psychosocial_enrollment_id,
        "ended_at" => time(stay.ended_at), "end_reason" => stay.end_reason, "nights" => NightLimit.nights(stay).map { |night| date(night) },
        "reassessment" => reassessment, "started_by" => by.call(stay.started_by_user), "closed_by" => by.call(stay.closed_by_user),
        "created_at" => time(stay.created_at)
      )
    end

    # RAAS do mês do CAPS (GET /psychosocial/months/:month; contrato §6, P24):
    # situação (open | closed | exported), o fechamento ativo, os contadores e
    # os registros da janela (MonthProblems). Sem CID nem texto clínico;
    # problems e warnings são só códigos. cbos: { user_id => CBO no CAPS }.
    def month(unit:, month:, status:, closure:, report:, cbos:)
      { "month" => month.strftime("%Y-%m"), "health_unit_id" => unit.id, "status" => status,
        "closure" => closure && { "closed_at" => time(closure.closed_at),
                                  "closed_by" => pro(closure.closed_by_user, cbos[closure.closed_by_user_id]) },
        "counts" => report[:counts].transform_keys(&:to_s),
        "records" => report[:records].map { |entry| month_record(entry) } }
    end

    def month_record(entry)
      record = entry[:record]
      { "id" => record.id, "enrollment_id" => record.psychosocial_enrollment_id, "patient" => patient_ref(entry[:patient]),
        "status" => record.status, "homeless" => record.homeless, "actions_count" => entry[:actions_count],
        "problems" => entry[:problems], "warnings" => entry[:warnings] }
    end

    # Registro na resposta do PATCH da situação de rua: só ids e o estado.
    def monthly_record(record)
      { "id" => record.id, "enrollment_id" => record.psychosocial_enrollment_id, "health_unit_id" => record.health_unit_id,
        "month" => record.month.strftime("%Y-%m"), "status" => record.status, "homeless" => record.homeless }
    end

    # Remessa RAAS (GET/POST /psychosocial/raas_exports; contrato §6, P4): só
    # metadados — nunca nome, CID nem o arquivo. cbos: { user_id => CBO no CAPS }
    # (o faturista, sem lotação, sai com cbo_code nulo).
    def raas_export(export, cbos)
      { "id" => export.id, "health_unit_id" => export.health_unit_id, "month" => export.month.strftime("%Y-%m"),
        "competence" => export.competence, "layout_version" => export.layout_version, "records_count" => export.records_count,
        "sha256" => export.sha256, "created_at" => time(export.created_at),
        "created_by" => pro(export.created_by_user, cbos[export.created_by_user_id]) }
    end

    def action_participant(participant)
      return { "family_name" => participant.family_name } if participant.patient_id.nil?

      { "enrollment_id" => participant.psychosocial_enrollment_id, "patient" => patient_ref(participant.patient) }
    end
  end
end
