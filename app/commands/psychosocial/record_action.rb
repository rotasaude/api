# Ação do CAPS (ADR 0049; plano, Desvios 1, 3, 4, 5 e 6; contrato §4, P3,
# P12, P23, P25): individual, coletiva ou no território, sempre por aqui
# (manual, acolhimento, acolhimento noturno, matriciamento).
#
# Campos (só o corpo JSON): `sigtap_code` (10 dígitos); `performed_at` (data e
# hora ISO; o mês é o LOCAL); `place` (caps | territory); `quantity` (1..999,
# padrão 1); `notes` opcional (até 4000, cifrado; acima → too_long);
# `authorization_number` opcional (13 dígitos); `group_id` opcional (grupo
# deste CAPS); `participants` (até 100), cada um exatamente um de
# `{ enrollment_id }`, `{ patient_id }` ou `{ family_name }` (3..120), sem o
# mesmo paciente duas vezes. Recusas de campo (invalid_request / too_long, com
# o path) todas de uma vez, antes da crítica.
#
# Numa transação: trava a linha do CAPS (FOR SHARE, ruling: o fechamento do mês
# trava FOR UPDATE) e as matrículas (FOR SHARE), relê "aberta e deste CAPS" e
# roda a crítica (Psychosocial::ActionRules). Com problemas → 422
# action_rejected, nada gravado. Senão grava a ação (o profissional é quem
# pede, com o CBO do vínculo no CAPS), os participantes na ordem do corpo
# (position = índice + 1), a RAAS do mês de cada matriculado
# (MonthlyRecords.ensure!) e publica `psychosocial.action_recorded` só com o
# id. O trigger que recusa ação em mês fechado (corrida) vira month_closed.
module Psychosocial
  module RecordAction
    KEYS = %w[health_unit_id sigtap_code performed_at place quantity notes authorization_number group_id participants].freeze
    PARTICIPANT_KEYS = %w[enrollment_id patient_id family_name].freeze
    MAX_PARTICIPANTS = Catalog::CAPACITY.max
    SIGTAP_CODE = /\A\d{10}\z/
    KEY_PATH_MAX = 64
    MONTH_CLOSED = "psychosocial_actions: month closed".freeze

    module_function

    # -> Result.ok(action:) | fail(:action_rejected, details: { problems: }) |
    #    fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(attrs:, unit:, by:, link:, origin: "manual", night_stay: nil, now: Time.current)
      values, problems = check(attrs.to_h.stringify_keys, unit)
      return failure(problems) if problems.any?

      ApplicationRecord.transaction(requires_new: true) do
        record(values, unit: unit, by: by, link: link, origin: origin, night_stay: night_stay, now: now)
      end
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.include?(MONTH_CLOSED)

      rejected([ { error: "month_closed", path: "performed_at" } ])
    end

    def record(values, unit:, by:, link:, origin:, night_stay:, now:)
      HealthUnit.lock("FOR SHARE").find(unit.id)
      ids = values[:participants].filter_map { |p| p[:enrollment_id] }
      enrollments = ids.empty? ? {} : PsychosocialEnrollment.where(id: ids).lock("FOR SHARE").index_by(&:id)
      participants = values[:participants].map { |p| p.merge(enrollment: enrollments[p[:enrollment_id]]) }

      verdict = ActionRules.problems(values.slice(:sigtap_code, :performed_at, :quantity, :authorization_number).merge(participants: participants),
                                     unit: unit, link: link, now: now)
      return rejected(verdict[:problems]) if verdict[:problems].any?

      month = ActionRules.month_of(values[:performed_at])
      action = PsychosocialAction.create!(
        health_unit: unit, sigtap_code: values[:sigtap_code], instrument: verdict[:instrument], performed_at: values[:performed_at],
        month: month, place: values[:place], quantity: values[:quantity], notes: values[:notes],
        authorization_number: values[:authorization_number], psychosocial_group: values[:group], professional_user: by,
        cbo_code: link.cbo_code, origin: origin, psychosocial_night_stay: night_stay
      )
      participants.each_with_index do |participant, index|
        enrollment = participant[:enrollment]
        PsychosocialActionParticipant.create!(psychosocial_action: action, position: index + 1, psychosocial_enrollment: enrollment,
                                              patient_id: enrollment&.patient_id || participant[:patient_id],
                                              family_name: participant[:family_name])
      end
      enrollments.each_value { |enrollment| MonthlyRecords.ensure!(enrollment, month) }
      DomainEvents.publish("psychosocial.action_recorded", action_id: action.id)
      Result.ok(action: action)
    end

    # -> [values, problems]
    def check(attrs, unit)
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }

      code = attrs["sigtap_code"]
      problems << problem("sigtap_code") unless code.is_a?(String) && code.match?(SIGTAP_CODE)
      performed_at = Input.time(attrs["performed_at"])
      problems << problem("performed_at") unless performed_at
      problems << problem("place") unless Catalog::PLACES.include?(attrs["place"])
      quantity = attrs.fetch("quantity", 1)
      problems << problem("quantity") unless quantity.is_a?(Integer) && Catalog::QUANTITY.cover?(quantity)
      notes = attrs["notes"]
      problems << Catalog.text_problem(notes, Catalog::NOTES, "notes") unless notes.nil?
      authorization = attrs["authorization_number"]
      problems << problem("authorization_number") unless authorization.nil? || (authorization.is_a?(String) && authorization.match?(Catalog::AUTHORIZATION))
      group = group(attrs["group_id"], unit, problems)
      participants = participants(attrs["participants"], problems)

      values = { sigtap_code: code, performed_at: performed_at, place: attrs["place"], quantity: quantity, notes: notes&.strip,
                 authorization_number: authorization, group: group, participants: participants }
      [ values, problems.compact ]
    end

    def group(id, unit, problems)
      return nil if id.nil?

      group = Input.uuid?(id) ? PsychosocialGroup.find_by(id: id, health_unit_id: unit.id) : nil
      problems << problem("group_id") unless group
      group
    end

    # -> [ { enrollment_id:, patient_id:, family_name: } ] (só os bem formados ficam com valor).
    def participants(list, problems)
      unless list.is_a?(Array) && list.size <= MAX_PARTICIPANTS
        problems << problem("participants")
        return []
      end

      parsed = list.each_with_index.map { |item, index| participant(item, "participants[#{index}]", problems) }
      duplicates(parsed, problems)
      parsed
    end

    def participant(item, path, problems)
      keys = item.is_a?(Hash) ? item.keys.map(&:to_s) : []
      unless keys.size == 1 && PARTICIPANT_KEYS.include?(keys.first)
        problems << problem(path)
        return {}
      end

      key = keys.first
      value = item.values.first
      case key
      when "enrollment_id"
        return { enrollment_id: value } if Input.uuid?(value)
      when "patient_id"
        return { patient_id: value } if Input.uuid?(value) && Patient.exists?(id: value)
      when "family_name"
        refusal = Catalog.text_problem(value, Catalog::FAMILY_NAME, "#{path}.family_name")
        return { family_name: value.strip } unless refusal

        problems << refusal
        return {}
      end
      problems << problem("#{path}.#{key}")
      {}
    end

    # O mesmo paciente (pela matrícula ou pelo id) ou a mesma matrícula duas
    # vezes: recusa o participante repetido.
    def duplicates(parsed, problems)
      ids = parsed.filter_map { |p| p[:enrollment_id] }
      patients = ids.empty? ? {} : PsychosocialEnrollment.where(id: ids).pluck(:id, :patient_id).to_h
      seen = Set.new
      parsed.each_with_index do |p, index|
        keys = [ p[:enrollment_id] && "e:#{p[:enrollment_id]}", (patients[p[:enrollment_id]] || p[:patient_id])&.then { |id| "p:#{id}" } ].compact
        problems << problem("participants[#{index}]") if keys.any? { |key| seen.include?(key) }
        seen.merge(keys)
      end
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def rejected(problems) = Result.fail(:action_rejected, details: { problems: problems })

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :record, :check, :group, :participants, :participant, :duplicates, :problem, :rejected, :failure
  end
end
