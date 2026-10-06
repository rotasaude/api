# Compatibilidade de procedimento SIGTAP (ADR 0028; spec 2026-10-05 §4). Lê a
# release ativa da competência — ou a última ativa anterior a ela. Relação
# vazia (procedimento sem CBO/CID listado) não restringe. Os módulos que
# registram procedimento (18, 19…) chamam isto antes de gerar a ficha.
module Terminology
  module Sigtap
    COMPETENCE = /\A\d{4}(0[1-9]|1[0-2])\z/
    SEX = { "female" => "F", "male" => "M", "F" => "F", "M" => "M" }.freeze

    module_function

    def release_for(competence)
      scope = TerminologyRelease.active.where(kind: "sigtap")
      scope = scope.where("version <= ?", competence) if competence
      scope.order(version: :desc).first
    end

    def compatible?(code, competence:, cbo: nil, age_months: nil, sex: nil, cid: nil)
      raise ArgumentError, "competência inválida: #{competence.inspect}" unless competence.nil? || competence.to_s.match?(COMPETENCE)

      release = release_for(competence&.to_s)
      return { ok: false, reasons: %w[no_release], release_version: nil } unless release

      procedure = SigtapProcedure.find_by(release_id: release.id, code: code.to_s)
      return { ok: false, reasons: %w[unknown_procedure], release_version: release.version } unless procedure

      reasons = []
      reasons << "sex_incompatible" if sex_incompatible?(procedure.sex, sex)
      if age_months
        reasons << "age_below_minimum" if procedure.age_min_months && age_months < procedure.age_min_months
        reasons << "age_above_maximum" if procedure.age_max_months && age_months > procedure.age_max_months
      end
      reasons << "cbo_incompatible" if cbo && !listed?(SigtapProcedureCbo, release, code, cbo_code: cbo.to_s)
      if cid && !listed?(SigtapProcedureCid, release, code, cid_code: cid.to_s.delete(".").upcase)
        reasons << "cid_incompatible"
      end
      { ok: reasons.empty?, reasons: reasons, release_version: release.version }
    end

    def sex_incompatible?(required, sex)
      return false if sex.nil? || !%w[F M].include?(required)

      SEX[sex.to_s] != required
    end

    # Sem relação nenhuma para o procedimento = sem restrição.
    def listed?(model, release, code, **value)
      scope = model.where(release_id: release.id, procedure_code: code.to_s)
      !scope.exists? || scope.exists?(value)
    end
  end
end
