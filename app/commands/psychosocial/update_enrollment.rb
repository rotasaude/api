# Edição da matrícula aberta (ADR 0049; contrato §4, P13): parcial, com as
# regras de campo da criação (CreateEnrollment.field/esf_problem) mais
# `next_visit_at` (ISO 8601 ou nulo). `origin` e `started_on` só mudam antes da
# primeira RAAS exportada da matrícula (senão 422 origin_locked, com o path da
# chave); `started_on` também não sai de nem vai para mês fechado no CAPS (422
# month_closed, ruling). Corpo vazio → 422 invalid_request. Sem cobertura de ESF, o CNES da USF é apagado; com cobertura, o CNES
# gravado vale até vir outro. Encerrada → 409 already_closed. Mudou o início:
# garante a RAAS de cada mês do novo início até o corrente (e recusa com
# month_closed se algum deles estiver fechado). Recusas todas de uma vez. Sem evento
# (o contrato §13 não tem um para a edição).
module Psychosocial
  module UpdateEnrollment
    KEYS = %w[origin started_on cid_main cid_secondary substances esf_covered esf_cnes reference_user_id next_visit_at].freeze
    LOCKED = %w[origin started_on].freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(enrollment:) | fail(:already_closed) |
    #    fail(:invalid_request | :origin_locked | :month_closed | :esf_cnes_required, details: { path:, problems: })
    def call(enrollment:, attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      return Result.fail(:invalid_request) if attrs.empty?
      return Result.fail(:already_closed) unless enrollment.open?

      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(enrollment.health_unit_id)
        enrollment.lock!
        next Result.fail(:already_closed) unless enrollment.open?

        changes, problems = check(enrollment, attrs)
        next failure(problems) if problems.any?

        enrollment.assign_attributes(changes)
        if enrollment.changed?
          start_moved = enrollment.started_on_changed?
          enrollment.save!
          MonthlyRecords.ensure_through!(enrollment) if start_moved
        end
        Result.ok(enrollment: enrollment)
      end
    end

    # -> [changes, problems]
    def check(enrollment, attrs)
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }
      changes = {}
      exported = nil
      (KEYS - %w[esf_cnes next_visit_at]).each do |key|
        next unless attrs.key?(key)

        value, error = CreateEnrollment.field(key, attrs[key], unit: enrollment.health_unit, patient: enrollment.patient)
        next problems << problem(key, error) if error

        if LOCKED.include?(key) && value != enrollment.public_send(key)
          exported = enrollment.psychosocial_monthly_records.exists?(status: "exported") if exported.nil?
          next problems << problem(key, "origin_locked") if exported
          next problems << problem(key, "month_closed") if key == "started_on" && start_month_closed?(enrollment, value)
        end
        changes[key] = value
      end
      check_next_visit(attrs, changes, problems)
      check_esf(enrollment, attrs, changes, problems)
      [ changes, problems ]
    end

    # O início muda de mês de registro inicial: todo mês do novo início até o
    # corrente (a continuidade, fix round 1 da Task 9) e o mês atual do início
    # precisam estar abertos (ruling; o chamador segura a trava do CAPS).
    def start_month_closed?(enrollment, started_on)
      MonthlyRecords.any_closed?(enrollment.health_unit_id, started_on) ||
        MonthlyRecords.closed?(enrollment.health_unit_id, enrollment.started_on)
    end

    def check_next_visit(attrs, changes, problems)
      return unless attrs.key?("next_visit_at")

      raw = attrs["next_visit_at"]
      time = raw.nil? ? nil : Input.time(raw)
      return problems << problem("next_visit_at") if !raw.nil? && time.nil?

      changes["next_visit_at"] = time
    end

    # O par cobertura/CNES é conferido inteiro (o CHECK do banco).
    def check_esf(enrollment, attrs, changes, problems)
      return unless attrs.key?("esf_covered") || attrs.key?("esf_cnes")
      return if attrs.key?("esf_covered") && !changes.key?("esf_covered") # esf_covered já recusado

      covered = changes.fetch("esf_covered", enrollment.esf_covered)
      cnes = if attrs.key?("esf_cnes") then attrs["esf_cnes"]
      elsif covered then enrollment.esf_cnes
      end
      error = CreateEnrollment.esf_problem(covered, cnes)
      return problems << problem("esf_cnes", error) if error

      changes["esf_cnes"] = cnes
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :check, :start_month_closed?, :check_next_visit, :check_esf, :problem, :failure
  end
end
