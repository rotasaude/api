require Rails.root.join("lib/sigtap_sample").to_s

# Módulo 31 (ADR 0049): cidade do CAPS (prontuário, ou o faturamento com
# billing: true), SIGTAP de dev com os procedimentos do CAPS (Valor fixado 6,
# pelo caminho real: Terminology::Import do SigtapSample), CAPS, equipe lotada
# (papel do CAPS + vínculo ativo), paciente com par validado, telefone e CNS,
# matrícula (com a RAAS do mês), leito, médico da UBS e o administrador. As
# gravações são diretas no banco (os caminhos reais são os comandos das Tasks
# 3–11). Tudo avaliado só na chamada.
module PsychosocialHelpers
  # Prontuário (clinical_city!) ou, com billing: true, a cidade do faturamento
  # (billing_city!), sempre com a SIGTAP do CAPS criada ANTES (a SIGTAP ativa é
  # imutável). Liga `psychosocial_care` e garante os parâmetros (a linha que a
  # migração insere e o dump não leva).
  def psychosocial_city!(billing: false)
    psychosocial_sigtap!
    city = billing ? billing_city! : clinical_city!
    Platform::Features.set!(city: city, key: "psychosocial_care", enabled: true, maintainer: ledi_maintainer!)
    PsychosocialSetting.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  # As releases SIGTAP da competência do dia e da anterior com o recorte de
  # dev inteiro (SigtapSample: faturamento, exames, saúde bucal, regulação e o
  # CAPS — instrumento 09, quantidade máxima, permanência e atributo 036).
  # Chame antes de billing_city!/exam_city!: depois de ativa, a release não muda.
  def psychosocial_sigtap!(competences = [ Time.zone.today.strftime("%Y%m"), Time.zone.today.prev_month.strftime("%Y%m") ])
    Array(competences).map do |competence|
      existing = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
      if existing
        raise "psychosocial_sigtap! depois de billing_city!/exam_city!: chame antes" unless
          SigtapProcedure.exists?(release_id: existing.id, code: SigtapSample::PSYCHOSOCIAL_CODES.first)

        next existing
      end
      result = Dir.mktmpdir do |dir|
        Terminology::Import.call(kind: "sigtap", version: competence, path: SigtapSample.write_to(dir, competence: competence),
                                 by: "rspec")
      end
      raise "SIGTAP do CAPS recusada: #{result.reason}" if result.failure?

      result.payload[:release]
    end
  end

  def psychosocial_admin!
    @psychosocial_admin ||= step_up_enrolled!(staff_with("admin-caps-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
  end

  def caps!(modality: "caps_ii", name: "CAPS #{SecureRandom.hex(3)}", cnes: billing_cnes, service_classification: "001")
    HealthUnit.create!(name: name, kind: "caps", caps_modality: modality, service_classification: service_classification, cnes: cnes)
  end

  # Profissional lotado no CAPS: papel psychosocial_staff (ou
  # psychosocial_lead), perfil e vínculo ativo com o CBO; MFA cadastrado (o
  # step-up da sessão é do request spec: stepped_up!).
  def caps_staff!(unit, cbo: "251510", lead: false)
    role = lead ? "psychosocial_lead" : "psychosocial_staff"
    user = staff_with("caps-#{SecureRandom.hex(3)}@cidade.gov.br", role)
    link_professional!(user, unit, cbo: cbo)
    step_up_enrolled!(user)
  end

  # Paciente com par validado e telefone (exam_patient!), raça/cor e endereço
  # (faturável) e, com cns: true, um CNS válido.
  def caps_patient!(cns: true)
    patient = exam_patient!(exam_seq!).first
    patient.update!(BillingHelpers::DEMOGRAPHICS.merge(cns: (Professionals::Cns.generate(SecureRandom.uuid) if cns)))
    patient
  end

  # Matrícula aberta gravada direto (o caminho real é Psychosocial::CreateEnrollment)
  # e a RAAS do mês do início.
  def enrollment!(unit, patient: caps_patient!, reference: caps_staff!(unit), started_on: Date.current.beginning_of_month, cid: "F200")
    ApplicationRecord.transaction(requires_new: true) do
      enrollment = PsychosocialEnrollment.create!(health_unit: unit, patient: patient, started_on: started_on, origin: "01",
                                                  cid_main: cid, cid_secondary: [], substances: [], esf_covered: false,
                                                  reference_user: reference)
      PsychosocialMonthlyRecord.create!(psychosocial_enrollment: enrollment, health_unit: unit, month: started_on.beginning_of_month)
      enrollment
    end
  end

  # Ação gravada pela via real (Psychosocial::RecordAction, com o vínculo de
  # quem grava no CAPS): hoje às 10:00 locais (ou agora, se ainda não deu
  # 10:00), no CAPS, quantidade 1. Recusa → erro com os códigos (nunca dado
  # do paciente). Devolve a PsychosocialAction.
  def record_action!(unit, by, **attrs)
    performed_at = [ Time.zone.today.in_time_zone.change(hour: 10), Time.current ].min
    attrs = { sigtap_code: "0301080208", performed_at: performed_at.iso8601, place: "caps", quantity: 1, participants: [] }.merge(attrs)
    result = Psychosocial::RecordAction.call(attrs: attrs.deep_stringify_keys, unit: unit, by: by,
                                             link: Psychosocial::Access.link(by, unit.id))
    raise "record_action! recusada: #{result.reason} #{Array(result.details[:problems]).map { |p| p[:error] }.join(',')}" if result.failure?

    result.payload.fetch(:action)
  end

  def bed!(unit, label: "L1")
    PsychosocialBed.create!(health_unit: unit, label: label, updated_by_user: psychosocial_admin!)
  end

  # Médico da UBS (health_professional, vínculo 225125 na unidade).
  def ubs_doctor!(ubs)
    screener!(ubs, cbo: "225125", email: "medico-ubs-#{SecureRandom.hex(3)}@cidade.gov.br")
  end
end

RSpec.configure { |c| c.include PsychosocialHelpers }
