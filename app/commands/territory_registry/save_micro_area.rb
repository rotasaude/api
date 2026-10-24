# Microárea da equipe (contrato §3; F-24.1). Criação: equipe ativa 70/76,
# código de 2 dígitos único na equipe, nome 1..60 e o ACS opcional. Edição:
# só nome, ACS (null tira) e active — código e equipe nunca mudam (trigger).
# O ACS precisa ser membro ativo da equipe com CBO 515105 e ter CNS (vai no
# cabeçalho da ficha). Evento micro_area.changed só com ids.
module TerritoryRegistry
  module SaveMicroArea
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    NAME_MAX = 60

    module_function

    def call(params:, by:, micro_area: nil)
      params = params.to_h.stringify_keys
      micro_area ? update(micro_area, params, by) : create(params, by)
    end

    # O CHECK de health_teams.kind só aceita 70/76 hoje; a checagem é a defesa
    # para um tipo novo no CNES (não depende de HealthTeam::KINDS).
    def team_kind_allowed?(team) = Catalog::TEAM_KINDS.include?(team.kind)

    # nil quando serve; senão o motivo. CNS é NOT NULL e validado hoje: a
    # checagem cobre CNS apagado por fora do modelo.
    def acs_check(team, professional)
      member = professional&.persisted? &&
               HealthTeamMember.active.exists?(professional: professional, health_team: team, cbo_code: Catalog::ACS_CBO)
      return :acs_not_in_team unless member
      return :acs_without_cns unless Professionals::Cns.valid?(professional.cns)

      nil
    end

    def create(params, by)
      team = uuid?(params["team_id"]) && HealthTeam.find_by(id: params["team_id"], active: true)
      return Result.fail(:not_found) unless team
      return Result.fail(:team_kind_not_allowed) unless team_kind_allowed?(team)

      code = params["code"]
      return Result.fail(:invalid_code) unless code.is_a?(String) && code.match?(MicroArea::CODE)

      area = MicroArea.new(team: team, code: code)
      failure = assign(area, params.slice("name", "acs_professional_id").reverse_merge("name" => nil), team)
      return failure if failure
      return Result.fail(:duplicate_code) if MicroArea.exists?(team_id: team.id, code: code)

      persist(area, by, created: true)
    end

    def update(area, params, by)
      return Result.fail(:team_kind_not_allowed) unless team_kind_allowed?(area.team)

      failure = assign(area, params.slice("name", "acs_professional_id", "active"), area.team)
      return failure if failure

      persist(area, by, created: false)
    end

    def assign(area, attrs, team)
      if attrs.key?("name")
        name = attrs["name"].is_a?(String) ? attrs["name"].squish : ""
        return Result.fail(:invalid_micro_area, details: { field: "name" }) unless name.length.between?(1, NAME_MAX)

        area.name = name
      end
      if attrs.key?("active")
        return Result.fail(:invalid_micro_area, details: { field: "active" }) unless [ true, false ].include?(attrs["active"])

        area.active = attrs["active"]
      end
      if attrs.key?("acs_professional_id")
        id = attrs["acs_professional_id"]
        professional = nil
        unless id.nil? # null tira o ACS
          professional = uuid?(id) ? Professional.find_by(id: id) : nil
          reason = acs_check(team, professional)
          return Result.fail(reason) if reason
        end
        area.acs_professional = professional
      end
      nil
    end

    # Savepoint próprio: o índice único (team_id, code) na corrida vira
    # duplicate_code sem abortar a transação de quem chamou.
    def persist(area, by, created:)
      return Result.ok(micro_area: area, created: false) unless area.changed? # PATCH sem mudança: nada a gravar

      MicroArea.transaction(requires_new: true) do
        area.save!
        DomainEvents.publish("micro_area.changed", micro_area_id: area.id, team_id: area.team_id, user_id: by.id)
      end
      Result.ok(micro_area: area, created: created)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_code)
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :create, :update, :assign, :persist, :uuid?
  end
end
