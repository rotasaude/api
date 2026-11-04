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
  end
end
