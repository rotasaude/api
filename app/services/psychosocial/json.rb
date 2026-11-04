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
  end
end
