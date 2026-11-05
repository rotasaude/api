# RAAS do mês de uma matrícula (ADR 0049; plano, Desvio 6): o registro `open`
# de (matrícula, mês), criado uma vez (índice único, ON CONFLICT DO NOTHING) ao
# matricular (mês do início), ao gravar ação com o participante matriculado
# (Task 7) e no job do mês (Task 9). Mês com fechamento ativo no CAPS: devolve o
# existente sem criar (ou nil). Quem chama segura a linha do CAPS (FOR SHARE)
# antes, para não correr com o fechamento (ruling das Tasks 7 e 9).
module Psychosocial
  module MonthlyRecords
    module_function

    # Mês fechado sem registro onde o chamador já recusou o mês fechado
    # (matrícula, edição do início, encerramento): nunca deveria acontecer.
    class MissingRecord < StandardError; end

    # Destino da RAAS de quem continua no mês seguinte (raas.yml, "Permanência").
    PERMANENCE = "00".freeze

    # month: qualquer dia do mês. -> PsychosocialMonthlyRecord | nil
    # strict: true → nil vira MissingRecord (o chamador já conferiu o mês sob a trava).
    def ensure!(enrollment, month, strict: false)
      month = month.to_date.beginning_of_month
      scope = PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrollment.id, month: month)
      if closed?(enrollment.health_unit_id, month)
        record = scope.first
        raise MissingRecord, "RAAS do mês #{month} ausente com o mês fechado" if strict && record.nil?

        return record
      end

      PsychosocialMonthlyRecord.insert_all(
        [ { psychosocial_enrollment_id: enrollment.id, health_unit_id: enrollment.health_unit_id, month: month, status: "open" } ],
        unique_by: %i[psychosocial_enrollment_id month]
      )
      scope.first!
    end

    # Continuidade de uma matrícula que começa num mês passado (fix rounds 1 e
    # 2 da Task 9): a RAAS de TODO mês do início até o mês corrente, num único
    # INSERT ... ON CONFLICT DO NOTHING. Quem chama já conferiu, sob a trava do
    # CAPS, que nenhum desses meses está fechado (any_closed?) e que o início
    # respeita o piso (Catalog::MAX_RETROACTIVE_MONTHS). -> [PsychosocialMonthlyRecord] por mês
    def ensure_through!(enrollment, today: Time.zone.today)
      list = months(enrollment.started_on, today)
      return [] if list.empty?

      rows = list.map { |month| { psychosocial_enrollment_id: enrollment.id, health_unit_id: enrollment.health_unit_id, month: month, status: "open" } }
      PsychosocialMonthlyRecord.insert_all(rows, unique_by: %i[psychosocial_enrollment_id month])
      PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrollment.id, month: list.first..list.last).order(:month).to_a
    end

    # Algum mês com fechamento ativo no CAPS entre `from` e `to` (qualquer dia
    # de cada um, inclusive).
    def any_closed?(health_unit_id, from, to = Time.zone.today)
      PsychosocialMonthClosure.active.where(health_unit_id: health_unit_id,
                                            month: from.to_date.beginning_of_month..to.to_date.beginning_of_month).exists?
    end

    # Dias 1º de cada mês de `from` a `to`, inclusive. -> [Date]
    def months(from, to)
      month = from.to_date.beginning_of_month
      last = to.to_date.beginning_of_month
      list = []
      while month <= last
        list << month
        month = month.next_month
      end
      list
    end

    # Fechamento ativo do CAPS no mês (qualquer dia do mês).
    def closed?(health_unit_id, month)
      PsychosocialMonthClosure.active.exists?(health_unit_id: health_unit_id, month: month.to_date.beginning_of_month)
    end

    # Mês com remessa RAAS gerada (ou registro já exportado) no CAPS: não reabre
    # (ReopenMonth), a situação do GET é `exported` e a Task 10 não gera outra.
    def exported?(health_unit_id, month)
      month = month.to_date.beginning_of_month
      PsychosocialRaasExport.exists?(health_unit_id: health_unit_id, month: month) ||
        PsychosocialMonthlyRecord.exists?(health_unit_id: health_unit_id, month: month, status: "exported")
    end

    # Telefone de contato do registro (P57, I3): o do par validado; sem ele,
    # para quem está em situação de rua no mês (homeless = true), o do CAPS
    # (health_units.phone, P27), contato legítimo da pessoa. Senão nil.
    def contact_phone(record, patient_phone, unit)
      return patient_phone if patient_phone.present?

      unit.phone.presence if record.homeless == true
    end

    # A foto do registro no fechamento (plano, Desvio 7), a gravar no
    # `snapshot` (JSON cifrado; nunca em log, evento ou erro): identificação
    # do paciente (nome, nome social, CNS, nascimento, sexo, mãe), raça/cor,
    # etnia, telefone, endereço, a origem só no registro inicial (mês do
    # início), início, CIDs, substâncias, ESF, destino ("00" = permanência),
    # conclusão e situação de rua. O telefone é o de contato (contact_phone:
    # o do par validado ou, em situação de rua, o do CAPS), passado por quem chama.
    def snapshot(record, phone:)
      enrollment = record.psychosocial_enrollment
      patient = enrollment.patient
      initial = record.month == enrollment.started_on.beginning_of_month
      {
        "patient" => {
          "id" => patient.id, "name" => patient.full_name, "social_name" => patient.social_name, "cns" => patient.cns,
          "birth_date" => patient.birth_date, "sex" => patient.sex, "mother_name" => patient.mother_name,
          "race_color" => patient.race_color, "ethnicity" => patient.ethnicity, "phone" => phone,
          "address" => { "zip" => patient.address_zip, "street" => patient.address_street, "number" => patient.address_number,
                         "complement" => patient.address_complement, "district" => patient.address_district }
        },
        "initial" => initial, "origin" => (enrollment.origin if initial), "started_on" => enrollment.started_on.iso8601,
        "cid_main" => enrollment.cid_main, "cid_secondary" => enrollment.cid_secondary || [], "substances" => enrollment.substances || [],
        "esf_covered" => enrollment.esf_covered, "esf_cnes" => enrollment.esf_cnes,
        "destination" => record.destination || PERMANENCE, "concluded_on" => record.concluded_on&.iso8601, "homeless" => record.homeless
      }
    end
  end
end
