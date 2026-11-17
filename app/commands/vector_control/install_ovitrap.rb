# Instala a ovitrampa (módulo 35a, ADR 0054; contrato §6, §17; Q7(2), Q7(5),
# Q7(6), Q13(2); A-9). Pelo agente de endemias com o domicílio numa microárea
# atribuída a ele, no dashboard (`origin: "dashboard"`) ou no app (Task 15:
# `origin: "field_app"` com o aparelho). Corpo `{ client_uuid, household_id,
# number, consent, installed_on }`, todas obrigatórias. Recusas (só a
# primeira), nesta ordem:
#   - client_uuid não UUID → invalid_request; já gravado pelo mesmo usuário →
#     ok(replayed: true) com a ovitrampa; por outro → client_uuid_conflict;
#   - chave desconhecida ou faltando, household_id não UUID, number fora de
#     OVITRAP_NUMBER (Q7(6)), consent não boolean (Q7(5)), installed_on que
#     não é AAAA-MM-DD ou depois de hoje → invalid_request com o path;
#   - domicílio desconhecido ou inativo → not_found path household_id;
#   - escopo (VectorControl::Access.agent_refusal) → out_of_scope |
#     cbo_not_allowed | missing_role;
#   - perfil sem quarteirão → household_without_block path household_id;
#   - consent false → consent_required path consent;
#   - número de outra ativa, sem caixa (idx_ovitraps_number) →
#     ovitrap_number_taken path number.
# O perfil é lido FOR SHARE e o quarteirão fica congelado na ovitrampa. Abre a
# primeira leitura com installed_on e epi_week YYYYWW. Evento
# `ovitrap.installed` só com ids. Num savepoint: a corrida do número e do
# client_uuid é decidida pelos índices únicos.
module VectorControl
  module InstallOvitrap
    KEYS = %w[client_uuid household_id number consent installed_on].freeze
    EVENT = "ovitrap.installed".freeze
    NUMBER_INDEX = "idx_ovitraps_number".freeze
    CLIENT_UUID_INDEX = "idx_ovitraps_client_uuid".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    # -> Result.ok(ovitrap:, replayed:) | fail(<código>, details: { path: })
    def call(params:, by:, origin: "dashboard", device: nil, today: Time.zone.today, now: Time.current)
      raise ArgumentError, "origin" unless Ovitrap::ORIGINS.include?(origin)
      raise ArgumentError, "device: só (e sempre) com origin field_app" if (origin == "field_app") == device.nil?

      params = params.to_h.stringify_keys
      uuid = params["client_uuid"]
      return invalid("client_uuid") unless uuid.is_a?(String) && uuid.match?(UUID)

      replay = replayed(uuid, by)
      return replay if replay

      input = parse(params, today)
      return input if input.is_a?(Result)

      household = Household.includes(micro_area: :team).find_by(id: input[:household_id])
      return fail_with(:not_found, "household_id") unless household&.status == "active"

      refusal = Access.agent_refusal(by, household.micro_area)
      return Result.fail(refusal) if refusal

      write(input, household, by, origin, device, now)
    rescue ActiveRecord::RecordNotUnique => e
      return fail_with(:ovitrap_number_taken, "number") if e.message.include?(NUMBER_INDEX)
      raise unless e.message.include?(CLIENT_UUID_INDEX)

      replayed(uuid, by) || raise
    end

    def write(input, household, by, origin, device, now)
      Ovitrap.transaction(requires_new: true) do
        profile = HouseholdVectorProfile.lock("FOR SHARE").find_by(household_id: household.id)
        next fail_with(:household_without_block, "household_id") unless profile&.city_block_id
        next fail_with(:consent_required, "consent") unless input[:consent]

        ovitrap = Ovitrap.create!(household: household, city_block_id: profile.city_block_id, client_uuid: input[:client_uuid],
                                  number: input[:number], consent_at: now, installed_on: input[:installed_on], installed_by_user: by,
                                  origin: origin, field_device_id: device&.id)
        OvitrapReading.create!(ovitrap: ovitrap, installed_on: input[:installed_on], epi_week: OvitrapIndex.week_of(input[:installed_on]))
        DomainEvents.publish(EVENT, ovitrap_id: ovitrap.id, user_id: by.id)
        Result.ok(ovitrap: ovitrap, replayed: false)
      end
    end

    # { client_uuid:, household_id:, number:, consent:, installed_on: } | Result de recusa.
    def parse(params, today)
      unknown = (params.keys - KEYS).first
      return invalid(unknown) if unknown

      missing = (KEYS - params.keys).first
      return invalid(missing) if missing

      household_id = params["household_id"]
      return invalid("household_id") unless household_id.is_a?(String) && household_id.match?(UUID)

      number = params["number"]
      return invalid("number") unless number.is_a?(String) && number.match?(Catalog::OVITRAP_NUMBER)
      return invalid("consent") unless [ true, false ].include?(params["consent"])

      installed_on = date(params["installed_on"])
      return invalid("installed_on") unless installed_on && installed_on <= today

      { client_uuid: params["client_uuid"], household_id: household_id, number: number, consent: params["consent"],
        installed_on: installed_on }
    end

    def replayed(uuid, by)
      ovitrap = Ovitrap.find_by(client_uuid: uuid)
      return nil unless ovitrap
      return fail_with(:client_uuid_conflict, "client_uuid") unless by && ovitrap.installed_by_user_id == by.id

      Result.ok(ovitrap: ovitrap, replayed: true)
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
