# Desfecho da observação do animal agressor (módulo 35b, ADR 0054; contrato
# §5, §7, Q16). POST /zoonoses/observations/:id/close, para team? (senão
# missing_role). Corpo: `outcome` (Catalog::OBSERVATION_OUTCOMES),
# `outcome_on` ("AAAA-MM-DD"), `outcome_note` (opcional, 10–500 depois do
# strip: recusada, nunca cortada; cifrada) e o obrigatório `expected_version`
# (ausente → expected_version_required; diferente → 409 observation_changed).
# Chave estranha ou valor fora da forma → invalid_request com o path.
#
#   - A observação FOR UPDATE: closed → 409 invalid_transition path status;
#   - outcome_on antes de exposure_on ou depois de hoje → date_out_of_range
#     path outcome_on;
#   - healthy com outcome_on < ends_on → observation_not_finished path
#     outcome_on (o dia ends_on exato vale: o 10º dia);
#   - euthanized exige a eutanásia gravada com a bite_observation_id desta
#     observação (Zoonoses::RecordEuthanasia, que já exige o animal ligado),
#     senão invalid_request path outcome; e, com essa eutanásia gravada, só
#     euthanized fecha (outro desfecho → invalid_request path outcome).
# Não trava nem muda o animal: a eutanásia é imutável (basta lê-la), e a
# morte do animal é do RecordEuthanasia / AnimalDeath. Sem trava do animal
# não há ciclo com o EnterShelter (animal → observação).
#
# `bite_observation.closed` só com o id. A nota nunca em Result.details.
module Zoonoses
  module CloseObservation
    EVENT = "bite_observation.closed".freeze
    KEYS = %w[outcome outcome_on outcome_note expected_version].freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(observation:) | fail(:invalid_request | :date_out_of_range | :observation_not_finished, details: { path: }) |
    #    fail(:expected_version_required, details: { path: "expected_version" }) | fail(:invalid_transition, details: { path: "status" }) |
    #    fail(:missing_role | :observation_changed)
    def call(observation:, params:, by:, today: Time.zone.today)
      return Result.fail(:missing_role) unless Access.team?(by)

      attrs = parse(params.to_h.stringify_keys)
      return attrs if attrs.is_a?(Result)

      BiteObservation.transaction(requires_new: true) { close(observation.id, attrs, by, today) }
    end

    def close(id, attrs, by, today)
      row = BiteObservation.lock.find(id)
      return Result.fail(:observation_changed) unless row.version == attrs[:expected_version]
      return Result.fail(:invalid_transition, details: { path: "status" }) if row.closed?

      outcome_on = attrs[:outcome_on]
      return Result.fail(:date_out_of_range, details: { path: "outcome_on" }) if outcome_on < row.exposure_on || outcome_on > today
      if attrs[:outcome] == "healthy" && outcome_on < row.ends_on
        return Result.fail(:observation_not_finished, details: { path: "outcome_on" })
      end
      # Desfecho coerente: com a eutanásia ligada, só euthanized; sem ela, nunca euthanized.
      euthanized = Euthanasia.exists?(bite_observation_id: row.id)
      return invalid("outcome") if (attrs[:outcome] == "euthanized") != euthanized

      row.update!(state: "closed", outcome: attrs[:outcome], outcome_on: outcome_on, outcome_note: attrs[:outcome_note],
                  closed_by_user: by, version: row.version + 1)
      DomainEvents.publish(
        EVENT,
        bite_observation_id: row.id
      )
      Result.ok(observation: row)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid("outcome") unless Catalog::OBSERVATION_OUTCOMES.include?(params["outcome"])

      outcome_on = date(params["outcome_on"])
      return invalid("outcome_on") unless outcome_on

      note = nil
      if params.key?("outcome_note") && !params["outcome_note"].nil?
        note = params["outcome_note"].is_a?(String) ? params["outcome_note"].strip : ""
        return invalid("outcome_note") unless Catalog::NOTE.cover?(note.length)
      end
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

      version = params["expected_version"]
      return invalid("expected_version") unless version.is_a?(Integer) && version.positive?

      { outcome: params["outcome"], outcome_on: outcome_on, outcome_note: note, expected_version: version }
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :close, :parse, :date, :invalid
  end
end
