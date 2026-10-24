# Quem faz o quê no cadastro territorial (módulo 24a, ADR 0042; contrato §1 e
# §3; plano, Desvio 4). Microáreas: municipal_admin. Ficha de cadastro: membro
# ativo da equipe (papel health_professional, perfil de profissional) com
#   - CBO de enfermeiro/médico (Catalog::REGISTRAR_CBO_PREFIXES) → qualquer
#     microárea da equipe;
#   - CBO 515105 (ACS) → só a microárea em que é o responsável;
# e, além do papel, o CBO do vínculo NA EQUIPE na tabela do LEDI da ficha
# (config/ledi/registration_cbos.yml: individual = Tabela 1, household =
# Tabela 2): fora dela a ficha nunca nasceria aceitável → cbo_not_allowed.
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

    # ficha: :individual | :household (outra → KeyError: erro de programação).
    def registrar_cbo?(cbo, ficha:) = REGISTRATION_CBOS.fetch(ficha.to_sym).include?(cbo.to_s)

    # :ok | :out_of_scope | :cbo_not_allowed. micro_area nil = cadastro sem
    # domicílio, pela equipe (fora de área, Desvio 3): qualquer membro com
    # papel de cadastro, inclusive o ACS. `ficha:` escolhe a tabela do LEDI.
    def registrar?(user, team, ficha:, micro_area: nil)
      member = membership(user, team)
      return :out_of_scope unless member
      return :out_of_scope if micro_area && micro_area.team_id != team.id

      case role(member.cbo_code)
      when :registrar then nil
      when :acs then return :out_of_scope if micro_area && micro_area.acs_professional_id != member.professional_id
      else return :cbo_not_allowed
      end
      registrar_cbo?(member.cbo_code, ficha: ficha) ? :ok : :cbo_not_allowed
    end

    # Microáreas da equipe que o usuário enxerga para cadastrar: todas para
    # enfermeiro/médico, as suas para o ACS, nenhuma para os demais.
    def visible_micro_area_ids(user, team)
      member = membership(user, team)
      case member && role(member.cbo_code)
      when :registrar then MicroArea.where(team: team).pluck(:id)
      when :acs then MicroArea.where(team: team, acs_professional_id: member.professional_id).pluck(:id)
      else []
      end
    end

    def role(cbo)
      return :acs if cbo == Catalog::ACS_CBO

      :registrar if Catalog::REGISTRAR_CBO_PREFIXES.any? { |prefix| cbo.to_s.start_with?(prefix) }
    end
    private_class_method :role
  end
end
