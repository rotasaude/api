# Andamento da demanda de zoonoses (módulo 35b, ADR 0054; contrato §4, Q13,
# Q34). POST /zoonoses/demands/:id/{schedule,inspect,close,decline,extend},
# para team? (senão missing_role). Corpo, sempre com o obrigatório
# `expected_version` (ausente → expected_version_required; diferente → 409
# demand_changed); chave fora da ação → invalid_request com o path:
#   - schedule `{ scheduled_on }`: open → scheduled; o dia ≥ hoje, senão
#     date_out_of_range;
#   - inspect `{ inspected_on, inspection_note }`: open/scheduled → inspected;
#     o dia ≤ hoje (senão date_out_of_range); a nota em INSPECTION_NOTE
#     (10..2000, cifrada);
#   - close `{ outcome, text }`: de qualquer estado aberto → closed com o
#     `outcome` (DEMAND_OUTCOMES); o texto (CLOSING_TEXT, 20..4000) vira a
#     resposta do encaminhamento (Ombudsman::ReplyForwarding, via_zoonoses);
#   - decline `{ text }`: de qualquer estado aberto → closed sem outcome; o
#     texto (TEXT do 33, 10..4000) é o motivo (Ombudsman::DeclineForwarding);
#   - extend `{ reason }`: Ombudsman::ExtendForwarding, uma vez (o
#     already_extended do 33); a demanda fica no estado, com a versão + 1 (o
#     prazo mostrado mudou).
# Texto longo é recusado, nunca cortado (Ombudsman::Input: sem as bordas).
#
# Travas na ordem das escritas do 33: a manifestação, o encaminhamento
# (Ombudsman::Lock.forwarding!) e só então a demanda FOR UPDATE; a ação do 33
# chamada depois retrava os mesmos dois (já nossos). Encaminhamento fora de
# pending → 409 forwarding_changed (antes da versão: o fim pelo 33 já fechou a
# demanda); estado fora da ação → 409 invalid_transition path status. Tudo num
# savepoint: a recusa do 33 volta a demanda.
#
# Todo fim do encaminhamento ligado fecha a demanda na mesma transação
# (forwarding_ended!, chamado pelos ReplyForwarding, DeclineForwarding e
# CancelForwarding do 33, por qualquer caminho): o close e o decline daqui
# já a fecharam antes, e o gancho não faz nada; a resposta ou a recusa do
# respondente do 33 pelo inbox e o cancelamento da equipe da ouvidoria a
# fecham sem outcome. `zoonoses_demand.changed` só com o id.
module Zoonoses
  module AdvanceDemand
    EVENT = "zoonoses_demand.changed".freeze
    OPEN_STATES = %w[open scheduled inspected].freeze
    KEYS = {
      "schedule" => %w[scheduled_on], "inspect" => %w[inspected_on inspection_note], "close" => %w[outcome text],
      "decline" => %w[text], "extend" => %w[reason]
    }.freeze
    FROM = { "schedule" => %w[open], "inspect" => %w[open scheduled], "close" => OPEN_STATES, "decline" => OPEN_STATES,
             "extend" => OPEN_STATES }.freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(demand:, forwarding:) | fail(:invalid_request | :date_out_of_range, details: { path: }) |
    #    fail(:expected_version_required, details: { path: "expected_version" }) | fail(:invalid_transition, details: { path: "status" }) |
    #    fail(:missing_role | :not_found | :demand_changed | :forwarding_changed | :already_extended)
    def call(demand:, action:, params:, by:, now: Time.current, today: Time.zone.today)
      return invalid("action") unless KEYS.key?(action)
      return Result.fail(:missing_role) unless Access.team?(by)

      attrs = parse(action, params.to_h.stringify_keys, today)
      return attrs if attrs.is_a?(Result)

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = advance(demand, action, attrs, by, now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    # O encaminhamento saiu de pending (Ombudsman::Forwardings.ended!, sob a
    # trava manifestação → encaminhamento): a demanda ligada, se ainda aberta,
    # vai a closed sem outcome.
    def forwarding_ended!(forwarding:, now:)
      row = ZoonosesDemand.lock.find_by(ombudsman_forwarding_id: forwarding.id)
      return if row.nil? || row.state == "closed"

      row.update!(state: "closed", version: row.version + 1, updated_at: now)
      publish(row)
    end

    def advance(demand, action, attrs, by, now)
      locked = Ombudsman::Lock.forwarding!(demand.ombudsman_forwarding_id)
      return Result.fail(:not_found) unless locked

      forwarding = locked.last
      row = ZoonosesDemand.lock.find(demand.id)
      return Result.fail(:forwarding_changed) unless forwarding.pending?
      return Result.fail(:demand_changed) unless row.version == attrs[:expected_version]
      return Result.fail(:invalid_transition, details: { path: "status" }) unless FROM.fetch(action).include?(row.state)

      changes = { version: row.version + 1, updated_at: now }
      case action
      when "schedule" then row.update!(changes.merge(state: "scheduled", scheduled_on: attrs[:scheduled_on]))
      when "inspect"
        row.update!(changes.merge(state: "inspected", inspected_on: attrs[:inspected_on], inspection_note: attrs[:inspection_note]))
      when "close"
        row.update!(changes.merge(state: "closed", outcome: attrs[:outcome]))
        delegated = Ombudsman::ReplyForwarding.call(forwarding_id: forwarding.id, expected_state: "pending", body: attrs[:text], by: by,
                                                    via_zoonoses: true, now: now)
      when "decline"
        row.update!(changes.merge(state: "closed"))
        delegated = Ombudsman::DeclineForwarding.call(forwarding_id: forwarding.id, expected_state: "pending", reason: attrs[:text],
                                                      by: by, via_zoonoses: true, now: now)
      when "extend"
        delegated = Ombudsman::ExtendForwarding.call(forwarding_id: forwarding.id, expected_state: "pending", reason: attrs[:reason],
                                                     by: by, via_zoonoses: true, now: now)
        row.update!(changes) if delegated.ok?
      end
      return refused(delegated, action) if delegated&.failure?

      publish(row)
      Result.ok(demand: row, forwarding: forwarding.reload)
    end

    # A recusa do 33 no formato daqui: a de campo (body/reason, já conferidos
    # no parse) com o path da chave de texto da ação, nunca os `problems`.
    def refused(result, action)
      return Result.fail(result.reason) unless result.details[:path]

      Result.fail(result.reason, details: { path: KEYS.fetch(action).last })
    end

    def publish(row)
      DomainEvents.publish(
        EVENT,
        zoonoses_demand_id: row.id
      )
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(action, params, today)
      allowed = KEYS.fetch(action) + %w[expected_version]
      unknown = params.keys.find { |key| !allowed.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      attrs = fields(action, params, today)
      return attrs if attrs.is_a?(Result)
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

      version = params["expected_version"]
      return invalid("expected_version") unless version.is_a?(Integer) && version.positive?

      attrs.merge(expected_version: version)
    end

    def fields(action, params, today)
      case action
      when "schedule"
        on = date(params["scheduled_on"])
        return invalid("scheduled_on") unless on
        return out_of_range("scheduled_on") if on < today

        { scheduled_on: on }
      when "inspect"
        on = date(params["inspected_on"])
        return invalid("inspected_on") unless on
        return out_of_range("inspected_on") if on > today

        text(params, "inspection_note", Catalog::INSPECTION_NOTE) { |note| { inspected_on: on, inspection_note: note } }
      when "close"
        return invalid("outcome") unless Catalog::DEMAND_OUTCOMES.include?(params["outcome"])

        text(params, "text", Catalog::CLOSING_TEXT) { |value| { outcome: params["outcome"], text: value } }
      when "decline" then text(params, "text", Ombudsman::Catalog::TEXT) { |value| { text: value } }
      when "extend" then text(params, "reason", Ombudsman::Catalog::TEXT) { |value| { reason: value } }
      end
    end

    def text(params, key, range)
      value = Ombudsman::Input.text(params[key], range)
      value ? yield(value) : invalid(key)
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    def out_of_range(path) = Result.fail(:date_out_of_range, details: { path: path })

    private_class_method :advance, :refused, :publish, :parse, :fields, :text, :date, :invalid, :out_of_range
  end
end
