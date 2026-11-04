# Matrícula no CAPS (ADR 0049; contrato §4, P13). O CAPS vem da lotação de
# quem pede (o controller já conferiu `health_unit_id`). Campos:
#   patient_id; started_on (não futuro); origin (origins do raas.yml);
#   cid_main (CID-10 da release ativa, gravado sem ponto); cid_secondary
#   (até 4); substances (não vazio, códigos do raas.yml, "99" sozinho);
#   esf_covered e, se coberta, esf_cnes de 7 dígitos (falta →
#   esf_cnes_required; sem cobertura, esf_cnes não vem); reference_user_id
#   (lotado no mesmo CAPS).
# Recusas de campo todas de uma vez. Já aberta do paciente no CAPS → 409
# enrollment_open (também pelo índice parcial). Algum mês fechado no CAPS do
# início até o mês corrente → 422 month_closed `started_on` (ruling: sem
# matrícula sem RAAS; conferido sob a trava do CAPS). Cria a RAAS de cada mês
# do início ao corrente (MonthlyRecords.ensure_through!: a matrícula retroativa
# não fica sem os meses intermediários) e publica `psychosocial.enrolled` só
# com o id.
# O acolhimento (RecordReception) valida o bloco `enrollment` por `check` e
# grava por `insert`, na transação dele.
module Psychosocial
  module CreateEnrollment
    KEYS = %w[health_unit_id patient_id started_on origin cid_main cid_secondary substances esf_covered esf_cnes
              reference_user_id].freeze
    # O bloco `enrollment` do acolhimento: o CAPS e o paciente são os da recepção.
    BLOCK_KEYS = (KEYS - %w[health_unit_id patient_id]).freeze
    REQUIRED = %w[started_on origin cid_main substances esf_covered reference_user_id].freeze
    OPEN_INDEX = "idx_psychosocial_enrollments_open".freeze
    CNES = /\A\d{7}\z/
    NO_SUBSTANCE = "99".freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(enrollment:) | fail(:enrollment_open) |
    #    fail(:invalid_request | :esf_cnes_required | :month_closed, details: { path:, problems: })
    def call(attrs:, unit:, by:, reception: nil)
      attrs = attrs.to_h.stringify_keys
      patient = Input.uuid?(attrs["patient_id"]) ? Patient.find_by(id: attrs["patient_id"]) : nil
      values, problems = check(attrs.except("health_unit_id", "patient_id"), unit: unit)
      problems.unshift(problem("patient_id")) unless patient
      return failure(problems) if problems.any?

      insert(values, patient: patient, unit: unit, by: by, reception: reception)
    end

    # Valida os campos da matrícula (sem CAPS nem paciente). -> [values, problems]
    def check(attrs, unit:)
      problems = (attrs.keys - BLOCK_KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }
      values = {}
      (BLOCK_KEYS - %w[esf_cnes]).each do |key|
        next if !attrs.key?(key) && !REQUIRED.include?(key)

        value, error = field(key, attrs[key], unit: unit)
        if error
          problems << problem(key, error)
        else
          values[key] = value
        end
      end
      if values.key?("esf_covered")
        esf = esf_problem(values["esf_covered"], attrs["esf_cnes"])
        problems << problem("esf_cnes", esf) if esf
        values["esf_cnes"] = attrs["esf_cnes"] unless esf
      end
      [ values, problems ]
    end

    # Um campo da matrícula (também a edição). -> [valor, nil] | [nil, código do erro]
    def field(key, raw, unit:)
      case key
      when "started_on"
        date = Input.date(raw)
        date && date <= Time.zone.today ? [ date, nil ] : invalid
      when "origin" then Raas.valid?(:origins, raw) ? [ raw, nil ] : invalid
      when "cid_main"
        code = ClinicalTerms.cid10_code(raw)
        code.is_a?(String) ? [ code, nil ] : invalid
      when "cid_secondary" then secondary(raw)
      when "substances" then substances(raw)
      when "esf_covered" then [ true, false ].include?(raw) ? [ raw, nil ] : invalid
      when "reference_user_id"
        user = Input.uuid?(raw) ? User.find_by(id: raw) : nil
        user && Access.link(user, unit.id) ? [ user.id, nil ] : invalid
      else invalid
      end
    end

    # nil | "esf_cnes_required" | "invalid_request" (a regra do CHECK
    # esf_covered = (esf_cnes IS NOT NULL)).
    def esf_problem(covered, cnes)
      return (cnes.nil? ? nil : "invalid_request") unless covered
      return "esf_cnes_required" if cnes.nil? || cnes == ""

      cnes.is_a?(String) && cnes.match?(CNES) ? nil : "invalid_request"
    end

    # Grava a matrícula já validada, travando a linha do CAPS (FOR SHARE: o
    # fechamento do mês não corre junto da RAAS do mês do início).
    def insert(values, patient:, unit:, by:, reception: nil)
      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(unit.id)
        next Result.fail(:enrollment_open) if PsychosocialEnrollment.open_enrollments.exists?(patient_id: patient.id, health_unit_id: unit.id)
        next failure([ problem("started_on", "month_closed") ]) if MonthlyRecords.any_closed?(unit.id, values.fetch("started_on"))

        enrollment = PsychosocialEnrollment.create!(
          health_unit: unit, patient: patient, psychosocial_reception: reception, started_on: values.fetch("started_on"),
          origin: values.fetch("origin"), cid_main: values.fetch("cid_main"), cid_secondary: values.fetch("cid_secondary", []),
          substances: values.fetch("substances"), esf_covered: values.fetch("esf_covered"), esf_cnes: values["esf_cnes"],
          reference_user_id: values.fetch("reference_user_id")
        )
        MonthlyRecords.ensure_through!(enrollment)
        DomainEvents.publish("psychosocial.enrolled", enrollment_id: enrollment.id)
        Result.ok(enrollment: enrollment)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(OPEN_INDEX)

      Result.fail(:enrollment_open)
    end

    def secondary(raw)
      raw = [] if raw.nil?
      return invalid unless raw.is_a?(Array) && raw.size <= Catalog::MAX_SECONDARY_CIDS

      codes = raw.map { |value| ClinicalTerms.cid10_code(value) }
      codes.all?(String) ? [ codes.uniq, nil ] : invalid
    end

    def substances(raw)
      return invalid unless raw.is_a?(Array) && raw.any? && raw.all? { |code| Raas.valid?(:substances, code) }
      return invalid if raw.include?(NO_SUBSTANCE) && raw.uniq.size > 1

      [ raw.uniq, nil ]
    end

    def invalid = [ nil, "invalid_request" ]
    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :secondary, :substances, :invalid, :problem, :failure
  end
end
