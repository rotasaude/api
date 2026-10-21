# Crítica SIGTAP do procedimento realizado (ADR 0039; spec §2 decisões 2, 4 e
# 6; contrato §1). Marca, nunca bloqueia: devolve o instrumento, se é
# faturável e os motivos, na ordem estável REASONS. Lê a release da
# competência do dia do procedimento — ou a última ativa anterior (fallback,
# com aviso). Relação vazia na SIGTAP (procedimento sem CBO/CID listado) não
# restringe. BPA-I e BPA-C listados: BPA-I. CID e identificação do paciente
# só contam no BPA-I (o BPA-C não tem essas colunas); o nascimento conta nos
# dois (idade). Usada na gravação e de novo no fechamento.
module Billing
  module Critic
    REASONS = %w[establishment_is_aps missing_establishment_cnes not_in_sigtap not_bpa_instrument missing_professional_cbo
                 cbo_not_allowed missing_professional_cns age_out_of_range sex_not_allowed cid_required cid_not_allowed
                 missing_patient_id missing_required_patient_field missing_race_color missing_address].freeze
    SEX = { "female" => "F", "male" => "M" }.freeze

    Facts = Data.define(:establishment, :sigtap_code, :performed_on, :cbo_code, :professional_cns, :cid10, :patient)
    Outcome = Data.define(:instrument, :billable, :reasons, :sigtap_competence, :fallback, :label)

    module_function

    # closing: true no fechamento e nas pendências (Billing::Recalculate): só
    # ali entram raça/cor e endereço do paciente (D-U1, contrato §12).
    def call(facts, closing: false)
      competence = facts.performed_on.strftime("%Y%m")
      release = Terminology::Sigtap.release_for(competence)
      reasons = []
      reasons << "establishment_is_aps" if facts.establishment.aps?
      reasons << "missing_establishment_cnes" if facts.establishment.cnes.blank?
      procedure = release && SigtapProcedure.find_by(release_id: release.id, code: facts.sigtap_code)
      return outcome("not_bpa", reasons + %w[not_in_sigtap], release, competence, nil) unless procedure

      instrument = instrument(release, facts.sigtap_code)
      reasons << "not_bpa_instrument" if instrument == "not_bpa"
      reasons.concat(professional_reasons(facts, release, instrument))
      reasons.concat(patient_reasons(facts, procedure, release, instrument, closing))
      outcome(instrument, reasons, release, competence, procedure.name)
    end

    def instrument(release, code)
      codes = SigtapProcedureInstrument.where(release_id: release.id, procedure_code: code).pluck(:instrument_code)
      return "bpa_i" if codes.include?("02")

      codes.include?("01") ? "bpa_c" : "not_bpa"
    end

    def professional_reasons(facts, release, instrument)
      reasons = []
      if facts.cbo_code.blank?
        reasons << "missing_professional_cbo"
      elsif !listed?(SigtapProcedureCbo, release, facts.sigtap_code, cbo_code: facts.cbo_code)
        reasons << "cbo_not_allowed"
      end
      reasons << "missing_professional_cns" if instrument == "bpa_i" && facts.professional_cns.blank?
      reasons
    end

    def patient_reasons(facts, procedure, release, instrument, closing)
      patient = facts.patient
      reasons = []
      months = age_months(patient&.birth_date, facts.performed_on)
      if months && ((procedure.age_min_months && months < procedure.age_min_months) ||
                    (procedure.age_max_months && months > procedure.age_max_months))
        reasons << "age_out_of_range"
      end
      reasons << "sex_not_allowed" if %w[F M].include?(procedure.sex) && SEX[patient&.sex] && SEX[patient.sex] != procedure.sex
      return reasons if instrument == "not_bpa"

      reasons << "missing_required_patient_field" if patient.nil? || patient.birth_date.blank?
      return reasons unless instrument == "bpa_i"

      reasons.concat(cid_reasons(facts, release))
      reasons << "missing_patient_id" if patient.nil? || patient.cpf.blank?
      reasons << "missing_required_patient_field" if patient && (patient.full_name.blank? || !SEX.key?(patient.sex))
      reasons.concat(demographic_reasons(patient)) if closing && patient
      reasons
    end

    # D-U1: raça/cor 01..05 (sem 99) e etnia de 4 dígitos quando indígena (05);
    # endereço com CEP, logradouro e bairro (número vazio vira SN na entrada, §13 E4).
    def demographic_reasons(patient)
      reasons = []
      race = patient.race_color
      ethnic_ok = race != "05" || patient.ethnicity.to_s.match?(/\A\d{4}\z/)
      reasons << "missing_race_color" unless Patient::RACE_COLORS.include?(race) && ethnic_ok
      address = [ patient.address_zip, patient.address_street, patient.address_district ]
      reasons << "missing_address" if address.any?(&:blank?)
      reasons
    end

    def cid_reasons(facts, release)
      cids = SigtapProcedureCid.where(release_id: release.id, procedure_code: facts.sigtap_code)
      return [] unless cids.exists?
      return %w[cid_required] if facts.cid10.blank?

      cids.exists?(cid_code: facts.cid10) ? [] : %w[cid_not_allowed]
    end

    # Sem relação nenhuma para o procedimento = sem restrição (como Terminology::Sigtap).
    def listed?(model, release, code, **value)
      scope = model.where(release_id: release.id, procedure_code: code)
      !scope.exists? || scope.exists?(value)
    end

    def age_months(birth_date, on)
      born = Date.iso8601(birth_date.to_s)
      months = (on.year * 12 + on.month) - (born.year * 12 + born.month)
      on.day < born.day ? months - 1 : months
    rescue Date::Error
      nil
    end

    def outcome(instrument, reasons, release, competence, label)
      ordered = reasons.uniq.sort_by { |reason| REASONS.index(reason) }
      Outcome.new(instrument: instrument, billable: ordered.empty?, reasons: ordered, sigtap_competence: release&.version,
                  fallback: release.present? && release.version != competence, label: label)
    end
    private_class_method :instrument, :professional_reasons, :patient_reasons, :demographic_reasons, :cid_reasons, :listed?, :age_months, :outcome
  end
end
