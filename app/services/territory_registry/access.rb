# Quem faz o quê no cadastro territorial (módulo 24a, ADR 0042; contrato §1 e
# §3; plano, Desvio 4). Microáreas: municipal_admin. Ficha de cadastro: membro
# ativo da equipe (papel health_professional, perfil de profissional) com
#   - CBO de enfermeiro/médico (Catalog::REGISTRAR_CBO_PREFIXES) → qualquer
#     microárea da equipe;
#   - CBO 515105 (ACS) → só a microárea em que é o responsável;
# e, além do papel, o CBO do vínculo NA EQUIPE na tabela do LEDI da ficha
# (config/ledi/registration_cbos.yml: individual = Tabela 1, household =
# Tabela 2): fora dela a ficha nunca nasceria aceitável → cbo_not_allowed.
#
# Módulo 35a (ADR 0054; contrato §20 Q13(1), Q14): com vector_control
# utilizável (`vector_control:`, lido por quem chama fora de transação), o
# agente de endemias (VectorControl::Access.field_agent?: 515140, papel de
# campo da visita) grava a ficha DOMICILIAR só de imóvel não residencial
# (HomeVisits::Catalog::NON_RESIDENTIAL) nas microáreas atribuídas a ele
# (micro_area_field_assignments ativas). Ficha individual, família e
# responsável seguem cbo_not_allowed; o ACS e o enfermeiro não mudam.
module TerritoryRegistry
  module Access
    REGISTRATION_CBOS = YAML.load_file(Rails.root.join("config/ledi/registration_cbos.yml"))
                            .to_h { |ficha, cbos| [ ficha.to_sym, cbos.map(&:to_s).to_set.freeze ] }.freeze

    module_function

    def admin?(user) = user.has_role?("municipal_admin")

    def membership(user, team)
      return nil unless team && user&.professional && user.has_role?("health_professional")

      HealthTeamMember.active.find_by(professional: user.professional, health_team: team)
    end

    # ficha: :individual | :household | :home_visit | :collective_activity (as
    # chaves do YAML; outra → KeyError: erro de programação).
    def registrar_cbo?(cbo, ficha:) = REGISTRATION_CBOS.fetch(ficha.to_sym).include?(cbo.to_s)

    # :ok | :out_of_scope | :cbo_not_allowed. micro_area nil = cadastro sem
    # domicílio, pela equipe (fora de área, Desvio 3): qualquer membro com
    # papel de cadastro, inclusive o ACS. `ficha:` escolhe a tabela do LEDI.
    # property_type (o do corpo) e current_property_type (o da versão atual do
    # domicílio) só contam para o agente de endemias (módulo 35a); nil = sem
    # tipo (o contexto de cadastro do GET /territory/teams).
    def registrar?(user, team, ficha:, micro_area: nil, vector_control: false, property_type: nil, current_property_type: nil)
      member = membership(user, team)
      return :out_of_scope unless member
      return :out_of_scope if micro_area && micro_area.team_id != team.id
      if endemic_registrar?(user, team, ficha: ficha, vector_control: vector_control)
        return endemic_scope(member, ficha, micro_area, property_type, current_property_type)
      end

      case role(member.cbo_code)
      when :registrar then nil
      when :acs then return :out_of_scope if micro_area && micro_area.acs_professional_id != member.professional_id
      else return :cbo_not_allowed
      end
      registrar_cbo?(member.cbo_code, ficha: ficha) ? :ok : :cbo_not_allowed
    end

    # Lê o cadastro individual por id (GET /territory/registrations/:id; e o
    # registration_id dos duplicados, §14 L29): quem poderia gravá-lo onde ele
    # está (equipe e microárea).
    def reads_registration?(user, registration)
      registrar?(user, registration.team, ficha: :individual, micro_area: registration.micro_area) == :ok
    end

    # Microáreas da equipe que o usuário enxerga para cadastrar: todas para
    # enfermeiro/médico, as suas para o ACS, nenhuma para os demais. Com
    # `vector_control:` utilizável, as atribuídas ao agente de endemias (só o
    # domicílio não residencial grava; família e cadastro individual seguem
    # recusados pelo papel).
    def visible_micro_area_ids(user, team, vector_control: false)
      member = membership(user, team)
      case member && role(member.cbo_code)
      when :registrar then MicroArea.where(team: team).pluck(:id)
      when :acs then MicroArea.where(team: team, acs_professional_id: member.professional_id).pluck(:id)
      else
        endemic_registrar?(user, team, ficha: :household, vector_control: vector_control) ? assigned_ids(member, team) : []
      end
    end

    # Módulo 35a (Q14(1)): os tipos de imóvel que o usuário cadastra na equipe
    # — a lista não residencial para o agente de endemias com vector_control
    # utilizável; nil (= todos os tipos) para o resto.
    def registration_property_types(user, team, vector_control:)
      HomeVisits::Catalog::NON_RESIDENTIAL if endemic_registrar?(user, team, ficha: :household, vector_control: vector_control)
    end

    # Módulo 24b (Q11; ruling A5b): microáreas da equipe que o CBO de campo
    # que não é ACS (Tabela 7, :field do HomeVisits::Access) LÊ pelas rotas de
    # leitura do 24a — as atribuídas a ele e ativas (micro_area_field_assignments
    # sem ended_at). Só leitura: index/show de domicílios e o index de
    # cadastros por domicílio — nunca a guarda de uma escrita (o update de
    # domicílio confere a origem por visible_micro_area_ids). A escrita
    # (registrar?), visible_micro_area_ids, reads_registration? e as buscas não
    # mudam: o TACS segue cbo_not_allowed. `home_visits:` = o interruptor
    # utilizável, lido por quem chama fora de transação (Q48): desligado, vale
    # o acesso do 24a e nada mais.
    def field_reader_micro_area_ids(user, team, home_visits:)
      return [] unless home_visits

      scope = HomeVisits::Access.scope(user, team)
      scope[:kind] == "assigned" ? scope[:micro_area_ids] : []
    end

    # Módulo 24c (Q39): o usuário lê ao menos uma microárea — cadastra nela
    # (enfermeiro, médico, o ACS responsável) ou é o CBO de campo atribuído a
    # ela, com home_visits utilizável. É quem vê o mapa da microárea.
    def reads_households?(user, home_visits:)
      return false unless user&.professional

      team_ids = HealthTeamMember.active.where(professional: user.professional).pluck(:health_team_id)
      HealthTeam.where(id: team_ids, active: true).any? do |team|
        visible_micro_area_ids(user, team).any? || field_reader_micro_area_ids(user, team, home_visits: home_visits).any?
      end
    end

    # Gestão que lê a contagem da validade sem ser da equipe (L10).
    def manager?(user) = admin?(user) || user.has_role?("analyst")

    # Quem lê a validade da equipe (F-24.6, L10): :team (enfermeiro/médico,
    # qualquer microárea), :acs (só a microárea em que é o responsável) ou nil.
    # Leitura: não exige o CBO da tabela do LEDI, só o papel de cadastro.
    def status_reader(user, team)
      member = membership(user, team)
      case member && role(member.cbo_code)
      when :registrar then :team
      when :acs then :acs
      end
    end

    # Lê a validade da equipe inteira, sem micro_area_id (registry_status; a
    # tela de equipes como reads_whole_team, §14 L27). O ACS nunca, mesmo
    # responsável por todas as microáreas: manda a sua.
    def reads_whole_team?(user, team) = status_reader(user, team) == :team

    def role(cbo)
      return :acs if cbo == Catalog::ACS_CBO

      :registrar if Catalog::REGISTRAR_CBO_PREFIXES.any? { |prefix| cbo.to_s.start_with?(prefix) }
    end

    # O papel do módulo 35a vale só para a ficha domiciliar, com o interruptor.
    def endemic_registrar?(user, team, ficha:, vector_control:)
      vector_control == true && ficha.to_sym == :household && VectorControl::Access.field_agent?(user, team)
    end

    # Atribuição ativa na microárea → tipo do corpo e o atual não residenciais
    # (troca para residencial e edição de residencial → cbo_not_allowed).
    def endemic_scope(member, ficha, micro_area, property_type, current_property_type)
      return :out_of_scope unless micro_area && assigned_ids(member, micro_area.team).include?(micro_area.id)
      return :cbo_not_allowed unless [ property_type, current_property_type ].compact.all? { |type| HomeVisits::Catalog::NON_RESIDENTIAL.include?(type) }

      registrar_cbo?(member.cbo_code, ficha: ficha) ? :ok : :cbo_not_allowed
    end

    def assigned_ids(member, team)
      MicroArea.where(team: team, id: MicroAreaFieldAssignment.active.where(professional_id: member.professional_id).select(:micro_area_id)).pluck(:id)
    end
    private_class_method :role, :endemic_registrar?, :endemic_scope, :assigned_ids
  end
end
