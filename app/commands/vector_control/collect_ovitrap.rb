# Coleta a palheta da ovitrampa (módulo 35a, ADR 0054; contrato §6, §11, §17;
# Q7(2), Q7(5), Q13(2)). Pelo agente de endemias com o domicílio da ovitrampa
# numa microárea atribuída a ele, no dashboard ou no app (Task 15: `origin:
# "field_app"` com o aparelho; a idempotência do item é a do livro do app).
# Corpo `{ collected_on, condition, reinstall?, remove? }` (remove padrão
# false, reinstall padrão !remove). Recusas (só a primeira), nesta ordem:
#   - chave desconhecida ou faltando, collected_on que não é AAAA-MM-DD ou
#     depois de hoje, condition fora de CONDITIONS, reinstall/remove não
#     boolean → invalid_request com o path; reinstall == remove depois dos
#     padrões (false/false, true/true, reinstall false sozinho) →
#     invalid_request path reinstall (Q33: a coleta reinstala ou tira, nunca
#     deixa a ovitrampa ativa sem leitura aberta; tirar é sempre explícito);
#   - escopo (VectorControl::Access.agent_refusal);
#   - sob a trava da ovitrampa: não ativa → ovitrap_not_active; sem leitura
#     aberta → reading_not_open (os dois com path ovitrap_id);
#   - collected_on − installed_on fora de [ovitrap_collection_days_min, _max]
#     (Parameters.current) → collection_out_of_range path collected_on.
# Fecha a leitura aberta com a data e a condição. `remove: true` tira a
# ovitrampa (`removed`; `lost` com condition lost), com removed_on =
# collected_on; senão, reinstall abre a leitura seguinte com installed_on =
# collected_on (Q7(5), Q33). version + 1 e
# `ovitrap.collected` só com ids. Ordem de trava: ovitrampa → leitura (a
# mesma do VectorControl::CountReading).
module VectorControl
  module CollectOvitrap
    KEYS = %w[collected_on condition reinstall remove].freeze
    REQUIRED = %w[collected_on condition].freeze
    EVENT = "ovitrap.collected".freeze
    DATE = InstallOvitrap::DATE

    module_function

    # -> Result.ok(ovitrap:) | fail(<código>, details: { path: })
    def call(ovitrap:, params:, by:, origin: "dashboard", device: nil, today: Time.zone.today)
      raise ArgumentError, "origin" unless Ovitrap::ORIGINS.include?(origin)
      raise ArgumentError, "device: só (e sempre) com origin field_app" if (origin == "field_app") == device.nil?

      input = parse(params.to_h.stringify_keys, today)
      return input if input.is_a?(Result)

      refusal = Access.agent_refusal(by, ovitrap.household.micro_area)
      return Result.fail(refusal) if refusal

      Ovitrap.transaction(requires_new: true) { write(ovitrap, input, by) }
    end

    def write(ovitrap, input, by)
      ovitrap.lock!
      return fail_with(:ovitrap_not_active, "ovitrap_id") unless ovitrap.status == "active"

      reading = ovitrap.readings.open_readings.lock.first
      return fail_with(:reading_not_open, "ovitrap_id") unless reading

      collected_on = input[:collected_on]
      values = Parameters.current.values
      days = (collected_on - reading.installed_on).to_i
      unless days.between?(values.fetch("ovitrap_collection_days_min"), values.fetch("ovitrap_collection_days_max"))
        return fail_with(:collection_out_of_range, "collected_on")
      end

      reading.update!(collected_on: collected_on, condition: input[:condition], version: reading.version + 1)
      if input[:remove]
        ovitrap.assign_attributes(status: input[:condition] == "lost" ? "lost" : "removed", removed_on: collected_on)
      else
        OvitrapReading.create!(ovitrap: ovitrap, installed_on: collected_on, epi_week: OvitrapIndex.week_of(collected_on))
      end
      ovitrap.update!(version: ovitrap.version + 1)
      DomainEvents.publish(EVENT, ovitrap_id: ovitrap.id, user_id: by.id)
      Result.ok(ovitrap: ovitrap)
    end

    # { collected_on:, condition:, reinstall:, remove: } | Result de recusa.
    def parse(params, today)
      unknown = (params.keys - KEYS).first
      return invalid(unknown) if unknown

      missing = (REQUIRED - params.keys).first
      return invalid(missing) if missing

      collected_on = date(params["collected_on"])
      return invalid("collected_on") unless collected_on && collected_on <= today
      return invalid("condition") unless Catalog::CONDITIONS.include?(params["condition"])

      remove = params.fetch("remove", false)
      return invalid("remove") unless [ true, false ].include?(remove)

      reinstall = params.fetch("reinstall", !remove)
      return invalid("reinstall") unless [ true, false ].include?(reinstall) && reinstall != remove

      { collected_on: collected_on, condition: params["condition"], reinstall: reinstall, remove: remove }
    end

    def date(raw)
      raw.is_a?(String) && raw.match?(DATE) && Date.strptime(raw, "%Y-%m-%d")
    rescue Date::Error
      nil
    end

    def invalid(path) = fail_with(:invalid_request, path)

    def fail_with(reason, path) = Result.fail(reason, details: { path: path })
  end
end
