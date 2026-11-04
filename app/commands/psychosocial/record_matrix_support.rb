# Matriciamento do CAPS com uma equipe da atenção básica (ADR 0049; contrato
# §7, P12, P23). Campos (só o corpo JSON): `health_team_id` (equipe ativa de
# atenção primária — HealthTeam::PRIMARY_CARE_KINDS — de unidade ativa que não
# é CAPS); `held_on` (data, não futura no fuso da cidade); `topic` (1..200,
# cifrado; acima → too_long); `participants_user_ids` (1..20, sem repetição,
# cada um lotado neste CAPS — papel do CAPS e vínculo ativo); `sigtap_code` (10
# dígitos, que na SIGTAP da competência de `held_on` resolve para BPA-C sem
# participante paciente — instrumento 01 e não 02; senão instrument_mismatch).
# Recusas de campo todas de uma vez.
#
# Numa transação: a ação BPA-C pela via de toda ação (Psychosocial::RecordAction,
# `origin: "matrix_support"`, sem participantes, quantidade 1, no território, à
# 00:00 local de `held_on`, com o vínculo de quem grava) e o matriciamento que
# aponta para ela; publica `psychosocial.matrix_support_recorded` só com o id.
# A crítica da ação recusa tudo com 422 action_rejected, nos campos do
# matriciamento: `performed_at` → `held_on`; os demais → `sigtap_code` (o
# matriciamento não tem quantidade, autorização nem participantes pacientes).
module Psychosocial
  module RecordMatrixSupport
    KEYS = %w[health_unit_id health_team_id held_on topic participants_user_ids sigtap_code].freeze
    PARTICIPANTS = (1..20)
    SIGTAP_CODE = /\A\d{10}\z/
    KEY_PATH_MAX = 64

    module_function

    # link: o vínculo de quem grava no CAPS (o CBO da ação).
    # -> Result.ok(matrix_support:) | fail(:action_rejected, details: { problems: }) |
    #    fail(:invalid_request | :too_long | :instrument_mismatch, details: { path:, problems: })
    def call(attrs:, unit:, by:, link:, now: Time.current)
      attrs = attrs.to_h.stringify_keys
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }

      team = team(attrs["health_team_id"], problems)
      held_on = Input.date(attrs["held_on"])
      problems << problem("held_on") unless held_on && held_on <= now.in_time_zone.to_date
      topic = attrs["topic"]
      problems << Catalog.text_problem(topic, Catalog::TOPIC, "topic")
      user_ids = participants(attrs["participants_user_ids"], unit, problems)
      problems << code_problem(attrs["sigtap_code"], held_on)
      problems.compact!
      return failure(problems) if problems.any?

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = record(unit: unit, team: team, held_on: held_on, topic: topic.strip, user_ids: user_ids, code: attrs["sigtap_code"],
                        by: by, link: link, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def record(unit:, team:, held_on:, topic:, user_ids:, code:, by:, link:, now:)
      action = RecordAction.call(attrs: { "sigtap_code" => code, "performed_at" => held_on.in_time_zone.iso8601, "place" => "territory",
                                          "quantity" => 1, "participants" => [] },
                                 unit: unit, by: by, link: link, origin: "matrix_support", now: now)
      return action_refusal(action) if action.failure?

      support = PsychosocialMatrixSupport.create!(health_unit: unit, health_team: team, held_on: held_on, topic: topic,
                                                  participant_user_ids: user_ids, sigtap_code: code,
                                                  psychosocial_action: action.payload.fetch(:action), recorded_by_user: by)
      DomainEvents.publish("psychosocial.matrix_support_recorded", matrix_support_id: support.id)
      Result.ok(matrix_support: support)
    end

    # Equipe ativa de atenção primária, de unidade ativa que não é CAPS.
    def team(id, problems)
      team = Input.uuid?(id) ? HealthTeam.joins(:health_unit).find_by(id: id.downcase, active: true, kind: HealthTeam::PRIMARY_CARE_KINDS) : nil
      return team if team&.health_unit&.active && team.health_unit.kind != "caps"

      problems << problem("health_team_id")
      nil
    end

    # -> [uuid] na ordem do corpo. Cada um lotado neste CAPS (papel + vínculo
    # ativo); repetido → invalid_request no índice repetido.
    def participants(list, unit, problems)
      unless list.is_a?(Array) && PARTICIPANTS.cover?(list.size)
        problems << problem("participants_user_ids")
        return []
      end

      ids = list.map { |id| Input.uuid?(id) ? id.downcase : nil }
      users = User.where(id: ids.compact.uniq).index_by(&:id)
      seen = Set.new
      ids.each_with_index do |id, index|
        user = id && users[id]
        problems << problem("participants_user_ids[#{index}]") unless user && seen.add?(id) && Access.link(user, unit.id)
      end
      ids
    end

    # nil (aceito) | o problema. Sem `held_on` válido, só a forma do código.
    def code_problem(code, held_on)
      return problem("sigtap_code") unless code.is_a?(String) && code.match?(SIGTAP_CODE)
      return nil unless held_on

      release = Terminology::Sigtap.release_for(held_on.strftime("%Y%m"))
      instruments = release ? SigtapProcedureInstrument.where(release_id: release.id, procedure_code: code).pluck(:instrument_code) : []
      Instrument.for(instruments, enrolled: false) == "bpa_c" ? nil : problem("sigtap_code", "instrument_mismatch")
    end

    # A crítica da ação nos campos do matriciamento.
    def action_refusal(result)
      return result unless result.reason == :action_rejected

      problems = result.details[:problems].map { |p| { error: p[:error], path: p[:path] == "performed_at" ? "held_on" : "sigtap_code" } }
      Result.fail(:action_rejected, details: { problems: problems.uniq })
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :record, :team, :participants, :code_problem, :action_refusal, :problem, :failure
  end
end
