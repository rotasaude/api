# Prazos da ouvidoria (ADR 0051; contrato §2, Desvio 3; Q3, Q17). Fonte única
# em SQL (due_on_sql / color_sql, que a caixa, o painel e o job usam) com o
# espelho em Ruby (due_on / color) — o padrão de RegulationRequest.overdue_sql
# e #overdue?. Dias corridos, na data local da cidade (Time.zone dentro de
# CityConnection.with). Os prazos vêm SEMPRE da configuração vigente: mudar
# response_days muda o das abertas.
#
#   due_on = cycle_started_on + (urgent ? urgent_days : response_days)
#            + (extended ? extension_days : 0) + suspended_days
#
# Em awaiting_complement a cor é `paused` e o vencimento mostrado soma
# também os dias do complemento em curso (hoje - dia do pedido), que é o
# valor que suspended_days terá na volta. Nos estados finais o due_on é o do
# ciclo e a cor é nula. `yellow`: due_on - hoje <= warning_days (inclusive);
# `red`: hoje > due_on.
# As colunas de instante são `timestamp` em UTC: o SQL rotula como UTC e só
# então leva ao fuso da cidade (como Admin::Api::Period).
module Ombudsman
  module Deadlines
    TABLE = "ombudsman_manifestations".freeze

    module_function

    # Expressão SQL (date) sobre ombudsman_manifestations; os inteiros e a
    # data vão ligados por sanitize_sql_array, nunca interpolados crus.
    def due_on_sql(settings, today:)
      OmbudsmanManifestation.sanitize_sql_array([
        "(#{TABLE}.cycle_started_on + (CASE WHEN #{TABLE}.urgent THEN ? ELSE ? END)::int " \
        "+ (CASE WHEN #{TABLE}.extended THEN ? ELSE 0 END)::int + #{TABLE}.suspended_days " \
        "+ (CASE WHEN #{TABLE}.state = 'awaiting_complement' AND #{TABLE}.complement_requested_at IS NOT NULL " \
        "THEN GREATEST(CAST(? AS date) - ((#{TABLE}.complement_requested_at AT TIME ZONE 'UTC') AT TIME ZONE ?)::date, 0) ELSE 0 END)::int)",
        settings.urgent_days.to_i, settings.response_days.to_i, settings.extension_days.to_i, today.to_date, zone_name
      ])
    end

    # 'paused' | 'red' | 'yellow' | 'green' | NULL (estados finais).
    def color_sql(settings, today:)
      due = due_on_sql(settings, today: today)
      OmbudsmanManifestation.sanitize_sql_array([
        "(CASE WHEN #{TABLE}.state IN (?) THEN NULL " \
        "WHEN #{TABLE}.state = 'awaiting_complement' THEN 'paused' " \
        "WHEN CAST(? AS date) > #{due} THEN 'red' " \
        "WHEN #{due} - CAST(? AS date) <= ? THEN 'yellow' ELSE 'green' END)",
        Catalog::FINAL_STATES, today.to_date, today.to_date, settings.warning_days.to_i
      ])
    end

    # Espelho em Ruby de due_on_sql.
    def due_on(manifestation, settings, today:)
      days = manifestation.urgent ? settings.urgent_days : settings.response_days
      days += settings.extension_days if manifestation.extended
      days += manifestation.suspended_days.to_i
      days += complement_days_running(manifestation, today)
      manifestation.cycle_started_on + days
    end

    # Espelho em Ruby de color_sql.
    def color(manifestation, settings, today:)
      return nil if manifestation.final?
      return "paused" if manifestation.state == "awaiting_complement"

      by_due(due_on(manifestation, settings, today: today), settings, today)
    end

    # Encaminhamento: due_on gravado no encaminhamento (data local + forwarding_days).
    def forwarding_due_on(created_on, settings) = created_on + settings.forwarding_days

    # Só o encaminhamento pendente tem cor; a regra é a das manifestações.
    def forwarding_color(forwarding, settings, today:)
      return nil unless forwarding.pending?

      by_due(forwarding.due_on, settings, today)
    end

    # Dia em que o complemento pedido vence (o job arquiva no dia seguinte).
    def complement_due_on(manifestation, settings)
      requested = manifestation.complement_requested_at
      requested && requested.in_time_zone.to_date + settings.complement_days
    end

    # Janela do cidadão depois da conclusão (pedido de reabertura, pesquisa de
    # satisfação): até `days` dias corridos locais de `concluded_at`, inclusive
    # (o dia 31 já está fora de uma janela de 30).
    def within_window?(concluded_at, days, today:)
      concluded_at.present? && (today.to_date - concluded_at.in_time_zone.to_date).to_i <= days
    end

    def by_due(due_on, settings, today)
      return "red" if today.to_date > due_on
      return "yellow" if (due_on - today.to_date).to_i <= settings.warning_days

      "green"
    end

    def complement_days_running(manifestation, today)
      return 0 unless manifestation.state == "awaiting_complement" && manifestation.complement_requested_at

      [ (today.to_date - manifestation.complement_requested_at.in_time_zone.to_date).to_i, 0 ].max
    end

    def zone_name = Time.zone.tzinfo.name

    private_class_method :by_due, :complement_days_running, :zone_name
  end
end
